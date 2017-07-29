//
//  TOHost.h
//  Everapp
//
//  Created by Artem Meleshko on 2/13/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface TOHost : NSObject

+ (NSString *)addressForHostname:(NSString *)hostname;

+ (NSArray *)addressesForHostname:(NSString *)hostname;

+ (NSString *)hostnameForAddress:(NSString *)address;

+ (NSArray *)hostnamesForAddress:(NSString *)address;

+ (BOOL)isValidIPv4Address:(NSString *)addressString;

+ (BOOL)isValidIPv6Address:(NSString *)addressString;

+ (BOOL)isValidIPAddress:(NSString *)addressString;


@end
