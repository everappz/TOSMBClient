//
//  TOSMBSessionUploadTask.m
//  Everapp
//
//  Created by Artem Meleshko on 2/14/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#import "TOSMBSessionUploadTask.h"
#import "TOSMBSessionTransferTask+Private.h"

// -------------------------------------------------------------------------

@interface TOSMBSessionUploadTask ()

@property (nonatomic, copy) NSString *uploadTemporaryFilePath;

@property (nonatomic, assign) int64_t countOfBytesSend;
@property (nonatomic, assign) int64_t countOfBytesExpectedToSend;

@end

@implementation TOSMBSessionUploadTask

- (instancetype)init{
    //This class cannot be instantiated on its own.
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (instancetype)initWithSession:(TOSMBSession *)session
                       filePath:(NSString *)filePath
                destinationPath:(NSString *)destinationPath
                progressHandler:(TOSMBSessionTransferTaskProgressHandler)progressHandler
                 successHandler:(TOSMBSessionTransferTaskSuccessHandler)successHandler
                    failHandler:(TOSMBSessionTransferTaskFailHandler)failHandler
{
    if (self = [super init]) {
        self.session = session;
        self.sourceFilePath = [filePath copy];
        self.destinationFilePath = [destinationPath copy];
        self.progressHandler = [progressHandler copy];
        self.successHandler = [successHandler copy];
        self.failHandler = [failHandler copy];
        self.operations = [NSHashTable<NSOperation *> weakObjectsHashTable];
    }
    return self;
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

#pragma mark - Feedback Methods -

- (void)didSucceedWithFilePath:(NSString *)filePath{
    TOSMBMakeWeakReference();
    NSParameterAssert(self.session);
    [self.session performCallBackWithBlock:^{
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        if (strongSelf.successHandler){
            strongSelf.successHandler(filePath);
        }
    }];
}

- (void)didFailWithError:(NSError *)error{
    TOSMBMakeWeakReference();
    NSParameterAssert(self.session);
    [self.session performCallBackWithBlock:^{
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        if (strongSelf.failHandler){
            strongSelf.failHandler(error);
        }
    }];
}

- (BOOL)shouldNotifyWithProgress:(float)progress{
    float lastProgress = self.lastProgress;
    return (progress>0) && (ABS(lastProgress - progress) > 0.1 ||
                            (fabs(progress - 1.0) < FLT_EPSILON) ||
                            (fabs(progress) < FLT_EPSILON));
}

- (void)progressDidChange:(float)progress{
    if([self shouldNotifyWithProgress:progress] == NO){
        return;
    }
    
    self.lastProgress = progress;
    TOSMBMakeWeakReference();
    NSParameterAssert(self.session);
    [self.session performCallBackWithBlock:^{
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        if (strongSelf.progressHandler){
            strongSelf.progressHandler(strongSelf.countOfBytesSend, strongSelf.countOfBytesExpectedToSend);
        }
    }];
}

- (void)didUpdateWriteBytes:(NSData *)bytesWritten
          totalBytesWritten:(uint64_t)totalBytesWritten
         totalBytesExpected:(uint64_t)totalBytesExpected{
    if (self.countOfBytesExpectedToSend > 0){
        float currentProgress = (float)self.countOfBytesSend/(float)self.countOfBytesExpectedToSend;
        [self progressDidChange:currentProgress];
    }
}

#pragma mark - Uploading -

- (TOSMBSessionFile *)requestFileForItemAtFormattedPath:(NSString *)filePath
                                               fullPath:(NSString *)fullPath
                                                 inTree:(smb_tid)treeID
{
    const char *fileCString = [filePath cStringUsingEncoding:NSUTF8StringEncoding];
    __block smb_stat statBasic = NULL;
    __block smb_stat statStandard = NULL;
    [self.session inSMBCSession:^(smb_session *session) {
        statBasic = smb_fstat_basic(session, treeID, fileCString);
        statStandard = smb_fstat_standard(session, treeID, fileCString);
    }];
    
    if (statBasic == NULL || statStandard == NULL) {
        return nil;
    }
    
    TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithBasicFileInfoStat:statBasic
                                                 standardFileInfoStat:statStandard
                                                             fullPath:filePath];
    
    [self.session inSMBCSession:^(smb_session *session) {
        smb_stat_destroy(statBasic);
        smb_stat_destroy(statStandard);
    }];
    
    return file;
}

- (void)startTaskInternal{
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    TOSMBMakeWeakReference();
    TOSMBMakeWeakReferenceForOperation();
    id executionBlock = ^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        [strongSelf performStartUpload];
    };
    [operation setCompletionBlock:^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        [strongSelf removeCancellableOperation:weakOperation];
    }];
    [self.session addRequestOperation:operation withBlock:executionBlock];
    [self addCancellableOperation:operation];
}

