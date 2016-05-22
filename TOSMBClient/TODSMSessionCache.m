//
//  TODSMSessionCache.m
//  MyApp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import "TODSMSessionCache.h"
#import "TODSMSession.h"
#import "TOSMBConstants.h"
#import "TOSMBSession.h"

@interface TODSMSessionCache()

@property (nonatomic,strong)NSMutableDictionary *privateCache;

@end


@implementation TODSMSessionCache

+ (instancetype)sharedCache{
    static dispatch_once_t onceToken;
    static TODSMSessionCache *cache = nil;
    dispatch_once(&onceToken, ^{
        cache = [[TODSMSessionCache alloc] init];
    });
    return cache;
}

- (instancetype)init{
    self = [super init];
    if(self){
        self.privateCache = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (TODSMSession *)sessionForKey:(NSString *)sessionKey{
    NSParameterAssert(sessionKey!=nil);
    if(sessionKey==nil){
        return nil;
    }
    TODSMSession *session = [self.privateCache objectForKey:sessionKey];
    if(session!=nil && session.isValid==NO){
        [self removeSessionFromCache:session];
        session = nil;
    }
    return session;
}

- (void)cacheSession:(TODSMSession *)session{
    NSParameterAssert(session!=nil);
    if(session==nil){
        return;
    }
    @synchronized (self) {
        TODSMSession *existingSession = [self sessionForKey:session.sessionKey];
        if(session.isValid && session.lastRequestDate.timeIntervalSince1970>existingSession.lastRequestDate.timeIntervalSince1970){
            [self.privateCache setObject:session forKey:session.sessionKey];
        }
    }
}

- (void)removeSessionFromCache:(TODSMSession *)session{
    NSParameterAssert(session!=nil);
    if(session==nil){
        return;
    }
    @synchronized (self) {
        [self.privateCache removeObjectForKey:session.sessionKey];
    }
}

@end
