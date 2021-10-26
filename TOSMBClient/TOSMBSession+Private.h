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
#import "TOSMBCSessionWrapper+Private.h"


@interface TOSMBSession ()

@property (atomic, copy) NSString *hostName;
@property (atomic, copy) NSString *ipAddress;
@property (atomic, copy) NSString *port;
@property (atomic, copy) NSString *userName;
@property (atomic, copy) NSString *password;
@property (atomic, copy) NSString *domain;

/* The session pointer responsible for this object. */
@property (nonatomic, strong) TOSMBCSessionWrapper *smbSessionWrapper;
@property (nonatomic, strong) NSRecursiveLock *smbSessionLock;
@property (nonatomic, strong) NSDate *lastRequestDate;

@property (atomic, assign) BOOL useInternalNameResolution;

/* Operation queue for asynchronous data requests */
@property (nonatomic, strong) NSOperationQueue *requestsQueue;

/* Operation queue for asynchronous callbacks */
@property (nonatomic, strong) NSOperationQueue *callbackQueue;

/* Connection/Authentication handling */
- (NSError *)attemptConnection;

/* File path parsing */
+ (NSString *)shareNameFromPath:(NSString *)path;
+ (NSString *)filePathExcludingShareNameFromPath:(NSString *)path;
+ (NSString *)relativeSMBPathFromPath:(NSString *)path;

- (void)performCallBackWithBlock:(void(^)(void))block;
- (NSBlockOperation *)addRequestOperation:(NSBlockOperation *)operation
                  withBlock:(void(^)(void))operationBlock;

/* SMB Session */
- (void)inSMBCSession:(void (^)(smb_session *session))block;

- (smb_tid)cachedShareIDForName:(NSString *)shareName;
- (void)cacheShareID:(smb_tid)shareID forName:(NSString *)shareName;
- (void)removeCachedShareIDForName:(NSString *)shareName;

@end
