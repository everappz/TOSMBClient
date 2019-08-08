//
//  TOSMBCSessionWrapper+Private.h
//  TOSMBClient
//
//  Created by Artem on 8/9/19.
//  Copyright © 2019 TOSMB. All rights reserved.
//


#import "TOSMBCSessionWrapper.h"
#import "smb_session.h"

@interface TOSMBCSessionWrapper()

- (smb_tid)cachedShareIDForName:(NSString *)shareName;

- (void)cacheShareID:(smb_tid)shareID forName:(NSString *)shareName;

- (void)removeCachedShareIDForName:(NSString *)shareName;

- (void)inSMBCSession:(void (^)(smb_session *session))block;

@end
