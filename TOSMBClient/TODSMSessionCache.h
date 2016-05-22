//
//  TODSMSessionCache.h
//  MyApp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import <Foundation/Foundation.h>

@class TODSMSession;

@interface TODSMSessionCache : NSObject

+ (instancetype)sharedCache;

- (TODSMSession *)sessionForKey:(NSString *)sessionKey;

- (void)cacheSession:(TODSMSession *)session;

- (void)removeSessionFromCache:(TODSMSession *)session;

@end
