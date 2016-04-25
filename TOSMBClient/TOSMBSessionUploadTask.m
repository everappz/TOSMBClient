//
//  TOSMBSessionUploadTask.m
//  MyApp
//
//  Created by Artem Meleshko on 2/14/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import "TOSMBSessionUploadTask.h"
#import <UIKit/UIKit.h>

#import "TOSMBSessionUploadTask.h"
#import "TOSMBClient.h"
#import "smb_session.h"
#import "smb_share.h"
#import "smb_file.h"
#import "smb_defs.h"

// -------------------------------------------------------------------------
// Private methods in TOSMBSession shared here

@interface TOSMBSession ()

@property (readonly) NSOperationQueue *transferQueue;

- (NSError *)attemptConnectionWithSessionPointer:(smb_session *)session;
- (NSString *)shareNameFromPath:(NSString *)path;
- (NSString *)filePathExcludingSharePathFromPath:(NSString *)path;

@end

// -------------------------------------------------------------------------

@interface TOSMBSessionUploadTask ()

@property (assign, readwrite) TOSMBSessionTransferTaskState state;

@property (nonatomic, copy) NSString *sourceFilePath;
@property (nonatomic, copy) NSString *uploadTemporaryFilePath;
@property (nonatomic, copy) NSString *destinationFilePath;

@property (nonatomic, weak) TOSMBSession *session;
@property (nonatomic, assign) smb_session *uploadSession;
@property (nonatomic, strong) NSBlockOperation *uploadOperation;

@property (assign,readwrite) int64_t countOfBytesSend;
@property (assign,readwrite) int64_t countOfBytesExpectedToSend;

/** Feedback handlers */
@property (nonatomic, copy) void (^progressHandler)(uint64_t totalBytesWritten, uint64_t totalBytesExpected);
@property (nonatomic, copy) void (^successHandler)(NSString *filePath);
@property (nonatomic, copy) void (^failHandler)(NSError *error);

/* Download methods */
- (void)setupUploadOperation;
- (void)performUploadWithOperation:(__weak NSBlockOperation *)weakOperation;
- (TOSMBSessionFile *)requestFileForItemAtPath:(NSString *)filePath inTree:(smb_tid)treeID;

/* Feedback events sent to either the delegate or callback blocks */
- (void)didSucceedWithFilePath:(NSString *)filePath;
- (void)didFailWithError:(NSError *)error;
- (void)didUpdateWriteBytes:(NSData *)bytesWritten totalBytesWritten:(uint64_t)totalBytesWritten totalBytesExpected:(uint64_t)totalBytesExpected;

@end

@implementation TOSMBSessionUploadTask

