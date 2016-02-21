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

// -------------------------------------------------------------------------
// Private methods in TOSMBSession shared here

@interface TOSMBSession ()

@property (readonly) NSOperationQueue *transferQueue;

- (NSError *)attemptConnectionWithSessionPointer:(smb_session *)session;
- (NSString *)shareNameFromPath:(NSString *)path;
- (NSString *)filePathExcludingSharePathFromPath:(NSString *)path;
- (void)resumeDownloadTask:(TOSMBSessionDownloadTask *)task;


@end

// -------------------------------------------------------------------------

@interface TOSMBSessionDownloadTask ()

@property (assign, readwrite) TOSMBSessionTransferTaskState state;

@property (nonatomic, copy) NSString *sourceFilePath;
@property (nonatomic, copy) NSString *destinationFilePath;
@property (nonatomic, copy) NSString *tempFilePath;

@property (nonatomic, weak) TOSMBSession *session;
@property (nonatomic, strong) TOSMBSessionFile *file;
@property (assign) smb_session *downloadSession;
@property (nonatomic, strong) NSBlockOperation *downloadOperation;

@property (assign,readwrite) int64_t countOfBytesReceived;
@property (assign,readwrite) int64_t countOfBytesExpectedToReceive;

@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTaskIdentifier;

/** Feedback handlers */
@property (nonatomic, copy) void (^progressHandler)(uint64_t totalBytesWritten, uint64_t totalBytesExpected);
@property (nonatomic, copy) void (^successHandler)(NSString *filePath);
@property (nonatomic, copy) void (^failHandler)(NSError *error);

/* Download methods */
- (void)setupDownloadOperation;
- (void)performDownloadWithOperation:(__weak NSBlockOperation *)weakOperation;
- (TOSMBSessionFile *)requestFileForItemAtPath:(NSString *)filePath inTree:(smb_tid)treeID;

/* File Path Methods */
- (NSString *)hashForFilePath;
- (NSString *)filePathForTemporaryDestination;
- (NSString *)finalFilePathForDownloadedFile;
- (NSString *)documentsDirectory;

/* Feedback events sent to either the delegate or callback blocks */
- (void)didSucceedWithFilePath:(NSString *)filePath;
- (void)didFailWithError:(NSError *)error;
- (void)didUpdateWriteBytes:(NSData *)bytesWritten totalBytesWritten:(uint64_t)totalBytesWritten totalBytesExpected:(uint64_t)totalBytesExpected;
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
        _session = session;
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
        _session = session;
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
    if(self.downloadSession!=NULL){
        smb_session_destroy(self.downloadSession);
        self.downloadSession = NULL;
    }
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
    [self.session.transferQueue addOperation:self.downloadOperation];
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
    id deleteBlock = ^{
        [[NSFileManager defaultManager] removeItemAtPath:self.tempFilePath error:nil];
    };
    NSBlockOperation *deleteOperation = [[NSBlockOperation alloc] init];
    [deleteOperation addExecutionBlock:deleteBlock];
    [self.session.transferQueue addOperation:deleteOperation];
    self.state = TOSMBSessionTransferTaskStateCancelled;
}

#pragma mark - Feedback Methods -

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
    
    __weak typeof (self) weakSelf = self;
    
    [self.session performCallBackWithBlock:^{
        if (weakSelf.delegate && [weakSelf.delegate respondsToSelector:@selector(downloadTask:didFinishDownloadingToPath:)]){
            [weakSelf.delegate downloadTask:weakSelf didFinishDownloadingToPath:filePath];
        }
        if (weakSelf.successHandler){
            weakSelf.successHandler(filePath);
        }
    }];
    
}

- (void)didFailWithError:(NSError *)error{

    __weak typeof (self) weakSelf = self;
    
    [self.session performCallBackWithBlock:^{
        if (weakSelf.delegate && [weakSelf.delegate respondsToSelector:@selector(downloadTask:didCompleteWithError:)]){
            [weakSelf.delegate downloadTask:weakSelf didCompleteWithError:error];
        }
        if (weakSelf.failHandler){
            weakSelf.failHandler(error);
        }
    }];
}

- (void)didUpdateWriteBytes:(NSData *)bytesWritten totalBytesWritten:(uint64_t)totalBytesWritten totalBytesExpected:(uint64_t)totalBytesExpected{
    __weak typeof (self) weakSelf = self;
    [self.session performCallBackWithBlock:^{
        if (weakSelf.delegate && [weakSelf.delegate respondsToSelector:@selector(downloadTask:didWriteBytes:totalBytesReceived:totalBytesExpectedToReceive:)]){
            [weakSelf.delegate downloadTask:weakSelf didWriteBytes:bytesWritten totalBytesReceived:weakSelf.countOfBytesReceived totalBytesExpectedToReceive:weakSelf.countOfBytesExpectedToReceive];
        }
        if (weakSelf.progressHandler){
            weakSelf.progressHandler(weakSelf.countOfBytesReceived, weakSelf.countOfBytesExpectedToReceive);
        }
    }];
}

- (void)didResumeAtOffset:(uint64_t)bytesWritten totalBytesExpected:(uint64_t)totalBytesExpected{
    __weak typeof (self) weakSelf = self;
    [self.session performCallBackWithBlock:^{
        if (weakSelf.delegate && [weakSelf.delegate respondsToSelector:@selector(downloadTask:didResumeAtOffset:totalBytesExpectedToReceive:)]){
            [weakSelf.delegate downloadTask:weakSelf didResumeAtOffset:bytesWritten totalBytesExpectedToReceive:totalBytesExpected];
        }
    }];
}

