//
//  TOSMBSessionTransferTask.m
//  TOSMBClient
//
//  Created by Artem on 17/05/2021.
//  Copyright © 2021 TOSMB. All rights reserved.
//

#import "TOSMBSessionTransferTask.h"
#import "TOSMBSessionTransferTask+Private.h"

NSInteger kTOSMBSessionTransferTaskBufferSize = 32768;
NSInteger kTOSMBSessionTransferTaskCallbackDataBufferSize = 262144; // 8 * kTOSMBSessionTransferTaskBufferSize
NSTimeInterval kTOSMBSessionTransferAsyncDelay = 0.05;


@implementation TOSMBSessionTransferTask

- (void)dealloc{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

#pragma mark - Public Control Methods -

- (void)start{
    if (self.state == TOSMBSessionTransferTaskStateRunning){
        return;
    }
    self.state = TOSMBSessionTransferTaskStateRunning;
    [self startTaskInternal];
}

- (void)startTaskInternal{
    NSParameterAssert(NO);
}

- (BOOL)isCancelled{
    return self.state == TOSMBSessionTransferTaskStateCancelled;
}

- (void)cancel{
    self.state = TOSMBSessionTransferTaskStateCancelled;
    [self cancelAllOperations];
}

- (void)cancelAllOperations{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    @synchronized (self.operations) {
        [[self.operations allObjects] makeObjectsPerformSelector:@selector(cancel)];
    }
}

- (void)addCancellableOperation:(NSOperation *)operation{
    NSParameterAssert([operation isKindOfClass:[NSOperation class]]);
    if ([operation isKindOfClass:[NSOperation class]]) {
        @synchronized (self.operations) {
            [self.operations addObject:operation];
        }
    }
}

- (void)removeCancellableOperation:(NSOperation *)operation{
    NSParameterAssert([operation isKindOfClass:[NSOperation class]]);
    if ([operation isKindOfClass:[NSOperation class]]) {
        @synchronized (self.operations) {
            [self.operations removeObject:operation];
        }
    }
}

@end
