//
// TOSMBDownloadTask.m
// Copyright 2015 Timothy Oliver
//
// This file is dual-licensed under both the MIT License, and the LGPL v2.1 License.
//
// -------------------------------------------------------------------------------
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
// -------------------------------------------------------------------------------

#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import "TOSMBSessionDownloadTask.h"
#import "TOSMBClient.h"
#import "smb_session.h"
#import "smb_share.h"
#import "smb_file.h"
#import "smb_defs.h"
#import "TOSMBSession+Private.h"
#import "TOSMBSessionFile+Private.h"
#import "TOSMBSession.h"


@interface TOSMBSessionDownloadTask ()

@property (assign, readwrite) TOSMBSessionTransferTaskState state;

@property (nonatomic, copy) NSString *sourceFilePath;
@property (nonatomic, copy) NSString *destinationFilePath;
@property (nonatomic, copy) NSString *tempFilePath;

@property (nonatomic, weak) TOSMBSession *sessionObject;
@property (nonatomic, strong) TOSMBCSessionWrapper *dsm_session;
@property (nonatomic, strong) TOSMBSessionFile *file;
@property (nonatomic, strong) NSBlockOperation *downloadOperation;

@property (assign,readwrite) int64_t countOfBytesReceived;
@property (assign,readwrite) int64_t countOfBytesExpectedToReceive;

/** Feedback handlers */
@property (nonatomic, copy) void (^progressHandler)(uint64_t totalBytesWritten, uint64_t totalBytesExpected);
@property (nonatomic, copy) void (^successHandler)(NSString *filePath);
@property (nonatomic, copy) void (^failHandler)(NSError *error);

/* Download methods */
- (void)setupDownloadOperation;
- (void)performDownloadWithOperation:(NSBlockOperation *)weakOperation;
- (TOSMBSessionFile *)requestFileForItemAtFormattedPath:(NSString *)filePath fullPath:(NSString *)fullPath inTree:(smb_tid)treeID;

/* File Path Methods */
- (NSString *)hashForFilePath;
- (NSString *)filePathForTemporaryDestination;
- (NSString *)finalFilePathForDownloadedFile;
- (NSString *)documentsDirectory;

/* Feedback events sent to either the delegate or callback blocks */
- (void)didSucceedWithFilePath:(NSString *)filePath;
- (void)didFailWithError:(NSError *)error;
- (void)didUpdateWriteBytes:(NSData *)bytesWritten;
- (void)didResumeAtOffset:(uint64_t)bytesWritten totalBytesExpected:(uint64_t)totalBytesExpected;

@end

@implementation TOSMBSessionDownloadTask

- (instancetype)init{
    //This class cannot be instantiated on its own.
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (instancetype)initWithSession:(TOSMBSession *)session filePath:(NSString *)filePath destinationPath:(NSString *)destinationPath delegate:(id<TOSMBSessionDownloadTaskDelegate>)delegate{
    if (self = [super init]) {
        _sessionObject = session;
        _dsm_session = session.dsm_session;
        _sourceFilePath = [filePath copy];
        _destinationFilePath = destinationPath.length ? [destinationPath copy] : [self documentsDirectory];
        _delegate = delegate;
        _seekOffset = NSNotFound;
        _tempFilePath = [self filePathForTemporaryDestination];
    }
    
    return self;
}

- (instancetype)initWithSession:(TOSMBSession *)session filePath:(NSString *)filePath destinationPath:(NSString *)destinationPath progressHandler:(id)progressHandler successHandler:(id)successHandler failHandler:(id)failHandler{
    if (self = [super init]) {
        _sessionObject = session;
        _dsm_session = session.dsm_session;
        _sourceFilePath = [filePath copy];
        _destinationFilePath = destinationPath.length ? [destinationPath copy] : [self documentsDirectory];
        _progressHandler = [progressHandler copy];
        _successHandler = [successHandler copy];
        _failHandler = [failHandler copy];
        _seekOffset = NSNotFound;
        _tempFilePath = [self filePathForTemporaryDestination];
    }
    
    return self;
}

- (void)dealloc{
    [self.downloadOperation cancel];
}

#pragma mark - Temporary Destination Methods -

- (NSString *)filePathForTemporaryDestination{
    NSString *fileName = [[self hashForFilePath] stringByAppendingPathExtension:@"smb.data"];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
}

- (NSString *)hashForFilePath{
    NSString *filePath = self.sourceFilePath.lowercaseString;
    NSData *data = [filePath dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (unsigned int)data.length, digest);
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++){
        [output appendFormat:@"%02x", digest[i]];
    }
    return [NSString stringWithString:output];
}

