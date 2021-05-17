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

@property (nonatomic, copy) NSString *hostName;
@property (nonatomic, copy) NSString *ipAddress;
@property (nonatomic, copy) NSString *port;
@property (nonatomic, copy) NSString *userName;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy) NSString *domain;

/* The session pointer responsible for this object. */
@property (nonatomic, strong) TOSMBCSessionWrapper *dsm_session;
@property (nonatomic, strong) NSDate *lastRequestDate;

@property (nonatomic, assign) BOOL useInternalNameResolution;
@property (atomic, assign) BOOL needsReloadSession;

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
- (void)addRequestOperation:(NSOperation *)op;

/* SMB Session */
- (void)inSMBCSession:(void (^)(smb_session *session))block;

- (smb_tid)cachedShareIDForName:(NSString *)shareName;
- (void)cacheShareID:(smb_tid)shareID forName:(NSString *)shareName;
- (void)removeCachedShareIDForName:(NSString *)shareName;

@end