- (instancetype)init{
    //This class cannot be instantiated on its own.
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (instancetype)initWithSession:(TOSMBSession *)session filePath:(NSString *)filePath destinationPath:(NSString *)destinationPath progressHandler:(id)progressHandler successHandler:(id)successHandler failHandler:(id)failHandler{
    if (self = [super init]) {
        _session = session;
        _sourceFilePath = [filePath copy];
        _destinationFilePath = [destinationPath copy];
        _progressHandler = [progressHandler copy];
        _successHandler = [successHandler copy];
        _failHandler = [failHandler copy];
    }
    return self;
}

- (void)dealloc{
    [self.uploadOperation cancel];
    if(self.uploadSession!=NULL){
        smb_session_destroy(self.uploadSession);
        self.uploadSession = NULL;
    }
}


#pragma mark - Public Control Methods -

- (void)start{
    if (self.state == TOSMBSessionTransferTaskStateRunning){
        return;
    }
    [self setupUploadOperation];
    [self.session.transferQueue addOperation:self.uploadOperation];
    self.state = TOSMBSessionTransferTaskStateRunning;
}

- (void)cancel{
    if (self.state != TOSMBSessionTransferTaskStateRunning){
        return;
    }
    id deleteBlock = ^{
        //todo: delete unfinished uploaded file
    };
    NSBlockOperation *deleteOperation = [[NSBlockOperation alloc] init];
    [deleteOperation addExecutionBlock:deleteBlock];
    if(self.uploadOperation){
        [deleteOperation addDependency:self.uploadOperation];
    }
    [self.session.transferQueue addOperation:deleteOperation];
    [self.uploadOperation cancel];
    self.state = TOSMBSessionTransferTaskStateCancelled;
    self.uploadOperation = nil;
}

#pragma mark - Feedback Methods -


- (void)didSucceedWithFilePath:(NSString *)filePath{
    __weak typeof (self) weakSelf = self;
    [self.session performCallBackWithBlock:^{
        if (weakSelf.successHandler){
            weakSelf.successHandler(filePath);
        }
    }];
}

- (void)didFailWithError:(NSError *)error{
    __weak typeof (self) weakSelf = self;
    [self.session performCallBackWithBlock:^{
        if (weakSelf.failHandler){
            weakSelf.failHandler(error);
        }
    }];
}

- (void)didUpdateWriteBytes:(NSData *)bytesWritten totalBytesWritten:(uint64_t)totalBytesWritten totalBytesExpected:(uint64_t)totalBytesExpected{
    __weak typeof (self) weakSelf = self;
    [self.session performCallBackWithBlock:^{
        if (weakSelf.progressHandler){
            weakSelf.progressHandler(weakSelf.countOfBytesSend, weakSelf.countOfBytesExpectedToSend);
        }
    }];
}

#pragma mark - Uploading -

- (TOSMBSessionFile *)requestFileForItemAtPath:(NSString *)filePath inTree:(smb_tid)treeID{
    const char *fileCString = [filePath cStringUsingEncoding:NSUTF8StringEncoding];
    smb_stat fileStat = NULL;
    if(self.uploadSession!=NULL){
        fileStat = smb_fstat(self.uploadSession, treeID, fileCString);
    }
    if (fileStat==NULL){
        return nil;
    }
    TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:fileStat parentDirectoryFilePath:filePath];
    smb_stat_destroy(fileStat);
    return file;
}

