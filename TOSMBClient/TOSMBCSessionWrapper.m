//
//  TOSMBCSessionWrapper.m
//  Everapp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#import "TOSMBCSessionWrapper.h"
#import "TOSMBSession.h"
#import "smb_share.h"
#import "smb_stat.h"
#import "smb_dir.h"


@interface TOSMBCSessionWrapper()

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
    }
    return self;
}

- (void)dealloc{
    NSParameterAssert(self.smb_session==NULL);
    [self close];
}

- (void)close{
    @synchronized(self){
        if(self.smb_session!=NULL){
            [self.shares enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
                smb_tid shareID = [obj unsignedShortValue];
                smb_tree_disconnect(self.smb_session, shareID);
            }];
            if(smb_session_is_guest(self.smb_session) >= 0){
                smb_session_logoff(self.smb_session);
            }
            smb_session_destroy(self.smb_session);
            self.smb_session = NULL;
        }
    }
}

- (void)inSMBCSession:(void (^)(smb_session *session))block {
    @synchronized(self){
        smb_session *smb_session = self.smb_session;
        if(smb_session!=NULL && block){
            block(smb_session);
        }
    }
}

- (smb_tid)cachedShareIDForName:(NSString *)shareName{
    NSParameterAssert(shareName.length>0);
    if(shareName.length>0){
        @synchronized(self){
            smb_tid share_id = [[self.shares objectForKey:shareName] unsignedShortValue];
            return share_id;
        }
    }
    return 0;
}

- (void)cacheShareID:(smb_tid)shareID forName:(NSString *)shareName{
    NSParameterAssert(shareName.length>0);
    NSParameterAssert(shareID>0);
    if(shareName.length>0 && shareID>0){
        @synchronized(self){
            smb_tid cachedShareID = [self cachedShareIDForName:shareName];
            if(shareID!=cachedShareID){
                if(cachedShareID>0 && self.smb_session!=NULL){
                    smb_tree_disconnect(self.smb_session, cachedShareID);
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
                smb_tree_disconnect(self.smb_session, cachedShareID);
            }
            [self.shares removeObjectForKey:shareName];
        }
    }
}

- (BOOL)isConnected{
    BOOL connected = NO;
    @synchronized(self){
        connected = (self.smb_session !=NULL && smb_session_is_guest(self.smb_session) >= 0);
    }
    return connected;
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