- (void)performStartUpload{
    
    NSParameterAssert(self.session!=nil);
    
    if (self.isCancelled || self.session == nil) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        return;
    }
    
    self.treeID = 0;
    self.fileID = 0;
    
    //---------------------------------------------------------------------------------------
    //Set up paths
    self.uploadTemporaryFilePath =
    [[self.destinationFilePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@",
                                                                                                  [NSString TOSMB_uuidString],
                                                                                                  self.destinationFilePath.pathExtension?:@"tmp"]];
    
    const char *relativeUploadPathCString = [self relativeUploadPathCString];
    
    //---------------------------------------------------------------------------------------
    //Connect to SMB device
    
    //First, check to make sure the file is there, and to acquire its attributes
    NSError *error = [self.session attemptConnection];
    if (error) {
        [self didFailWithError:error];
        [self cleanUp];
        return;
    }
    
    if (self.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        [self cleanUp];
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Connect to share
    
    //Next attach to the share we'll be using
    NSString *shareName = [TOSMBSession shareNameFromPath:self.destinationFilePath];
    const char *shareCString = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    __block smb_tid treeID = 0;
    treeID = [self.session cachedShareIDForName:shareName];
    if (treeID == 0) {
        [self.session inSMBCSession:^(smb_session *session) {
            smb_tree_connect(session, shareCString,&treeID);
        }];
    }
    self.treeID = treeID;
    if (treeID == 0) {
        [self.session removeCachedShareIDForName:shareName];
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed)];
        [self cleanUp];
        return;
    }
    else{
        [self.session cacheShareID:treeID forName:shareName];
    }
    
    if (self.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        [self cleanUp];
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Find the target file
    
    BOOL isDir = NO;
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:self.sourceFilePath isDirectory:&isDir];
    
    if (fileExists == NO) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        [self cleanUp];
        return;
    }
    
    if (isDir) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeDirectoryUploaded)];
        [self cleanUp];
        return;
    }
    
    if (self.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        [self cleanUp];
        return;
    }
    
    NSDictionary *sourceFileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:self.sourceFilePath error:nil];
    self.countOfBytesExpectedToSend = [sourceFileAttributes fileSize];
    
    //---------------------------------------------------------------------------------------
    //Open the file handle
    __block smb_fd fileID = 0;
    [self.session inSMBCSession:^(smb_session *session) {
        smb_fopen(session, treeID, relativeUploadPathCString, SMB_MOD_RW, &fileID);
    }];
    self.fileID = fileID;
    
    if (fileID == 0) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFailToUpload)];
        [self cleanUp];
        return;
    }
    
    if (self.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        [self cleanUp];
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Start uploading
    
    //Open a handle to the file
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:self.sourceFilePath];
    self.fileHandle = fileHandle;
    unsigned long long seekOffset = 0;
    self.countOfBytesSend = seekOffset;
    
    //Perform the file upload
    [self uploadNextChunk];
}

- (void)uploadNextChunk {
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    TOSMBMakeWeakReference();
    TOSMBMakeWeakReferenceForOperation();
    id executionBlock = ^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        int result = [strongSelf performUploadNextChunk];
        if (result == 1) {
            [strongSelf uploadNextChunkAfterDelay];
        }
        else if (result == 0) {
            [strongSelf finishUpload];
        }
    };
    [operation setCompletionBlock:^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        [strongSelf removeCancellableOperation:weakOperation];
    }];
    [self.session addRequestOperation:operation withBlock:executionBlock];
    [self addCancellableOperation:operation];
}

- (void)uploadNextChunkAfterDelay {
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    TOSMBMakeWeakReferenceForOperation();
    TOSMBMakeWeakReference();
    id executionBlock = ^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        NSParameterAssert([NSThread isMainThread]);
        [strongSelf performSelector:@selector(uploadNextChunk)
                         withObject:nil
                         afterDelay:kTOSMBSessionTransferAsyncDelay];
    };
    [operation setCompletionBlock:^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        [strongSelf removeCancellableOperation:weakOperation];
    }];
    [operation addExecutionBlock:executionBlock];
    [[NSOperationQueue mainQueue] addOperation:operation];
    [self addCancellableOperation:operation];
}

