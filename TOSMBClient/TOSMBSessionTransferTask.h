//
//  TOSMBSessionTransferTask.h
//  TOSMBClient
//
//  Created by Artem on 17/05/2021.
//  Copyright © 2021 TOSMB. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TOSMBConstants.h"

@class TOSMBSession;

NS_ASSUME_NONNULL_BEGIN

typedef void(^TOSMBSessionTransferTaskProgressHandler)(uint64_t totalBytesWritten, uint64_t totalBytesExpected);
typedef void(^TOSMBSessionTransferTaskSuccessHandler)(NSString *filePath);
typedef void(^TOSMBSessionTransferTaskFailHandler)(NSError *error);

extern NSInteger kTOSMBSessionTransferTaskBufferSize;
extern NSInteger kTOSMBSessionTransferTaskCallbackDataBufferSize;

@interface TOSMBSessionTransferTask : NSObject

- (TOSMBSession *)session;

- (NSString *)sourceFilePath;

- (NSString *)destinationFilePath;

- (TOSMBSessionTransferTaskState)state;

- (void)start;

- (void)cancel;

- (BOOL)isCancelled;

@end

NS_ASSUME_NONNULL_END
