//
//  TOSMBCSessionWrapper.h
//  Everapp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#import <Foundation/Foundation.h>




@interface TOSMBCSessionWrapper : NSObject

@property (atomic,strong) NSDate *lastRequestDate;

@property (atomic,copy) NSString *userName;

@property (atomic,copy) NSString *password;

@property (atomic,copy) NSString *domain;

@property (atomic,copy) NSString *ipAddress;

- (NSString *)sessionKey;

- (BOOL)isValid;

+ (NSString *)sessionKeyForIPAddress:(NSString *)ipAddress
                              domain:(NSString *)domain
                            userName:(NSString *)userName
                            password:(NSString *)password;

- (void)close;

@end
