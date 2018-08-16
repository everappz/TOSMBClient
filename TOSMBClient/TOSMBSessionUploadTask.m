//
//  TOSMBSessionUploadTask.m
//  Everapp
//
//  Created by Artem Meleshko on 2/14/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#import "TOSMBSessionUploadTask.h"
#import <UIKit/UIKit.h>
#import "TOSMBSession+Private.h"
#import "TOSMBSession.h"
#import "TOSMBSessionUploadTask.h"
#import "TOSMBClient.h"
#import "smb_session.h"
#import "smb_share.h"
#import "smb_file.h"
#import "smb_defs.h"

// -------------------------------------------------------------------------

@interface TOSMBSessionUploadTask ()

@property (assign, readwrite) TOSMBSessionTransferTaskState state;

@property (nonatomic, copy) NSString *sourceFilePath;
@property (nonatomic, copy) NSString *uploadTemporaryFilePath;
@property (nonatomic, copy) NSString *destinationFilePath;

@property (nonatomic, weak) TOSMBSession *sessionObject;
@property (nonatomic, strong) TOSMBCSessionWrapper *dsm_session;
@property (nonatomic, strong) NSBlockOperation *uploadOperation;

@property (assign,readwrite) int64_t countOfBytesSend;
@property (assign,readwrite) int64_t countOfBytesExpectedToSend;

/** Feedback handlers */
@property (nonatomic, copy) void (^progressHandler)(uint64_t totalBytesWritten, uint64_t totalBytesExpected);
@property (nonatomic, copy) void (^successHandler)(NSString *filePath);
@property (nonatomic, copy) void (^failHandler)(NSError *error);

/* Download methods */
- (void)setupUploadOperation;
- (void)performUploadWithOperation:(NSBlockOperation *)weakOperation;
- (TOSMBSessionFile *)requestFileForItemAtFormattedPath:(NSString *)filePath fullPath:(NSString *)fullPath inTree:(smb_tid)treeID;

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
        _sessionObject = session;
        _dsm_session = session.dsm_session;
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
}

#pragma mark - Public Control Methods -

- (void)start{
    if (self.state == TOSMBSessionTransferTaskStateRunning){
        return;
    }
    [self setupUploadOperation];
    [self.sessionObject.dataQueue addOperation:self.uploadOperation];
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
    [self.sessionObject.dataQueue addOperation:deleteOperation];
    [self.uploadOperation cancel];
    self.state = TOSMBSessionTransferTaskStateCancelled;
    self.uploadOperation = nil;
}

#pragma mark - Feedback Methods -


- (void)didSucceedWithFilePath:(NSString *)filePath{
    WEAK_SELF();
    [self.sessionObject performCallBackWithBlock:^{
        CHECK_IF_WEAK_SELF_IS_NIL_AND_RETURN();
        STRONG_WEAK_SELF();
        if (strongSelf.successHandler){
            strongSelf.successHandler(filePath);
        }
    }];
}

- (void)didFailWithError:(NSError *)error{
    WEAK_SELF();
    [self.sessionObject performCallBackWithBlock:^{
        CHECK_IF_WEAK_SELF_IS_NIL_AND_RETURN();
        STRONG_WEAK_SELF();
        if (strongSelf.failHandler){
            strongSelf.failHandler(error);
        }
    }];
}

- (void)didUpdateWriteBytes:(NSData *)bytesWritten totalBytesWritten:(uint64_t)totalBytesWritten totalBytesExpected:(uint64_t)totalBytesExpected{
    WEAK_SELF();
    [self.sessionObject performCallBackWithBlock:^{
        CHECK_IF_WEAK_SELF_IS_NIL_AND_RETURN();
        STRONG_WEAK_SELF();
        if (strongSelf.progressHandler){
            strongSelf.progressHandler(strongSelf.countOfBytesSend, strongSelf.countOfBytesExpectedToSend);
        }
    }];
}

#pragma mark - Uploading -

- (TOSMBSessionFile *)requestFileForItemAtFormattedPath:(NSString *)filePath fullPath:(NSString *)fullPath inTree:(smb_tid)treeID{
    const char *fileCString = [filePath cStringUsingEncoding:NSUTF8StringEncoding];
    __block smb_stat fileStat = NULL;
    [self.dsm_session inSMBCSession:^(smb_session *session) {
         fileStat = smb_fstat(session, treeID, fileCString);
    }];
    
    if (fileStat==NULL){
        return nil;
    }
    TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:fileStat parentDirectoryFilePath:[filePath stringByDeletingLastPathComponent]];
    smb_stat_destroy(fileStat);
    return file;
}

- (void)setupUploadOperation{
    if (self.uploadOperation){
        return;
    }
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    WEAK_SELF();
    WEAK_OPERATION();
    id executionBlock = ^{
        CHECK_IF_WEAK_OPERATION_IS_CANCELLED_OR_NIL_AND_RETURN();
        CHECK_IF_WEAK_SELF_IS_NIL_AND_RETURN();
        STRONG_WEAK_SELF();
        STRONG_WEAK_OPERATION();
        [strongSelf performUploadWithOperation:strongOperation];
    };
    [operation addExecutionBlock:executionBlock];
    operation.completionBlock = ^{
        STRONG_WEAK_SELF();
        strongSelf.uploadOperation = nil;
    };
    self.uploadOperation = operation;
}

