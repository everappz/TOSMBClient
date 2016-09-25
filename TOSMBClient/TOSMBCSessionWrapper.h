//
//  TOSMBCSessionWrapper.h
//  MyApp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "smb_session.h"


@interface TOSMBCSessionWrapper : NSObject

@property (nonatomic,readonly,assign) smb_session *smb_session;

@property (nonatomic,strong) NSDate *lastRequestDate;

@property (nonatomic,copy) NSString *userName;

@property (nonatomic,copy) NSString *password;

@property (nonatomic,copy) NSString *domain;

@property (nonatomic,copy) NSString *ipAddress;

- (smb_tid)cachedShareIDForName:(NSString *)shareName;

- (void)cacheShareID:(smb_tid)shareID forName:(NSString *)shareName;

- (void)removeCachedShareIDForName:(NSString *)shareName;

- (NSString *)sessionKey;

- (BOOL)isValid;

+ (NSString *)sessionKeyForIPAddress:(NSString *)ipAddress
                              domain:(NSString *)domain
                            userName:(NSString *)userName
                            password:(NSString *)password;



@end
