//
//  TOSMBSession+Private.h
//  Everapp
//
//  Created by Artem Meleshko on 5/4/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#import "TOSMBSession.h"
#import "smb_session.h"
#import "smb_share.h"
#import "smb_stat.h"
#import "smb_dir.h"
#import "TOSMBCSessionWrapper.h"



@interface TOSMBSession ()

/* The session pointer responsible for this object. */
@property (nonatomic, strong) TOSMBCSessionWrapper *dsm_session;
@property (nonatomic, strong) NSDate *lastRequestDate;

/* 1 == Guest, 0 == Logged in, -1 == Logged out */
@property (nonatomic, assign, readwrite) NSInteger guest;

@property (nonatomic, assign) BOOL needsReloadSession;

@property (nonatomic, strong) NSOperationQueue *dataQueue; /* Operation queue for asynchronous data requests */

@property (nonatomic, strong) NSOperationQueue *callbackQueue; /* Operation queue for asynchronous callbacks */

/* Connection/Authentication handling */
- (NSError *)attemptConnection;

/* File path parsing */
- (NSString *)shareNameFromPath:(NSString *)path;
- (NSString *)filePathExcludingSharePathFromPath:(NSString *)path;
- (NSString *)relativeSMBPathFromPath:(NSString *)path;

- (void)performCallBackWithBlock:(void(^)(void))block;

@end
