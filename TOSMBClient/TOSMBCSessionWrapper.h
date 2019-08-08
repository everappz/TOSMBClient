//
//  TOSMBCSessionWrapper.h
//  Everapp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface TOSMBCSessionWrapper : NSObject

@property (nonatomic,strong) NSDate *lastRequestDate;

@property (nonatomic,copy) NSString *userName;

@property (nonatomic,copy) NSString *password;

@property (nonatomic,copy) NSString *domain;

@property (nonatomic,copy) NSString *ipAddress;

- (NSString *)sessionKey;

- (BOOL)isValid;

+ (NSString *)sessionKeyForIPAddress:(NSString *)ipAddress
                              domain:(NSString *)domain
                            userName:(NSString *)userName
                            password:(NSString *)password;

- (void)close;

@end
