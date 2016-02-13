//
//  TOHost.h
//  MyApp
//
//  Created by Artem Meleshko on 2/13/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface TOHost : NSObject

+ (NSString *)addressForHostname:(NSString *)hostname ;

+ (NSArray *)addressesForHostname:(NSString *)hostname ;

+ (NSString *)hostnameForAddress:(NSString *)address ;

+ (NSArray *)hostnamesForAddress:(NSString *)address ;

+ (NSArray *)ipAddresses ;

+ (NSArray *)ethernetAddresses ;

@end
