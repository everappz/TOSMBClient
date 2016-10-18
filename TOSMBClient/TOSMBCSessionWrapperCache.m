//
//  TOSMBCSessionWrapperCache.m
//  MyApp
//
//  Created by Artem Meleshko on 5/22/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import "TOSMBCSessionWrapperCache.h"
#import "TOSMBCSessionWrapper.h"
#import "TOSMBConstants.h"
#import "TOSMBSession.h"

@interface TOSMBCSessionWrapperCache()

@property (nonatomic,strong)NSMutableDictionary *privateCache;

@end


@implementation TOSMBCSessionWrapperCache

+ (instancetype)sharedCache{
    static dispatch_once_t onceToken;
    static TOSMBCSessionWrapperCache *cache = nil;
    dispatch_once(&onceToken, ^{
        cache = [[TOSMBCSessionWrapperCache alloc] init];
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

- (TOSMBCSessionWrapper *)sessionForKey:(NSString *)sessionKey{
    NSParameterAssert(sessionKey!=nil);
    if(sessionKey==nil){
        return nil;
    }
    TOSMBCSessionWrapper *session = [self.privateCache objectForKey:sessionKey];
    if(session!=nil && session.isValid==NO){
        [self removeSessionFromCache:session];
        session = nil;
    }
    return session;
}

- (void)cacheSession:(TOSMBCSessionWrapper *)session{
    NSParameterAssert(session!=nil && session.sessionKey!=nil);
    if(session==nil || session.sessionKey==nil){
        return;
    }
    @synchronized (self) {
        TOSMBCSessionWrapper *existingSession = [self sessionForKey:session.sessionKey];
        if(session.isValid && session.lastRequestDate.timeIntervalSince1970>existingSession.lastRequestDate.timeIntervalSince1970 && session!=existingSession){
            if(existingSession){
                [self removeSessionFromCache:existingSession];
            }
            [self.privateCache setObject:session forKey:session.sessionKey];
        }
    }
}

- (void)removeSessionFromCache:(TOSMBCSessionWrapper *)session{
    NSParameterAssert(session!=nil && session.sessionKey!=nil);
    if(session==nil || session.sessionKey==nil){
        return;
    }
    @synchronized (self) {
        [session close];
        [self.privateCache removeObjectForKey:session.sessionKey];
    }
}

@end
