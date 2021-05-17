//
//  TOHost.m
//  Everapp
//
//  Created by Artem Meleshko on 2/13/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#import "TOHost.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <CFNetwork/CFNetwork.h>
#import <netinet/in.h>
#import <net/ethernet.h>
#import <net/if_dl.h>
#import <net/if.h>
#import <netdb.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <dlfcn.h>


@implementation TOHost

+ (NSString *)addressForHostname:(NSString *)hostname {
    NSArray *addresses = [TOHost addressesForHostname:hostname];
    if ([addresses count] > 0)
        return [addresses objectAtIndex:0];
    else
        return nil;
}


+ (NSArray *)unixAddressesForHostname:(NSString *)hostname {
    if (hostname.length == 0) {
        return nil;
    }
    struct hostent *remoteHostEnt = gethostbyname([hostname UTF8String]);
    if (remoteHostEnt == NULL) {
        return nil;
    }
    NSMutableArray *addArray = [NSMutableArray array];
    for(int i = 0; i<remoteHostEnt->h_length;i++){
        struct in_addr *remoteInAddr = (struct in_addr *) remoteHostEnt->h_addr_list[0];
        char *sRemoteInAddr = inet_ntoa(*remoteInAddr);
        struct in_addr addr;
        struct in6_addr addr6;
        NSString *resultIPAddress = nil;
        if (inet_pton(AF_INET, sRemoteInAddr, &addr) == 1) {
            resultIPAddress = [NSString stringWithUTF8String:sRemoteInAddr];
        }
        else if(inet_pton(AF_INET6, sRemoteInAddr, &addr6) == 1) {
            resultIPAddress = [NSString stringWithUTF8String:sRemoteInAddr];
        }
        if(resultIPAddress){
            [addArray addObject:resultIPAddress];
        }
    }
    return addArray;
}

+ (NSArray *)addressesForHostname:(NSString *)hostname {
    
    // Get the addresses for the given hostname.
    CFHostRef hostRef = CFHostCreateWithName(kCFAllocatorDefault, (__bridge CFStringRef)hostname);
    BOOL isSuccess = CFHostStartInfoResolution(hostRef, kCFHostAddresses, nil);
    if (!isSuccess){
        CFRelease(hostRef);
        return nil;
    }
    CFArrayRef addressesRef = CFHostGetAddressing(hostRef, nil);
    if (addressesRef == nil){
        CFRelease(hostRef);
        return nil;
    }
    
    // Convert these addresses into strings.
    char ipAddress[INET6_ADDRSTRLEN];
    NSMutableArray *addresses = [[NSMutableArray alloc] init];
    CFIndex numAddresses = CFArrayGetCount(addressesRef);
    for (CFIndex currentIndex = 0; currentIndex < numAddresses; currentIndex++) {
        struct sockaddr *address = (struct sockaddr *)CFDataGetBytePtr(CFArrayGetValueAtIndex(addressesRef, currentIndex));
        if (address == nil){
            CFRelease(hostRef);
            return nil;
        };
        getnameinfo(address, address->sa_len, ipAddress, INET6_ADDRSTRLEN, nil, 0, NI_NUMERICHOST);
        NSString *str = [NSString stringWithCString:ipAddress encoding:NSASCIIStringEncoding];
        if(str){
            [addresses addObject:str];
        }
    }
    CFRelease(hostRef);
    return addresses;
}

+ (NSString *)hostnameForAddress:(NSString *)address {
    NSArray *hostnames = [TOHost hostnamesForAddress:address];
    if ([hostnames count] > 0){
        return [hostnames objectAtIndex:0];
    }
    else{
        return nil;
    }
}

+ (NSArray *)hostnamesForAddress:(NSString *)address {
    // Get the host reference for the given address.
    struct addrinfo      hints;
    struct addrinfo      *result = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_flags    = AI_NUMERICHOST;
    hints.ai_family   = PF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = 0;
    int errorStatus = getaddrinfo([address cStringUsingEncoding:NSASCIIStringEncoding], NULL, &hints, &result);
    if (errorStatus != 0) {
        return nil;
    }
    CFDataRef addressRef = CFDataCreate(NULL, (UInt8 *)result->ai_addr, result->ai_addrlen);
    if (addressRef == nil){
        return nil;
    }
    freeaddrinfo(result);
    CFHostRef hostRef = CFHostCreateWithAddress(kCFAllocatorDefault, addressRef);
    if (hostRef == nil) {
        CFRelease(addressRef);
        return nil;
    }
    CFRelease(addressRef);
    BOOL isSuccess = CFHostStartInfoResolution(hostRef, kCFHostNames, NULL);
    if (!isSuccess){
        CFRelease(hostRef);
        return nil;
    };
    
    // Get the hostnames for the host reference.
    CFArrayRef hostnamesRef = CFHostGetNames(hostRef, NULL);
    NSMutableArray *hostnames = [NSMutableArray array];
    for (int currentIndex = 0; currentIndex < [(__bridge NSArray *)hostnamesRef count]; currentIndex++) {
        [hostnames addObject:[(__bridge NSArray *)hostnamesRef objectAtIndex:currentIndex]];
    }
    CFRelease(hostRef);
    return hostnames;
}


// These methods adapted from code posted by Evan Schoenberg to Stack Overflow
// and licensed under the Attribution-ShareAlike 3.0 Unported license
// http://stackoverflow.com/questions/1679152/how-to-validate-an-ip-address-with-regular-expression-in-objective-c

+ (BOOL)isValidIPv4Address:(NSString *)addressString{
    if(addressString.length>0){
        struct in_addr throwaway;
        int success = inet_pton(AF_INET, [addressString UTF8String], &throwaway);
        return (success == 1);
    }
    return NO;
}

+ (BOOL)isValidIPv6Address:(NSString *)addressString{
    if(addressString.length>0){
        struct in6_addr throwaway;
        int success = inet_pton(AF_INET6, [addressString UTF8String], &throwaway);
        return (success == 1);
    }
    return NO;
}

+ (BOOL)isValidIPAddress:(NSString *)addressString{
    return ([self isValidIPv4Address:addressString] || [self isValidIPv6Address:addressString]);
}

@end