- (NSString *)finalFilePathForDownloadedFile{
    NSString *path = self.destinationFilePath;
    
    //Check to ensure the destination isn't referring to a file name
    NSString *fileName = [path lastPathComponent];
    BOOL isFile = ([fileName rangeOfString:@"."].location != NSNotFound && [fileName characterAtIndex:0] != '.');
    
    NSString *folderPath = nil;
    if (isFile) {
        folderPath = [path stringByDeletingLastPathComponent];
    }
    else {
        fileName = [self.sourceFilePath lastPathComponent];
        folderPath = path;
    }
    
    path = [folderPath stringByAppendingPathComponent:fileName];
    
    //If a file with that name already exists in the destination directory, append a number on the end of the file name
    NSString *newFilePath = path;
    NSString *newFileName = fileName;
    NSInteger index = 1;
    while ([[NSFileManager defaultManager] fileExistsAtPath:newFilePath]) {
        newFileName = [NSString stringWithFormat:@"%@-%ld.%@", [fileName stringByDeletingPathExtension], (long)index++, [fileName pathExtension]];
        newFilePath = [folderPath stringByAppendingPathComponent:newFileName];
    }
    
    return newFilePath;
}

- (NSString *)documentsDirectory{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    return basePath;
}

#pragma mark - Public Control Methods -

- (void)resume{
    if (self.state == TOSMBSessionTransferTaskStateRunning){
        return;
    }
    [self setupDownloadOperation];
    [self.sessionObject.dataQueue addOperation:self.downloadOperation];
    self.state = TOSMBSessionTransferTaskStateRunning;
}

- (void)suspend{
    if (self.state != TOSMBSessionTransferTaskStateRunning){
        return;
    }
    [self.downloadOperation cancel];
    self.state = TOSMBSessionTransferTaskStateSuspended;
    self.downloadOperation = nil;
}

- (void)cancel{
    if (self.state != TOSMBSessionTransferTaskStateRunning){
        return;
    }
    [self.downloadOperation cancel];
    self.downloadOperation = nil;
    WEAK_SELF();
    id deleteBlock = ^{
        CHECK_IF_WEAK_SELF_IS_NIL_AND_RETURN();
        STRONG_WEAK_SELF();
        @try{[[NSFileManager defaultManager] removeItemAtPath:strongSelf.tempFilePath error:nil];}@catch(NSException *exc){}
    };
    NSBlockOperation *deleteOperation = [[NSBlockOperation alloc] init];
    [deleteOperation addExecutionBlock:deleteBlock];
    [self.sessionObject.dataQueue addOperation:deleteOperation];
    self.state = TOSMBSessionTransferTaskStateCancelled;
}

#pragma mark - Feedback Methods -

#pragma mark - Private Control Methods -
- (void)fail
{
    if (self.state != TOSMBSessionTransferTaskStateRunning){
        return;
    }
    
    [self cancel];
    
    self.state = TOSMBSessionTransferTaskStateFailed;
}

- (BOOL)canBeResumed{
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.tempFilePath] == NO){
        return NO;
    }
    NSDate *modificationTime = [[[NSFileManager defaultManager] attributesOfItemAtPath:self.tempFilePath error:nil] fileModificationDate];
    if ([modificationTime isEqual:self.file.modificationTime] == NO) {
        return NO;
    }
    return YES;
}

- (void)didSucceedWithFilePath:(NSString *)filePath{
    WEAK_SELF();
    [self.sessionObject performCallBackWithBlock:^{
        CHECK_IF_WEAK_SELF_IS_NIL_AND_RETURN();
        STRONG_WEAK_SELF();
        if (strongSelf.delegate && [strongSelf.delegate respondsToSelector:@selector(downloadTask:didFinishDownloadingToPath:)]){
            [strongSelf.delegate downloadTask:strongSelf didFinishDownloadingToPath:filePath];
        }
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
        if (strongSelf.delegate && [strongSelf.delegate respondsToSelector:@selector(downloadTask:didCompleteWithError:)]){
            [strongSelf.delegate downloadTask:strongSelf didCompleteWithError:error];
        }
        if (strongSelf.failHandler){
            strongSelf.failHandler(error);
        }
    }];
}

