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

#import "TOSMBSessionDownloadTask.h"
#import "TOSMBSessionTransferTask+Private.h"

@interface TOSMBSessionDownloadTask ()

@property (nonatomic, copy) NSString *tempFilePath;
@property (nonatomic, strong) NSMutableData *callbackData;

@property (nonatomic, strong) TOSMBSessionFile *file;

@property (nonatomic, assign) int64_t countOfBytesReceived;
@property (nonatomic, assign) int64_t countOfBytesExpectedToReceive;

@end

@implementation TOSMBSessionDownloadTask

- (instancetype)init{
    //This class cannot be instantiated on its own.
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (instancetype)initWithSession:(TOSMBSession *)session
                       filePath:(NSString *)filePath
                destinationPath:(NSString *)destinationPath
                       delegate:(id<TOSMBSessionDownloadTaskDelegate>)delegate
{
    if (self = [super init]) {
        self.session = session;
        self.sourceFilePath = [filePath copy];
        self.destinationFilePath = destinationPath.length ? [destinationPath copy] : [self documentsDirectory];
        self.delegate = delegate;
        self.seekOffset = NSNotFound;
        self.tempFilePath = [self filePathForTemporaryDestination];
    }
    return self;
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
        self.destinationFilePath = destinationPath.length ? [destinationPath copy] : [self documentsDirectory];
        self.progressHandler = [progressHandler copy];
        self.successHandler = [successHandler copy];
        self.failHandler = [failHandler copy];
        self.seekOffset = NSNotFound;
        self.tempFilePath = [self filePathForTemporaryDestination];
    }
    return self;
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

#pragma mark - Temporary Destination Methods -

- (NSString *)filePathForTemporaryDestination{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.tmp",[NSString TOSMB_uuidString]]];
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

- (void)cancel{
    [super cancel];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    @try{[[NSFileManager defaultManager] removeItemAtPath:self.tempFilePath error:nil];}@catch(NSException *exc){}
}

#pragma mark - Private Control Methods -

- (void)fail{
    if (self.state != TOSMBSessionTransferTaskStateRunning){
        return;
    }
    [self cancel];
    self.state = TOSMBSessionTransferTaskStateFailed;
}

- (void)didSucceedWithFilePath:(NSString *)filePath{
    TOSMBMakeWeakReference();
    [self.session performCallBackWithBlock:^{
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        if (strongSelf.delegate && [strongSelf.delegate respondsToSelector:@selector(downloadTask:didFinishDownloadingToPath:)]){
            [strongSelf.delegate downloadTask:strongSelf didFinishDownloadingToPath:filePath];
        }
        if (strongSelf.successHandler){
            strongSelf.successHandler(filePath);
        }
    }];
}

- (void)didFailWithError:(NSError *)error{
    TOSMBMakeWeakReference();
    [self.session performCallBackWithBlock:^{
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        if (strongSelf.delegate && [strongSelf.delegate respondsToSelector:@selector(downloadTask:didCompleteWithError:)]){
            [strongSelf.delegate downloadTask:strongSelf didCompleteWithError:error];
        }
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
    [self.session performCallBackWithBlock:^{
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        if (strongSelf.progressHandler){
            strongSelf.progressHandler(strongSelf.countOfBytesReceived, strongSelf.countOfBytesExpectedToReceive);
        }
    }];
}

- (void)didUpdateWriteBytes:(NSData *)bytesWritten{
    TOSMBMakeWeakReference();
    [self.session performCallBackWithBlock:^{
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        if (strongSelf.delegate && [strongSelf.delegate respondsToSelector:@selector(downloadTask:didWriteBytes:totalBytesReceived:totalBytesExpectedToReceive:)]){
            [strongSelf.delegate downloadTask:strongSelf
                                didWriteBytes:bytesWritten
                           totalBytesReceived:strongSelf.countOfBytesReceived
                  totalBytesExpectedToReceive:strongSelf.countOfBytesExpectedToReceive];
        }
    }];
    if (self.countOfBytesExpectedToReceive > 0){
        float currentProgress = (float)self.countOfBytesReceived/(float)self.countOfBytesExpectedToReceive;
        [self progressDidChange:currentProgress];
    }
}

- (void)didResumeAtOffset:(uint64_t)bytesWritten totalBytesExpected:(uint64_t)totalBytesExpected{
    TOSMBMakeWeakReference();
    [self.session performCallBackWithBlock:^{
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        if (strongSelf.delegate && [strongSelf.delegate respondsToSelector:@selector(downloadTask:didResumeAtOffset:totalBytesExpectedToReceive:)]){
            [strongSelf.delegate downloadTask:strongSelf didResumeAtOffset:bytesWritten totalBytesExpectedToReceive:totalBytesExpected];
        }
    }];
}

#pragma mark - Downloading -

- (TOSMBSessionFile *)requestFileForItemAtFormattedPath:(NSString *)filePath
                                               fullPath:(NSString *)fullPath
                                                 inTree:(smb_tid)treeID
{
    const char *fileCString = [filePath cStringUsingEncoding:NSUTF8StringEncoding];
    __block smb_stat fileStat = NULL;
    [self.session inSMBCSession:^(smb_session *session) {
        fileStat = smb_fstat(session, treeID, fileCString);
    }];
    if (fileStat == NULL) {
        return nil;
    }
    TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:fileStat
                                            parentDirectoryFilePath:[fullPath stringByDeletingLastPathComponent]];
    [self.session inSMBCSession:^(smb_session *session) {
        smb_stat_destroy(fileStat);
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
        [strongSelf performStartDownload];
    };
    [operation addExecutionBlock:executionBlock];
    [operation setCompletionBlock:^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        [strongSelf removeCancellableOperation:weakOperation];
    }];
    [self.session addRequestOperation:operation];
    [self addCancellableOperation:operation];
}

- (void)cleanUp{
    __block smb_fd fileID = self.fileID;
    if (fileID > 0) {
        [self.session inSMBCSession:^(smb_session *session) {
            smb_fclose(session, fileID);
        }];
    }
}

- (void)performStartDownload{
    if (self.isCancelled || self.session==nil) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        return;
    }
    
    self.treeID = 0;
    self.fileID = 0;
    
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
    NSString *shareName = [TOSMBSession shareNameFromPath:self.sourceFilePath];
    const char *shareCString = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    __block smb_tid treeID = [self.session cachedShareIDForName:shareName];
    
    if (treeID == 0) {
        [self.session inSMBCSession:^(smb_session *session) {
            smb_tree_connect(session, shareCString, &treeID);
        }];
    }
    if (treeID == 0) {
        [self.session removeCachedShareIDForName:shareName];
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed)];
        [self cleanUp];
        return;
    }
    else{
        [self.session cacheShareID:treeID forName:shareName];
    }
    self.treeID = treeID;
    
    if (self.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        [self cleanUp];
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Find the target file
    
    NSString *formattedPath = [TOSMBSession relativeSMBPathFromPath:self.sourceFilePath];
    
    //Get the file info we'll be working off
    self.file = [self requestFileForItemAtFormattedPath:formattedPath
                                               fullPath:self.sourceFilePath
                                                 inTree:treeID];
    if (self.file == nil) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        [self cleanUp];
        return;
    }
    
    if (self.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        [self cleanUp];
        return;
    }
    
    if (self.file.directory) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeDirectoryDownloaded)];
        [self cleanUp];
        return;
    }
    
    self.countOfBytesExpectedToReceive = self.file.fileSize;
    
    //---------------------------------------------------------------------------------------
    //Open the file handle
    __block smb_fd fileID = 0;
    [self.session inSMBCSession:^(smb_session *session) {
        smb_fopen(session, treeID, [formattedPath cStringUsingEncoding:NSUTF8StringEncoding], SMB_MOD_RO, &fileID);
    }];
    
    if (fileID == 0) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        [self cleanUp];
        return;
    }
    
    self.fileID = fileID;
    
    if (self.isCancelled) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        [self cleanUp];
        return;
    }
    
    
    //---------------------------------------------------------------------------------------
    //Start downloading
    
    //Create the directories to the download destination
    [[NSFileManager defaultManager] createDirectoryAtPath:[self.tempFilePath stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    //Create a new blank file to write to
    [[NSFileManager defaultManager] removeItemAtPath:self.tempFilePath error:nil];
    [[NSFileManager defaultManager] createFileAtPath:self.tempFilePath contents:nil attributes:nil];
    
    //Open a handle to the file and skip ahead if we're resuming
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.tempFilePath];
    self.fileHandle = fileHandle;
    
    unsigned long long seekOffset = (ssize_t)[fileHandle seekToEndOfFile];
    if (self.seekOffset != NSNotFound) {
        seekOffset = self.seekOffset;
    }
    self.countOfBytesReceived = seekOffset;
    
    if (seekOffset > 0) {
        [self.session inSMBCSession:^(smb_session *session) {
            smb_fseek(session, fileID, (ssize_t)seekOffset, SMB_SEEK_SET);
        }];
        [self didResumeAtOffset:seekOffset
             totalBytesExpected:self.countOfBytesExpectedToReceive];
    }
    
    //Perform the file download
    self.callbackData = [[NSMutableData alloc] init];
    [self downloadNextChunk];
}

