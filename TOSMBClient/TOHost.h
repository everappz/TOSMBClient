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


#pragma mark Class IP and Host Utilities

+ (NSString *) stringFromAddress: (const struct sockaddr *) address;

+ (BOOL)addressFromString:(NSString *)IPAddress address:(struct sockaddr_in *)address;

+ (NSString *) addressFromData:(NSData *) addressData;

+ (NSString *) portFromData:(NSData *) addressData;

+ (NSData *) dataFromAddress: (struct sockaddr_in) address;

- (NSString *) hostname;

- (NSString *) getIPAddressForHost: (NSString *) theHost;

- (NSString *) localIPAddress;
- (NSString *) localWiFiIPAddress;
+ (NSArray *) localWiFiIPAddresses;

- (NSString *) whatismyipdotcom;

@end
