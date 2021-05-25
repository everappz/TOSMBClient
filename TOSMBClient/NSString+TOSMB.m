//
//  NSString+TOSMB.m
//  TOSMBClient
//
//  Created by Artem on 2/13/19.
//  Copyright © 2019 TOSMB. All rights reserved.
//

#import "NSString+TOSMB.h"

@implementation NSString (TOSMB)

//Replace any backslashes with forward slashes
- (NSString *)TOSMB_stringByReplacingOccurrencesOfBackSlashWithForwardSlash{
    return [self stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
}

- (NSString *)TOSMB_shareNameFromPath{
    NSString *shareName = [self copy];
    //Remove any potential slashes at the start
    if ([shareName hasPrefix:@"//"] || [shareName hasPrefix:@"\\\\"]) {
        shareName = [shareName substringFromIndex:2];
    }
    else if ([shareName hasPrefix:@"/"] || [shareName hasPrefix:@"\\"]) {
        shareName = [shareName substringFromIndex:1];
    }
    NSRange range = [shareName rangeOfString:@"/"];
    if (range.location != NSNotFound){
        shareName = [shareName substringWithRange:NSMakeRange(0, range.location)];
    }
    return shareName;
}

- (NSString *)TOSMB_filePathExcludingShareNameFromPath{
    NSString *resultPath = [self copy];
    //Remove any potential slashes at the start
    if ([resultPath hasPrefix:@"//"] || [resultPath hasPrefix:@"\\\\"]) {
        resultPath = [resultPath substringFromIndex:2];
    }
    else if ([resultPath hasPrefix:@"/"] || [resultPath hasPrefix:@"\\"]) {
        resultPath = [resultPath substringFromIndex:1];
    }
    NSRange range = [resultPath rangeOfString:@"/"];
    if (range.location == NSNotFound) {
        range = [resultPath rangeOfString:@"\\"];
    }
    if (range.location != NSNotFound){
        resultPath = [resultPath substringFromIndex:range.location+1];
    }
    if ([resultPath length] > 1 && [resultPath hasSuffix:@"/"]) {
        return [resultPath substringToIndex:[resultPath length] - 1];
    }
    return resultPath;
}

- (NSString *)TOSMB_relativeSMBPathFromPath{
    NSString *path = [self copy];
    //work out the remainder of the file path and create the search query
    NSString *relativePath = [path TOSMB_filePathExcludingShareNameFromPath];
    //prepend double backslashes
    relativePath = [NSString stringWithFormat:@"\\%@",relativePath];
    //replace any additional forward slashes with backslashes
    relativePath = [relativePath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]; //replace forward slashes with backslashes
    NSParameterAssert(relativePath);
    return relativePath;
}

+ (NSString *)TOSMB_uuidString {
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    NSString *uuidStr = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return uuidStr;
}

@end
