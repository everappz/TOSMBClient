//
//  TOSMBCSessionWrapper.m
//  Everapp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#import "TOSMBCSessionWrapper.h"
#import "TOSMBCSessionWrapper+Private.h"
#import "TOSMBConstants.h"
#import "TOSMBSession.h"
#import "smb_share.h"
#import "smb_stat.h"
#import "smb_dir.h"

static const void * const kTOSMBCSessionWrapperQueueSpecificKey = &kTOSMBCSessionWrapperQueueSpecificKey;

@interface TOSMBCSessionWrapper(){
    dispatch_queue_t    _queue;
}

@property (nonatomic,assign) smb_session *smb_session;
@property (nonatomic,strong) NSMutableDictionary *shares;

@end



@implementation TOSMBCSessionWrapper

- (instancetype)init{
    self = [super init];
    if(self){
        self.smb_session = smb_session_new();
        if(self.smb_session == NULL){
            NSParameterAssert(NO);
            return nil;
        }
        self.shares = [[NSMutableDictionary alloc] init];
        _queue = dispatch_queue_create([[NSString stringWithFormat:@"tosmb_session_wrapper.%@", self] UTF8String], NULL);
        dispatch_queue_set_specific(_queue, kTOSMBCSessionWrapperQueueSpecificKey, (__bridge void *)self, NULL);
    }
    return self;
}

- (void)dealloc{
    NSParameterAssert(self.smb_session==NULL);
}

- (void)close{
    TOSMBMakeWeakReference();
    [self inSMBCSession:^(smb_session *session) {
        TOSMBMakeStrongFromWeakReference();
        if(session != NULL){
            [strongSelf.shares enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
                smb_tid shareID = [obj unsignedShortValue];
                smb_tree_disconnect(session, shareID);
            }];
            if(smb_session_is_guest(session) >= 0){
                smb_session_logoff(session);
            }
            smb_session_destroy(session);
            strongSelf.smb_session = NULL;
        }
    }];
}

- (void)inSMBCSession:(void (^)(smb_session *session))block {
    TOSMBCSessionWrapper *currentSyncQueue = (__bridge id)dispatch_get_specific(kTOSMBCSessionWrapperQueueSpecificKey);
    NSParameterAssert(currentSyncQueue != self);
    if (currentSyncQueue == self) {
        return;
    }
    TOSMBMakeWeakReference();
    dispatch_sync(_queue, ^() {
        TOSMBMakeStrongFromWeakReference();
        smb_session *smb_session = [strongSelf smb_session];
        if(smb_session != NULL && block){
            block(smb_session);
        }
    });
}

- (smb_tid)cachedShareIDForName:(NSString *)shareName{
    NSParameterAssert(shareName.length>0);
    __block smb_tid share_id = 0;
    TOSMBMakeWeakReference();
    [self inSMBCSession:^(smb_session *session) {
        TOSMBMakeStrongFromWeakReference();
        share_id = [[strongSelf.shares objectForKey:shareName] unsignedShortValue];
    }];
    return share_id;
}

- (void)cacheShareID:(smb_tid)shareID forName:(NSString *)shareName{
    NSParameterAssert(shareName.length>0);
    NSParameterAssert(shareID>0);
    __block BOOL removeShare = NO;
    __block smb_tid cachedShareID = 0;
    if(shareName.length>0 && shareID>0){
        TOSMBMakeWeakReference();
        [self inSMBCSession:^(smb_session *session) {
            TOSMBMakeStrongFromWeakReference();
            cachedShareID = [[strongSelf.shares objectForKey:shareName] unsignedShortValue];
            if(shareID!=cachedShareID){
                removeShare = cachedShareID>0;
                [strongSelf.shares setObject:@(shareID) forKey:shareName];
            }
            if(removeShare){
                smb_tree_disconnect(session, cachedShareID);
            }
        }];
    }
}

- (void)removeCachedShareIDForName:(NSString *)shareName{
    NSParameterAssert(shareName.length>0);
    if(shareName.length>0){
        __block smb_tid cachedShareID = 0;
        __block BOOL removeShare = NO;
        TOSMBMakeWeakReference();
        [self inSMBCSession:^(smb_session *session) {
            TOSMBMakeStrongFromWeakReference();
            cachedShareID = [[strongSelf.shares objectForKey:shareName] unsignedShortValue];
            removeShare = (cachedShareID>0);
            [strongSelf.shares removeObjectForKey:shareName];
            if(removeShare){
                smb_tree_disconnect(session, cachedShareID);
            }
        }];
    }
}

- (BOOL)isConnected{
    __block BOOL connected = NO;
    [self inSMBCSession:^(smb_session *session) {
        connected = (session !=NULL && smb_session_is_guest(session) >= 0);
    }];
    return connected;
}

- (BOOL)isValid{
    const BOOL valid = [self isConnected] &&
    (NSDate.date.timeIntervalSince1970 - self.lastRequestDate.timeIntervalSince1970) < kTOSMBSessionTimeout &&
    self.ipAddress.length > 0 &&
    self.userName.length > 0;
    return valid;
}

- (NSString *)sessionKey{
    return [[self class] sessionKeyForIPAddress:self.ipAddress
                                         domain:self.domain
                                       userName:self.userName
                                       password:self.password];
}

+ (NSString *)sessionKeyForIPAddress:(NSString *)ipAddress
                              domain:(NSString *)domain
                            userName:(NSString *)userName
                            password:(NSString *)password{
    NSString *sessionKey = [NSString stringWithFormat:@"%@:%@:%@:%@",ipAddress,domain,userName,password];
    return sessionKey;
}

@end
