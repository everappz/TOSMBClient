//
//  TOHost.m
//  MyApp
//
//  Created by Artem Meleshko on 2/13/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import "TOHost.h"
#import <CFNetwork/CFNetwork.h>
#import <netinet/in.h>
#import <netdb.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/ethernet.h>
#import <net/if_dl.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <unistd.h>
#import <dlfcn.h>
#import <arpa/inet.h>

@implementation TOHost

+ (NSString *)addressForHostname:(NSString *)hostname {
    NSArray *addresses = [TOHost addressesForHostname:hostname];
    if ([addresses count] > 0)
        return [addresses objectAtIndex:0];
    else
        return nil;
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

+ (NSArray *)ipAddresses {
    NSMutableArray *addresses = [NSMutableArray array];
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *currentAddress = NULL;
    
    int success = getifaddrs(&interfaces);
    if (success == 0) {
        currentAddress = interfaces;
        while(currentAddress != NULL) {
            if(currentAddress->ifa_addr->sa_family == AF_INET) {
                NSString *address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)currentAddress->ifa_addr)->sin_addr)];
                if (![address isEqual:@"127.0.0.1"]) {
                    NSLog(@"%@ ip: %@", [NSString stringWithUTF8String:currentAddress->ifa_name], address);
                    [addresses addObject:address];
                }
            }
            currentAddress = currentAddress->ifa_next;
        }
    }
    freeifaddrs(interfaces);
    return addresses;
}

+ (NSArray *)ethernetAddresses {
    NSMutableArray *addresses = [NSMutableArray array];
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *currentAddress = NULL;
    int success = getifaddrs(&interfaces);
    if (success == 0) {
        currentAddress = interfaces;
        while(currentAddress != NULL) {
            if(currentAddress->ifa_addr->sa_family == AF_LINK) {
                NSString *address = [NSString stringWithUTF8String:ether_ntoa((const struct ether_addr *)LLADDR((struct sockaddr_dl *)currentAddress->ifa_addr))];
                
                // ether_ntoa doesn't format the ethernet address with padding.
                char paddedAddress[80];
                int a,b,c,d,e,f;
                sscanf([address UTF8String], "%x:%x:%x:%x:%x:%x", &a, &b, &c, &d, &e, &f);
                sprintf(paddedAddress, "%02X:%02X:%02X:%02X:%02X:%02X",a,b,c,d,e,f);
                address = [NSString stringWithUTF8String:paddedAddress];
                
                if (![address isEqual:@"00:00:00:00:00:00"] && ![address isEqual:@"00:00:00:00:00:FF"]) {
                    NSLog(@"%@ mac: %@", [NSString stringWithUTF8String:currentAddress->ifa_name], address);
                    [addresses addObject:address];
                }
            }
            currentAddress = currentAddress->ifa_next;
        }
    }
    freeifaddrs(interfaces);
    return addresses;
}


// These methods adapted from code posted by Evan Schoenberg to Stack Overflow
// and licensed under the Attribution-ShareAlike 3.0 Unported license
// http://stackoverflow.com/questions/1679152/how-to-validate-an-ip-address-with-regular-expression-in-objective-c

+ (BOOL)isValidIPv4Address:(NSString *)addressString{
    struct in_addr throwaway;
    int success = inet_pton(AF_INET, [addressString UTF8String], &throwaway);
    return (success == 1);
}

+ (BOOL)isValidIPv6Address:(NSString *)addressString{
    struct in6_addr throwaway;
    int success = inet_pton(AF_INET6, [addressString UTF8String], &throwaway);
    return (success == 1);
}

+ (BOOL)isValidIPAddress:(NSString *)addressString{
    return ([self isValidIPv4Address:addressString] || [self isValidIPv6Address:addressString]);
}


#pragma mark Class IP and Host Utilities
// This IP Utilities are mostly inspired by or derived from Apple code. Thank you Apple.

+ (NSString *) stringFromAddress: (const struct sockaddr *) address
{
    if (address && address->sa_family == AF_INET)
    {
        const struct sockaddr_in* sin = (struct sockaddr_in *) address;
        return [NSString stringWithFormat:@"%@:%d", [NSString stringWithUTF8String:inet_ntoa(sin->sin_addr)], ntohs(sin->sin_port)];
    }
    
    return nil;
}

+ (BOOL)addressFromString:(NSString *)IPAddress address:(struct sockaddr_in *)address
{
    if (!IPAddress || ![IPAddress length]) return NO;
    
    memset((char *) address, sizeof(struct sockaddr_in), 0);
    address->sin_family = AF_INET;
    address->sin_len = sizeof(struct sockaddr_in);
    
    int conversionResult = inet_aton([IPAddress UTF8String], &address->sin_addr);
    if (conversionResult == 0)
    {
        NSAssert1(conversionResult != 1, @"Failed to convert the IP address string into a sockaddr_in: %@", IPAddress);
        return NO;
    }
    
    return YES;
}

