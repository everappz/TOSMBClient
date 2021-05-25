//
//  NSString+TOSMB.h
//  TOSMBClient
//
//  Created by Artem on 2/13/19.
//  Copyright © 2019 TOSMB. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSString (TOSMB)

//Replace any backslashes \ with forward slashes /
- (NSString *)TOSMB_stringByReplacingOccurrencesOfBackSlashWithForwardSlash;

- (nullable NSString *)TOSMB_shareNameFromPath;

- (NSString *)TOSMB_filePathExcludingShareNameFromPath;

- (NSString *)TOSMB_relativeSMBPathFromPath;

+ (NSString *)TOSMB_uuidString;

@end

NS_ASSUME_NONNULL_END
