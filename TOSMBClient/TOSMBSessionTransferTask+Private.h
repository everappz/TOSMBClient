//
//  TOSMBSessionTransferTask+Private.h
//  TOSMBClient
//
//  Created by Artem on 17/05/2021.
//  Copyright © 2021 TOSMB. All rights reserved.
//

#import "TOSMBSessionTransferTask.h"
#import "TOSMBSession.h"
#import "TOSMBSession+Private.h"
#import "NSString+TOSMB.h"
#import "TOSMBSessionFile+Private.h"
#import "TOSMBClient.h"
#import "smb_session.h"
#import "smb_share.h"
#import "smb_file.h"
#import "smb_defs.h"

@interface TOSMBSessionTransferTask()

@property (assign, readwrite) TOSMBSessionTransferTaskState state;

@property (nonatomic, assign) smb_tid treeID;
@property (nonatomic, assign) smb_fd fileID;

@property (nonatomic, copy) NSString *sourceFilePath;
@property (nonatomic, copy) NSString *destinationFilePath;

@property (nonatomic, weak) TOSMBSession *session;
@property (nonatomic, assign) float lastProgress;
@property (nonatomic, strong) NSFileHandle *fileHandle;
@property (nonatomic, strong) NSHashTable <NSOperation *> *operations;

@property (nonatomic, copy) TOSMBSessionTransferTaskProgressHandler progressHandler;
@property (nonatomic, copy) TOSMBSessionTransferTaskSuccessHandler successHandler;
@property (nonatomic, copy) TOSMBSessionTransferTaskFailHandler failHandler;

- (void)startTaskInternal;

- (void)cancelAllOperations;

- (void)addCancellableOperation:(NSOperation *)operation;

- (void)removeCancellableOperation:(NSOperation *)operation;

- (TOSMBSessionFile *)requestFileForItemAtFormattedPath:(NSString *)filePath
                                               fullPath:(NSString *)fullPath
                                                 inTree:(smb_tid)treeID;

@end