+ (NSString *) addressFromData:(NSData *) addressData
{
    NSString *adr = nil;
    
    if (addressData != nil)
    {
        struct sockaddr_in addrIn = *(struct sockaddr_in *)[addressData bytes];
        adr = [NSString stringWithFormat: @"%s", inet_ntoa(addrIn.sin_addr)];
    }
    
    return adr;
}

+ (NSString *) portFromData:(NSData *) addressData
{
    NSString *port = nil;
    
    if (addressData != nil)
    {
        struct sockaddr_in addrIn = *(struct sockaddr_in *)[addressData bytes];
        port = [NSString stringWithFormat: @"%hu", ntohs(addrIn.sin_port)];
    }
    
    return port;
}

+ (NSData *) dataFromAddress: (struct sockaddr_in) address
{
    return [NSData dataWithBytes:&address length:sizeof(struct sockaddr_in)];
}

- (NSString *) hostname
{
    char baseHostName[256]; // Thanks, Gunnar Larisch
    int success = gethostname(baseHostName, 255);
    if (success != 0) return nil;
    baseHostName[255] = '\0';
    
#if TARGET_IPHONE_SIMULATOR
    return [NSString stringWithFormat:@"%s", baseHostName];
#else
    return [NSString stringWithFormat:@"%s.local", baseHostName];
#endif
}

- (NSString *) getIPAddressForHost: (NSString *) theHost
{
    struct hostent *host = gethostbyname([theHost UTF8String]);
    if (!host) {herror("resolv"); return NULL; }
    struct in_addr **list = (struct in_addr **)host->h_addr_list;
    NSString *addressString = [NSString stringWithCString:inet_ntoa(*list[0]) encoding:NSUTF8StringEncoding];
    return addressString;
}

- (NSString *) localIPAddress
{
    struct hostent *host = gethostbyname([[self hostname] UTF8String]);
    if (!host) {herror("resolv"); return nil;}
    struct in_addr **list = (struct in_addr **)host->h_addr_list;
    return [NSString stringWithCString:inet_ntoa(*list[0]) encoding:NSUTF8StringEncoding];
}

// Matt Brown's get WiFi IP addy solution
// Author gave permission to use in Cookbook under cookbook license
// http://mattbsoftware.blogspot.com/2009/04/how-to-get-ip-address-of-iphone-os-v221.html
// Updates: changed en0 to en.
// More updates: TBD
- (NSString *) localWiFiIPAddress
{
    BOOL success;
    struct ifaddrs * addrs;
    const struct ifaddrs * cursor;
    
    success = getifaddrs(&addrs) == 0;
    if (success) {
        cursor = addrs;
        while (cursor != NULL) {
            // the second test keeps from picking up the loopback address
            if (cursor->ifa_addr->sa_family == AF_INET && (cursor->ifa_flags & IFF_LOOPBACK) == 0)
            {
                NSString *name = [NSString stringWithUTF8String:cursor->ifa_name];
                if ([name isEqualToString:@"en"])  // Wi-Fi adapter -- was en0
                    return [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)cursor->ifa_addr)->sin_addr)];
            }
            cursor = cursor->ifa_next;
        }
        freeifaddrs(addrs);
    }
    return nil;
}

+ (NSArray *) localWiFiIPAddresses
{
    BOOL success;
    struct ifaddrs * addrs;
    const struct ifaddrs * cursor;
    
    NSMutableArray *array = [NSMutableArray array];
    
    success = getifaddrs(&addrs) == 0;
    if (success) {
        cursor = addrs;
        while (cursor != NULL) {
            // the second test keeps from picking up the loopback address
            if (cursor->ifa_addr->sa_family == AF_INET && (cursor->ifa_flags & IFF_LOOPBACK) == 0)
            {
                NSString *name = [NSString stringWithUTF8String:cursor->ifa_name];
                if ([name hasPrefix:@"en"])
                    [array addObject:[NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)cursor->ifa_addr)->sin_addr)]];
            }
            cursor = cursor->ifa_next;
        }
        freeifaddrs(addrs);
    }
    
    if (array.count) return array;
    
    return nil;
}


- (NSString *) whatismyipdotcom
{
    NSError *error;
    NSURL *ipURL = [NSURL URLWithString:@"http://www.whatismyip.com/automation/n09230945.asp"];
    NSString *ip = [NSString stringWithContentsOfURL:ipURL encoding:1 error:&error];
    return ip ? ip : [error localizedDescription];
}


@end
