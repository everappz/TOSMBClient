//
//  TODSMSession.m
//  MyApp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import "TODSMSession.h"
#import "TOSMBSession.h"
#import "smb_share.h"
#import "smb_stat.h"
#import "smb_dir.h"


@interface TODSMSession()

@property (nonatomic, assign) smb_session *smb_session;

@property (nonatomic,strong) NSMutableDictionary *shares;


@end



@implementation TODSMSession

- (instancetype)init{
    self = [super init];
    if(self){
        self.smb_session = smb_session_new();
        if(self.smb_session == NULL){
            return nil;
        }
        self.shares = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc{
    if(self.smb_session!=NULL){
        [self.shares enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
            smb_tid shareID = [obj intValue];
            smb_tree_disconnect(self.smb_session, shareID);
        }];
        smb_session_destroy(self.smb_session);
        self.smb_session = NULL;
    }
    self.lastRequestDate = nil;
}

- (smb_tid)cachedShareIDForName:(NSString *)shareName{
    NSParameterAssert(shareName.length>0);
    if(shareName.length>0){
        smb_tid share_id = [[self.shares objectForKey:shareName] intValue];
        if(share_id==0){
            share_id = -1;
        }
        return share_id;
    }
    return -1;
}

- (void)cacheShareID:(smb_tid)shareID forName:(NSString *)shareName{
    NSParameterAssert(shareName.length>0);
    NSParameterAssert(shareID>0);
    if(shareName.length>0 && shareID>0){
        @synchronized (self) {
            smb_tid cachedShareID = [self cachedShareIDForName:shareName];
            if(shareID!=cachedShareID){
                if(cachedShareID>0){
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
            [self.shares removeObjectForKey:shareName];
        }
    }
}

- (BOOL)isValid{
    BOOL b = (self.smb_session !=NULL  && smb_session_state(self.smb_session) >= TOSMBSessionStateDialectOK && (NSDate.date.timeIntervalSince1970-self.lastRequestDate.timeIntervalSince1970)<kSessionTimeout && self.ipAddress.length>0 && self.userName.length>0);
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
