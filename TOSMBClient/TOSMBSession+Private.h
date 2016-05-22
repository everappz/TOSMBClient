//
//  TOSMBSession+Private.h
//  MyApp
//
//  Created by Artem Meleshko on 5/4/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import "TOSMBSession.h"
#import "smb_session.h"
#import "smb_share.h"
#import "smb_stat.h"
#import "smb_dir.h"
#import "TODSMSession.h"



@interface TOSMBSession ()

/* The session pointer responsible for this object. */
@property (nonatomic, strong) TODSMSession *dsm_session;
@property (nonatomic, readonly, assign) smb_session *session;
@property (nonatomic, strong) NSDate *lastRequestDate;

/* 1 == Guest, 0 == Logged in, -1 == Logged out */
@property (nonatomic, assign, readwrite) NSInteger guest;

@property (nonatomic, strong) NSOperationQueue *dataQueue; /* Operation queue for asynchronous data requests */

/* Connection/Authentication handling */
- (BOOL)deviceIsOnWiFi;
- (NSError *)attemptConnection;
- (NSError *)attemptConnectionWithSessionPointer:(smb_session *)session;

/* File path parsing */
- (NSString *)shareNameFromPath:(NSString *)path;
- (NSString *)filePathExcludingSharePathFromPath:(NSString *)path;

/* Asynchronous operation management */
- (void)setupDataQueue;

@property (nonatomic, strong)dispatch_queue_t callBackQueue;

@end