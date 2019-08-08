//
//  TONetBIOSNameServiceEntry+Private.h
//  TOSMBClient
//
//  Created by Artem on 2/13/19.
//  Copyright © 2019 TOSMB. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TOSMBConstants.h"
#import "netbios_ns.h"
#import "TONetBIOSNameServiceEntry.h"

@interface TONetBIOSNameServiceEntry()

@property (nonatomic, assign) netbios_ns_entry *entry;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *group;
@property (nonatomic, assign, readwrite) TONetBIOSNameServiceType type;
@property (nonatomic, assign, readwrite) uint32_t ipAddress;
@property (nonatomic, copy, readwrite) NSString *ipAddressString;

- (BOOL)isEqualToEntry:(TONetBIOSNameServiceEntry *)entry;

- (instancetype)initWithCEntry:(netbios_ns_entry *)entry;
+ (instancetype)entryWithCEntry:(netbios_ns_entry *)entry;

@end
