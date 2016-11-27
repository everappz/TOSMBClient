//
//  TOSMBCSessionWrapper.m
//  MyApp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import "TOSMBCSessionWrapper.h"
#import "TOSMBSession.h"
#import "smb_share.h"
#import "smb_stat.h"
#import "smb_dir.h"

static const void * const kTOSMBCSessionWrapperSpecificKey = &kTOSMBCSessionWrapperSpecificKey;

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
            return nil;
        }
        self.shares = [[NSMutableDictionary alloc] init];
        _queue = dispatch_queue_create([[NSString stringWithFormat:@"smb.session.wrapper.%@", self] UTF8String], NULL);
        dispatch_queue_set_specific(_queue, kTOSMBCSessionWrapperSpecificKey, (__bridge void *)self, NULL);
    }
    return self;
}

- (void)dealloc{
    [self close];
    if (_queue) {
        _queue = 0x00;
    }
}

- (void)close {
    if(self.smb_session!=NULL){
        [self inSyncQueue:^{
            [self.shares enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
                smb_tid shareID = [obj unsignedShortValue];
                smb_tree_disconnect(self.smb_session, shareID);
            }];
            if([self isConnected]){
                smb_session_logoff(self.smb_session);
            }
            smb_session_destroy(self.smb_session);
            self.smb_session = NULL;
        }];
    }
}

- (void)inSMBSession:(void (^)(smb_session *session))block {
    TOSMBCSessionWrapper *currentSyncQueue = (__bridge id)dispatch_get_specific(kTOSMBCSessionWrapperSpecificKey);
    assert(currentSyncQueue != self && "inSMBSession: was called reentrantly on the same queue, which would lead to a deadlock");
    dispatch_sync(_queue, ^() {
        smb_session *smb_session = self.smb_session;
        if(smb_session!=NULL){
            block(smb_session);
        }
    });
}

- (void)inSyncQueue:(void(^)(void))block{
    TOSMBCSessionWrapper *currentSyncQueue = (__bridge id)dispatch_get_specific(kTOSMBCSessionWrapperSpecificKey);
    if(currentSyncQueue != self){
        dispatch_sync(_queue, ^() {
            block();
        });
    }
    else{
        block();
    }
}

- (smb_tid)cachedShareIDForName:(NSString *)shareName{
    NSParameterAssert(shareName.length>0);
    if(shareName.length>0){
        smb_tid share_id = [[self.shares objectForKey:shareName] unsignedShortValue];
        return share_id;
    }
    return 0;
}

- (void)cacheShareID:(smb_tid)shareID forName:(NSString *)shareName{
    NSParameterAssert(shareName.length>0);
    NSParameterAssert(shareID>0);
    if(shareName.length>0 && shareID>0){
        @synchronized (self) {
            smb_tid cachedShareID = [self cachedShareIDForName:shareName];
            if(shareID!=cachedShareID){
                if(cachedShareID>0 && self.smb_session!=NULL){
                    [self inSyncQueue:^{
                         smb_tree_disconnect(self.smb_session, cachedShareID);
                    }];
                }
                [self.shares setObject:@(shareID) forKey:shareName];
            }
        }
    }
}

- (void)removeCachedShareIDForName:(NSString *)shareName{
    NSParameterAssert(shareName.length>0);
    if(shareName.length>0){
        @synchronized (self) {
            smb_tid cachedShareID = [self cachedShareIDForName:shareName];
            if(cachedShareID>0 && self.smb_session!=NULL){
                [self inSyncQueue:^{
                     smb_tree_disconnect(self.smb_session, cachedShareID);
                }];
            }
            [self.shares removeObjectForKey:shareName];
        }
    }
}

- (BOOL)isConnected{
    return (self.smb_session !=NULL && smb_session_is_guest(self.smb_session) >= 0);
}

- (BOOL)isValid{
    BOOL b = ([self isConnected] && (NSDate.date.timeIntervalSince1970-self.lastRequestDate.timeIntervalSince1970)<kSessionTimeout && self.ipAddress.length>0 && self.userName.length>0);
    return b;
}

- (NSString *)sessionKey{
    return [[self class] sessionKeyForIPAddress:self.ipAddress domain:self.domain userName:self.userName password:self.password];
}

+ (NSString *)sessionKeyForIPAddress:(NSString *)ipAddress
                              domain:(NSString *)domain
                            userName:(NSString *)userName
                            password:(NSString *)password{
    NSString *sessionKey = [NSString stringWithFormat:@"%@:%@:%@:%@",ipAddress,domain,userName,password];
    return sessionKey;
}

@end