+ (NSString *)uuidString {
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    NSString *uuidStr = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return uuidStr;
}

- (void)performUploadWithOperation:(NSBlockOperation *)operation{
    
    NSParameterAssert(self.dsm_session!=nil && self.sessionObject!=nil);
    
    if (operation.isCancelled  || self.dsm_session==nil || self.sessionObject==nil){
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        return;
    }
    
    __block smb_tid treeID = 0;
    __block smb_fd fileID = 0;
    
    //---------------------------------------------------------------------------------------
    //Set up paths
    
    self.uploadTemporaryFilePath = [[self.destinationFilePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@",[[self class] uuidString],self.destinationFilePath.pathExtension?:@"tmp"]];
    
    NSString *formattedUploadPath = [self.sessionObject relativeSMBPathFromPath:self.uploadTemporaryFilePath];
    NSString *formattedPath = [self.sessionObject relativeSMBPathFromPath:self.destinationFilePath];
    
    const char *relativeUploadPathCString = [formattedUploadPath cStringUsingEncoding:NSUTF8StringEncoding];
    const char *relativeToPathCString = [formattedPath cStringUsingEncoding:NSUTF8StringEncoding];
    
    //---------------------------------------------------------------------------------------
    //Set up a cleanup block that'll release any handles before cancellation
    WEAK_SELF();
    void (^cleanup)(void) = ^{
        STRONG_WEAK_SELF()
        if (fileID>0){
            [strongSelf.dsm_session inSMBCSession:^(smb_session *session) {
               smb_fclose(session, fileID);
            }];
        }
        if (treeID>0){
            [strongSelf.dsm_session inSMBCSession:^(smb_session *session) {
                 smb_file_rm(session, treeID, relativeUploadPathCString);
            }];
            //smb_tree_disconnect(self.session, treeID);
        }
    };
    
    //---------------------------------------------------------------------------------------
    //Connect to SMB device
    
    //First, check to make sure the file is there, and to acquire its attributes
    NSError *error = [self.sessionObject attemptConnection];
    self.dsm_session = self.sessionObject.dsm_session;
    if (error) {
        [self didFailWithError:error];
        cleanup();
        return;
    }
    
    if (operation.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        cleanup();
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Connect to share
    
    //Next attach to the share we'll be using
    NSString *shareName = [self.sessionObject shareNameFromPath:self.destinationFilePath];
    const char *shareCString = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    treeID = [self.dsm_session cachedShareIDForName:shareName];
    if(treeID==0){
        [self.dsm_session inSMBCSession:^(smb_session *session) {
            smb_tree_connect(session, shareCString,&treeID);
        }];
    }
    if (treeID==0) {
        [self.dsm_session removeCachedShareIDForName:shareName];
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed)];
        cleanup();
        return;
    }
    else{
        [self.dsm_session cacheShareID:treeID forName:shareName];
    }
    
    if (operation.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
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
    
    if (operation.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        cleanup();
        return;
    }
    
    NSDictionary *sourceFileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:self.sourceFilePath error:nil];
    
    self.countOfBytesExpectedToSend = [sourceFileAttributes fileSize];
    
    //---------------------------------------------------------------------------------------
    //Open the file handle
    [self.dsm_session inSMBCSession:^(smb_session *session) {
        smb_fopen(session, treeID, relativeUploadPathCString, SMB_MOD_RW,&fileID);
    }];

    if (fileID==0) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFailToUpload)];
        cleanup();
        return;
    }
    
    if (operation.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
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
    
    @autoreleasepool{
    
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
                    __block ssize_t r = -1;
                    [self.dsm_session inSMBCSession:^(smb_session *session) {
                        r = smb_fwrite(session, fileID, bytes, bytesToWrite);
                    }];
                    
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

            if (operation.isCancelled){
                break;
            }
            
            if(uploadError){
                [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFailToUpload)];
                break;
            }
            
            self.countOfBytesSend += dataLength;
            
            [self didUpdateWriteBytes:data totalBytesWritten:self.countOfBytesSend totalBytesExpected:self.countOfBytesExpectedToSend];
            
        } while (dataLength>0 && (uploadError!=YES));
    
    }
    
    @try{[fileHandle closeFile];}@catch(NSException *exc){}
    
    if (fileID>0){
        [self.dsm_session inSMBCSession:^(smb_session *session) {
            smb_fclose(session, fileID);
        }];
    }
    
    if (operation.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        cleanup();
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Move the finished file to its destination
    TOSMBSessionFile *existingFile = [self requestFileForItemAtFormattedPath:formattedPath fullPath:self.destinationFilePath inTree:treeID];
    if (existingFile){
        [self.dsm_session inSMBCSession:^(smb_session *session) {
            smb_file_rm(session, treeID, relativeToPathCString);
        }];
    }
    
    __block int result = DSM_ERROR_GENERIC;
    [self.dsm_session inSMBCSession:^(smb_session *session) {
        result = smb_file_mv(session, treeID, relativeUploadPathCString, relativeToPathCString);
    }];
    
    self.state = TOSMBSessionTransferTaskStateCompleted;
    
    cleanup();
    
    if(result==DSM_SUCCESS){
        [self didSucceedWithFilePath:self.destinationFilePath];
    }
    else{
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFailToUpload)];
    }

}

@end