- (void)downloadNextChunk {
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    TOSMBMakeWeakReference();
    TOSMBMakeWeakReferenceForOperation();
    id executionBlock = ^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        int result = [strongSelf performDownloadNextChunk];
        if (result == 1) {
            [strongSelf downloadNextChunkAfterDelay];
        }
        else if (result == 0) {
            [strongSelf finishDownload];
        }
    };
    [operation addExecutionBlock:executionBlock];
    [operation setCompletionBlock:^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        [strongSelf removeCancellableOperation:weakOperation];
    }];
    [self.session addRequestOperation:operation];
    [self addCancellableOperation:operation];
}

- (void)downloadNextChunkAfterDelay {
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    TOSMBMakeWeakReferenceForOperation();
    TOSMBMakeWeakReference();
    id executionBlock = ^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        NSParameterAssert([NSThread isMainThread]);
        [strongSelf performSelector:@selector(downloadNextChunk)
                         withObject:nil
                         afterDelay:kTOSMBSessionTransferAsyncDelay];
    };
    [operation addExecutionBlock:executionBlock];
    [[NSOperationQueue mainQueue] addOperation:operation];
    [self addCancellableOperation:operation];
}

- (int)performDownloadNextChunk{
    NSInteger bufferSize = kTOSMBSessionTransferTaskBufferSize;
    NSInteger callbackDataBufferSize = kTOSMBSessionTransferTaskCallbackDataBufferSize;
    
    char *buffer = malloc(bufferSize);
    
    __block int64_t bytesRead = 0;
    __block smb_fd fileID = self.fileID;
    
    [self.session inSMBCSession:^(smb_session *session) {
        bytesRead = smb_fread(session, fileID, buffer, bufferSize);
    }];
    
    if (bytesRead < 0) {
        [self fail];
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileDownloadFailed)];
        [self cleanUp];
        return -1;
    }
    
    //Save them to the file handle (And ensure the NSData object is flushed immediately)
    NSData *data = [NSData dataWithBytes:buffer length:bytesRead];
    @try {
        [self.fileHandle writeData:data];
        
        //Ensure the data is properly written to disk before proceeding
        [self.fileHandle synchronizeFile];
    } @catch (NSException *exception) {}
    
    if (self.isCancelled){
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        [self cleanUp];
        return -1;
    }
    self.countOfBytesReceived += bytesRead;
    [self.callbackData appendData:data];
    if (self.callbackData.length >= callbackDataBufferSize || bytesRead == 0) {
        [self didUpdateWriteBytes:self.callbackData];
        self.callbackData = [[NSMutableData alloc] init];
    }
    
    free(buffer);
    
    return bytesRead > 0 ? 1 : 0;
}