#pragma mark - Downloading -

- (TOSMBSessionFile *)requestFileForItemAtPath:(NSString *)filePath inTree:(smb_tid)treeID{
    const char *fileCString = [filePath cStringUsingEncoding:NSUTF8StringEncoding];
    smb_stat fileStat = smb_fstat(self.downloadSession, treeID, fileCString);
    if (!fileStat){
        return nil;
    }
    TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:fileStat parentDirectoryFilePath:filePath];
    smb_stat_destroy(fileStat);
    return file;
}

- (void)setupDownloadOperation{
    if (self.downloadOperation){
        return;
    }
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    __weak typeof (self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    
    id executionBlock = ^{
        [weakSelf performDownloadWithOperation:weakOperation];
    };
    [operation addExecutionBlock:executionBlock];
    operation.completionBlock = ^{
        weakSelf.downloadOperation = nil;
    };

    self.downloadOperation = operation;
}

- (void)performDownloadWithOperation:(__weak NSBlockOperation *)weakOperation{
    
    if (weakOperation.isCancelled)
        return;
    
    smb_tid treeID = -1;
    smb_fd fileID = 0;
    
    //---------------------------------------------------------------------------------------
    //Set up a cleanup block that'll release any handles before cancellation
    void (^cleanup)(void) = ^{
        
        //Release the background task handler, making the app eligible to be suspended now
        if (self.backgroundTaskIdentifier){
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskIdentifier];
        }
        
        if (self.downloadSession && fileID){
            smb_fclose(self.downloadSession, fileID);
        }
        
        if (self.downloadSession && treeID){
            smb_tree_disconnect(self.downloadSession, treeID);
        }

        if (self.downloadSession!=NULL) {
            smb_session_destroy(self.downloadSession);
            self.downloadSession = NULL;
        }
    };
    
    //---------------------------------------------------------------------------------------
    //Connect to SMB device
    
    self.downloadSession = smb_session_new();
    
    //First, check to make sure the file is there, and to acquire its attributes
    NSError *error = [self.session attemptConnectionWithSessionPointer:self.downloadSession];
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
    NSString *shareName = [self.session shareNameFromPath:self.sourceFilePath];
    const char *shareCString = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    treeID = smb_tree_connect(self.downloadSession, shareCString);
    if (!treeID) {
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
    
    NSString *formattedPath = [self.session filePathExcludingSharePathFromPath:self.sourceFilePath];
    formattedPath = [NSString stringWithFormat:@"\\%@",formattedPath];
    formattedPath = [formattedPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    
    //Get the file info we'll be working off
    self.file = [self requestFileForItemAtPath:formattedPath inTree:treeID];
    if (self.file == nil) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        cleanup();
        return;
    }
    
    if (weakOperation.isCancelled) {
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
    
    fileID = smb_fopen(self.downloadSession, treeID, [formattedPath cStringUsingEncoding:NSUTF8StringEncoding], SMB_MOD_RO);
    if (!fileID) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        cleanup();
        return;
    }
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }
    
    
    //---------------------------------------------------------------------------------------
    //Start downloading
    
    //Create the directories to the download destination
    [[NSFileManager defaultManager] createDirectoryAtPath:[self.tempFilePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    
    //Create a new blank file to write to
    if (self.canBeResumed == NO)
        [[NSFileManager defaultManager] createFileAtPath:self.tempFilePath contents:nil attributes:nil];
    
    //Open a handle to the file and skip ahead if we're resuming
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.tempFilePath];
    unsigned long long seekOffset = (ssize_t)[fileHandle seekToEndOfFile];
    if(self.seekOffset!=NSNotFound){
        seekOffset = self.seekOffset;
    }
    self.countOfBytesReceived = seekOffset;
    
    //Create a background handle so the download will continue even if the app is suspended
    self.backgroundTaskIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{ [self suspend]; }];
    
    if (seekOffset > 0) {
        smb_fseek(self.downloadSession, fileID, (ssize_t)seekOffset, SMB_SEEK_SET);
        [self didResumeAtOffset:seekOffset totalBytesExpected:self.countOfBytesExpectedToReceive];
    }
    
    //Perform the file download
    uint64_t bytesRead = 0;
    NSInteger bufferSize = 32768;
    char *buffer = malloc(bufferSize);
    
    do {
        bytesRead = smb_fread(self.downloadSession, fileID, buffer, bufferSize);
        NSData *data = [NSData dataWithBytes:buffer length:bufferSize];
        [fileHandle writeData:data];
        if (weakOperation.isCancelled){
            break;
        }
        self.countOfBytesReceived += bytesRead;
        [self didUpdateWriteBytes:data totalBytesWritten:self.countOfBytesReceived totalBytesExpected:self.countOfBytesExpectedToReceive];
    } while (bytesRead > 0);
    
    //Set the modification date to match the one on the SMB device so we can compare the two at a later date
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate:self.file.modificationTime} ofItemAtPath:self.tempFilePath error:nil];
    
    free(buffer);
    [fileHandle closeFile];
    
    if (weakOperation.isCancelled) {
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
