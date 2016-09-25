//
//  TOSMBCSessionWrapperCache.h
//  MyApp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import <Foundation/Foundation.h>

@class TOSMBCSessionWrapper;

@interface TOSMBCSessionWrapperCache : NSObject

+ (instancetype)sharedCache;

- (TOSMBCSessionWrapper *)sessionForKey:(NSString *)sessionKey;

- (void)cacheSession:(TOSMBCSessionWrapper *)session;

- (void)removeSessionFromCache:(TOSMBCSessionWrapper *)session;

@end