- (void)setupUploadOperation{
    
    if (self.uploadOperation){
        return;
    }
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    __weak typeof (self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    
    id executionBlock = ^{
        [weakSelf performUploadWithOperation:weakOperation];
    };
    [operation addExecutionBlock:executionBlock];
    operation.completionBlock = ^{
        weakSelf.uploadOperation = nil;
    };
    
    self.uploadOperation = operation;
}

+ (NSString *)uuidString {
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    NSString *uuidStr = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return uuidStr;
}

- (void)performUploadWithOperation:(__weak NSBlockOperation *)weakOperation{
    
    if (weakOperation.isCancelled){
        return;
    }
    
    smb_tid treeID = -1;
    smb_fd fileID = 0;
    
    //---------------------------------------------------------------------------------------
    //Set up paths
    
    self.uploadTemporaryFilePath = [[self.destinationFilePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@",[[self class] uuidString],self.destinationFilePath.pathExtension?:@"tmp"]];
    
    NSString *formattedUploadPath = [self.session filePathExcludingSharePathFromPath:self.uploadTemporaryFilePath];
    formattedUploadPath = [NSString stringWithFormat:@"\\%@",formattedUploadPath];
    formattedUploadPath = [formattedUploadPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    
    NSString *formattedPath = [self.session filePathExcludingSharePathFromPath:self.destinationFilePath];
    formattedPath = [NSString stringWithFormat:@"\\%@",formattedPath];
    formattedPath = [formattedPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    
    const char *relativeUploadPathCString = [formattedUploadPath cStringUsingEncoding:NSUTF8StringEncoding];
    const char *relativeToPathCString = [formattedPath cStringUsingEncoding:NSUTF8StringEncoding];
    
    //---------------------------------------------------------------------------------------
    //Set up a cleanup block that'll release any handles before cancellation
    void (^cleanup)(void) = ^{

        if (self.uploadSession!=NULL && fileID){
            smb_fclose(self.uploadSession, fileID);
        }
        
        if (self.uploadSession!=NULL && treeID){
            smb_file_rm(self.uploadSession, treeID, relativeUploadPathCString);
            smb_tree_disconnect(self.uploadSession, treeID);
        }
        
        if (self.uploadSession!=NULL) {
            smb_session_destroy(self.uploadSession);
            self.uploadSession = NULL;
        }
    };
    
    //---------------------------------------------------------------------------------------
    //Connect to SMB device
    
    self.uploadSession = smb_session_new();
    
    //First, check to make sure the file is there, and to acquire its attributes
    NSError *error = [self.session attemptConnectionWithSessionPointer:self.uploadSession];
    if (error) {
        [self didFailWithError:error];
        cleanup();
        return;
    }
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Connect to share
    
    //Next attach to the share we'll be using
    NSString *shareName = [self.session shareNameFromPath:self.destinationFilePath];
    const char *shareCString = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    treeID = smb_tree_connect(self.uploadSession, shareCString);
    if (treeID<0) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed)];
        cleanup();
        return;
    }
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Find the target file

    BOOL isDir = NO;
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:self.sourceFilePath isDirectory:&isDir];
    
    if (fileExists == NO) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        cleanup();
        return;
    }
    
    if (isDir) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeDirectoryUploaded)];
        cleanup();
        return;
    }
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }
    
    NSDictionary *sourceFileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:self.sourceFilePath error:nil];
    
    self.countOfBytesExpectedToSend = [sourceFileAttributes fileSize];
    
    //---------------------------------------------------------------------------------------
    //Open the file handle
    
    fileID = smb_fopen(self.uploadSession, treeID, relativeUploadPathCString, SMB_MOD_RW);
    if (!fileID) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFailToUpload)];
        cleanup();
        return;
    }
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Start uploading
    
    //Open a handle to the file
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:self.sourceFilePath];
    unsigned long long seekOffset = 0;
    self.countOfBytesSend = seekOffset;
    
    //Perform the file upload
    const NSInteger bufferSize = 32768;
    BOOL uploadError = NO;
    NSInteger dataLength = 0;
    
    do {
        
        @try{[fileHandle seekToFileOffset:self.countOfBytesSend];}@catch(NSException *exc){}
        
        NSData *data = nil;
        @try {
            data =  [fileHandle readDataOfLength:bufferSize];
        }
        @catch (NSException *exception) {
            uploadError = YES;
        }
        dataLength = data.length;
        NSInteger bytesToWrite = dataLength;
        
        if(bytesToWrite>0){
            
            void *bytes = (void *)data.bytes;
            while (bytesToWrite > 0) {
                ssize_t r = -1;
                if(self.uploadSession!=NULL){
                    r = smb_fwrite(self.uploadSession, fileID, bytes, bytesToWrite);
                }
                
                if (r == 0){
                    break;
                }
                
                if (r < 0) {
                    uploadError = YES;
                    break;
                }
                bytesToWrite -= r;
                bytes += r;
            }
            
        }

        if (weakOperation.isCancelled){
            break;
        }
        
        if(uploadError){
            [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFailToUpload)];
            break;
        }
        
        self.countOfBytesSend += dataLength;
        
        [self didUpdateWriteBytes:data totalBytesWritten:self.countOfBytesSend totalBytesExpected:self.countOfBytesExpectedToSend];
        
    } while (dataLength>0 && (uploadError!=YES));
    
    @try{
        [fileHandle closeFile];
    }
    @catch(NSException *exc){}
    
    if (self.uploadSession && fileID){
        smb_fclose(self.uploadSession, fileID);
    }
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Move the finished file to its destination
    
    TOSMBSessionFile *existingFile = [self requestFileForItemAtPath:formattedPath inTree:treeID];
    if(self.uploadSession && existingFile){
        smb_file_rm(self.uploadSession, treeID, relativeToPathCString);
    }
    int result = -1;
    
    if(self.uploadSession){
        result = smb_file_mv(self.uploadSession, treeID, relativeUploadPathCString, relativeToPathCString);
    }
    
    self.state =TOSMBSessionTransferTaskStateCompleted;
    
    cleanup();
    
    if(result==0){
        [self didSucceedWithFilePath:self.destinationFilePath];
    }
    else{
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFailToUpload)];
    }

}

@end
