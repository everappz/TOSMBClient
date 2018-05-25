//
//  TOSMBCSessionWrapperCache.h
//  Everapp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#ifdef USE_SMB_SESSION_CACHE

#import <Foundation/Foundation.h>

@class TOSMBCSessionWrapper;

@interface TOSMBCSessionWrapperCache : NSObject

+ (instancetype)sharedCache;

- (TOSMBCSessionWrapper *)sessionForKey:(NSString *)sessionKey;

- (void)cacheSession:(TOSMBCSessionWrapper *)session;

- (void)removeSessionFromCache:(TOSMBCSessionWrapper *)session;

@end

#endif