- (void)didUpdateWriteBytes:(NSData *)bytesWritten{
    WEAK_SELF();
    [self.sessionObject performCallBackWithBlock:^{
        CHECK_IF_WEAK_SELF_IS_NIL_AND_RETURN();
        STRONG_WEAK_SELF();
        if (strongSelf.delegate && [strongSelf.delegate respondsToSelector:@selector(downloadTask:didWriteBytes:totalBytesReceived:totalBytesExpectedToReceive:)]){
            [strongSelf.delegate downloadTask:strongSelf didWriteBytes:bytesWritten totalBytesReceived:strongSelf.countOfBytesReceived totalBytesExpectedToReceive:strongSelf.countOfBytesExpectedToReceive];
        }
        if (strongSelf.progressHandler){
            strongSelf.progressHandler(strongSelf.countOfBytesReceived, strongSelf.countOfBytesExpectedToReceive);
        }
    }];
}

- (void)didResumeAtOffset:(uint64_t)bytesWritten totalBytesExpected:(uint64_t)totalBytesExpected{
    WEAK_SELF();
    [self.sessionObject performCallBackWithBlock:^{
        CHECK_IF_WEAK_SELF_IS_NIL_AND_RETURN();
        STRONG_WEAK_SELF();
        if (strongSelf.delegate && [strongSelf.delegate respondsToSelector:@selector(downloadTask:didResumeAtOffset:totalBytesExpectedToReceive:)]){
            [strongSelf.delegate downloadTask:strongSelf didResumeAtOffset:bytesWritten totalBytesExpectedToReceive:totalBytesExpected];
        }
    }];
}

#pragma mark - Downloading -

- (TOSMBSessionFile *)requestFileForItemAtFormattedPath:(NSString *)filePath fullPath:(NSString *)fullPath inTree:(smb_tid)treeID{
    const char *fileCString = [filePath cStringUsingEncoding:NSUTF8StringEncoding];
    if(self.dsm_session!=NULL){
        __block smb_stat fileStat = NULL;
        [self.dsm_session inSMBCSession:^(smb_session *session) {
            fileStat = smb_fstat(session, treeID, fileCString);
        }];
        
        if (fileStat==NULL){
            return nil;
        }
        TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:fileStat parentDirectoryFilePath:[fullPath stringByDeletingLastPathComponent]];
        smb_stat_destroy(fileStat);
        return file;
    }
    return nil;
}

- (void)setupDownloadOperation{
    
    if (self.downloadOperation){
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
        
        [strongSelf performDownloadWithOperation:strongOperation];
    };
    [operation addExecutionBlock:executionBlock];
    operation.completionBlock = ^{
        STRONG_WEAK_SELF();
        strongSelf.downloadOperation = nil;
    };
    
    self.downloadOperation = operation;
}