- (void)finishDownload{
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    TOSMBMakeWeakReference();
    TOSMBMakeWeakReferenceForOperation();
    id executionBlock = ^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        [strongSelf performFinishDownload];
    };
    [operation addExecutionBlock:executionBlock];
    [operation setCompletionBlock:^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        [strongSelf removeCancellableOperation:weakOperation];
    }];
    [self.session addRequestOperation:operation];
    [self addCancellableOperation:operation];
}

- (void)performFinishDownload{
    @try{[self.fileHandle closeFile];}@catch(NSException *exc){}

    //Set the modification date to match the one on the SMB device so we can compare the two at a later date
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate:self.file.modificationTime}
                                     ofItemAtPath:self.tempFilePath
                                            error:nil];
    
    if (self.isCancelled  || self.state != TOSMBSessionTransferTaskStateRunning) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeCancelled)];
        [self cleanUp];
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Move the finished file to its destination
    
    //Workout the destination of the file and move it
    NSString *finalDestinationPath = [self finalFilePathForDownloadedFile];
    [[NSFileManager defaultManager] moveItemAtPath:self.tempFilePath toPath:finalDestinationPath error:nil];
    
    self.state = TOSMBSessionTransferTaskStateCompleted;
    
    //Perform a final cleanup of all handles and references
    [self cleanUp];
    
    //Alert the delegate that we finished, so they may perform any additional cleanup operations
    [self didSucceedWithFilePath:finalDestinationPath];
}

@end