- (int)performUploadNextChunk{
    NSInteger bufferSize = kTOSMBSessionTransferTaskBufferSize;
    BOOL uploadError = NO;
    NSInteger dataLength = 0;
    
    @try{[self.fileHandle seekToFileOffset:self.countOfBytesSend];}@catch(NSException *exc){}
    
    NSData *data = nil;
    @try {
        data = [self.fileHandle readDataOfLength:bufferSize];
    }
    @catch (NSException *exception) {
        uploadError = YES;
    }
    dataLength = data.length;
    NSInteger bytesToWrite = dataLength;
    
    if (bytesToWrite > 0) {
        void *bytes = (void *)data.bytes;
        while (bytesToWrite > 0) {
            __block ssize_t write_size = -1;
            [self.session inSMBCSession:^(smb_session *session) {
                write_size = smb_fwrite(session, self.fileID, bytes, bytesToWrite);
            }];
            
            if (write_size == 0){
                break;
            }
            
            if (write_size < 0) {
                uploadError = YES;
                break;
            }
            bytesToWrite -= write_size;
            bytes += write_size;
        }
    }
    
    if (self.isCancelled){
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        [self cleanUp];
        return -1;
    }
    
    if(uploadError){
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFailToUpload)];
        [self cleanUp];
        return -1;
    }
    
    self.countOfBytesSend += dataLength;
    
    [self didUpdateWriteBytes:data
            totalBytesWritten:self.countOfBytesSend
           totalBytesExpected:self.countOfBytesExpectedToSend];
    
    return (dataLength > 0) ? 1 : 0;
}

- (void)finishUpload{
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    TOSMBMakeWeakReference();
    TOSMBMakeWeakReferenceForOperation();
    id executionBlock = ^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        [strongSelf performFinishUpload];
    };
    [operation setCompletionBlock:^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        [strongSelf removeCancellableOperation:weakOperation];
    }];
    [self.session addRequestOperation:operation withBlock:executionBlock];
    [self addCancellableOperation:operation];
}

- (void)performFinishUpload{
    
    @try{[self.fileHandle closeFile];}@catch(NSException *exc){}
    
    __block smb_fd fileID = self.fileID;
    __block smb_tid treeID = self.treeID;
    
    NSString *formattedPath = [TOSMBSession relativeSMBPathFromPath:self.destinationFilePath];
    
    const char *relativeUploadPathCString = [self relativeUploadPathCString];
    const char *relativeToPathCString = [self relativeToPathCString];
    
    if (fileID > 0) {
        [self.session inSMBCSession:^(smb_session *session) {
            smb_fclose(session, fileID);
        }];
    }
    
    if (self.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        [self cleanUp];
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Move the finished file to its destination
    TOSMBSessionFile *existingFile = [self requestFileForItemAtFormattedPath:formattedPath
                                                                    fullPath:self.destinationFilePath
                                                                      inTree:treeID];
    if (existingFile){
        [self.session inSMBCSession:^(smb_session *session) {
            smb_file_rm(session, treeID, relativeToPathCString);
        }];
    }
    
    __block int result = DSM_ERROR_GENERIC;
    [self.session inSMBCSession:^(smb_session *session) {
        result = smb_file_mv(session, treeID, relativeUploadPathCString, relativeToPathCString);
    }];
    
    self.state = TOSMBSessionTransferTaskStateCompleted;
    
    [self cleanUp];
    
    if (result == DSM_SUCCESS) {
        [self didSucceedWithFilePath:self.destinationFilePath];
    }
    else{
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFailToUpload)];
    }
}

- (const char *)relativeUploadPathCString{
    NSString *formattedUploadPath = [TOSMBSession relativeSMBPathFromPath:self.uploadTemporaryFilePath];
    return [formattedUploadPath cStringUsingEncoding:NSUTF8StringEncoding];
}

- (const char *)relativeToPathCString{
    NSString *formattedPath = [TOSMBSession relativeSMBPathFromPath:self.destinationFilePath];
    return [formattedPath cStringUsingEncoding:NSUTF8StringEncoding];
}

- (void)cleanUp{
    __block smb_fd fileID = self.fileID;
    __block smb_tid treeID = self.treeID;
    
    if (fileID > 0) {
        [self.session inSMBCSession:^(smb_session *session) {
            smb_fclose(session, fileID);
        }];
    }
    
    if (treeID > 0) {
        const char *relativeUploadPathCString = self.relativeUploadPathCString;
        [self.session inSMBCSession:^(smb_session *session) {
            smb_file_rm(session, treeID, relativeUploadPathCString);
        }];
    }
}

@end