- (void)performDownloadWithOperation:(NSBlockOperation *)operation{
    
    NSParameterAssert(self.dsm_session!=nil && self.sessionObject!=nil);
    
    if (operation.isCancelled || self.dsm_session==nil || self.sessionObject==nil){
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        return;
    }
    
    __block smb_tid treeID = 0;
    __block smb_fd fileID = 0;
    
    //---------------------------------------------------------------------------------------
    //Set up a cleanup block that'll release any handles before cancellation
    WEAK_SELF();
    void (^cleanup)(void) = ^{
        
        if (fileID){
            [weakSelf.dsm_session inSMBCSession:^(smb_session *session) {
                smb_fclose(session, fileID);
            }];
        }
        
        //if (self.session!=NULL && treeID){
        //    smb_tree_disconnect(self.session, treeID);
        //}
        
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
    NSString *shareName = [self.sessionObject shareNameFromPath:self.sourceFilePath];
    const char *shareCString = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    treeID = [self.dsm_session cachedShareIDForName:shareName];
    
    if(treeID==0){
        [self.dsm_session inSMBCSession:^(smb_session *session) {
            smb_tree_connect(session, shareCString, &treeID);
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
    
    NSString *formattedPath = [self.sessionObject relativeSMBPathFromPath:self.sourceFilePath];
    
    //Get the file info we'll be working off
    self.file = [self requestFileForItemAtFormattedPath:formattedPath fullPath:self.sourceFilePath inTree:treeID];
    if (self.file == nil) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        cleanup();
        return;
    }
    
    if (operation.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        cleanup();
        return;
    }
    
    if (self.file.directory) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeDirectoryDownloaded)];
        cleanup();
        return;
    }
    
    self.countOfBytesExpectedToReceive = self.file.fileSize;
    
    //---------------------------------------------------------------------------------------
    //Open the file handle
    [self.dsm_session inSMBCSession:^(smb_session *session) {
        smb_fopen(session, treeID, [formattedPath cStringUsingEncoding:NSUTF8StringEncoding], SMB_MOD_RO,&fileID);
    }];
    
    if (fileID==0) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        cleanup();
        return;
    }
    
    if (operation.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        cleanup();
        return;
    }
    
    
    //---------------------------------------------------------------------------------------
    //Start downloading
    
    //Create the directories to the download destination
    [[NSFileManager defaultManager] createDirectoryAtPath:[self.tempFilePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    
    //Create a new blank file to write to
    if (self.canBeResumed == NO){
        [[NSFileManager defaultManager] createFileAtPath:self.tempFilePath contents:nil attributes:nil];
    }
    
    //Open a handle to the file and skip ahead if we're resuming
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.tempFilePath];
    unsigned long long seekOffset = (ssize_t)[fileHandle seekToEndOfFile];
    if(self.seekOffset!=NSNotFound){
        seekOffset = self.seekOffset;
    }
    self.countOfBytesReceived = seekOffset;
    
    if (seekOffset > 0) {
        [self.dsm_session inSMBCSession:^(smb_session *session) {
            smb_fseek(session, fileID, (ssize_t)seekOffset, SMB_SEEK_SET);
        }];
        [self didResumeAtOffset:seekOffset totalBytesExpected:self.countOfBytesExpectedToReceive];
    }
    
    //Perform the file download
    __block int64_t bytesRead = 0;
    const NSInteger bufferSize = 32768;
    const NSInteger callbackDataBufferSize = 5*bufferSize;
    NSMutableData *callbackData = [[NSMutableData alloc] init];
    char *buffer = malloc(bufferSize);
    
    @autoreleasepool {
        do {
            
            [self.dsm_session inSMBCSession:^(smb_session *session) {
                bytesRead = smb_fread(session, fileID, buffer, bufferSize);
            }];
            
            if (bytesRead < 0) {
                [self fail];
                [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileDownloadFailed)];
                break;
            }
            
            //Save them to the file handle (And ensure the NSData object is flushed immediately)
            NSData *data = [NSData dataWithBytes:buffer length:bytesRead];
            @try {
                [fileHandle writeData:data];
                
                //Ensure the data is properly written to disk before proceeding
                [fileHandle synchronizeFile];
            } @catch (NSException *exception) {}
            
            if (operation.isCancelled){
                break;
            }
            self.countOfBytesReceived += bytesRead;
            [callbackData appendData:data];
            if(callbackData.length>=callbackDataBufferSize || bytesRead==0){
                [self didUpdateWriteBytes:callbackData];
                callbackData = [[NSMutableData alloc] init];
            }
            
        } while (bytesRead > 0);
        
    }
    //Set the modification date to match the one on the SMB device so we can compare the two at a later date
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate:self.file.modificationTime} ofItemAtPath:self.tempFilePath error:nil];
    
    free(buffer);
    [fileHandle closeFile];
    
    if (operation.isCancelled  || self.state != TOSMBSessionTransferTaskStateRunning) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        cleanup();
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Move the finished file to its destination
    
    //Workout the destination of the file and move it
    NSString *finalDestinationPath = [self finalFilePathForDownloadedFile];
    [[NSFileManager defaultManager] moveItemAtPath:self.tempFilePath toPath:finalDestinationPath error:nil];
    
    self.state = TOSMBSessionTransferTaskStateCompleted;
    
    //Perform a final cleanup of all handles and references
    cleanup();
    
    //Alert the delegate that we finished, so they may perform any additional cleanup operations
    [self didSucceedWithFilePath:finalDestinationPath];
}

@end
