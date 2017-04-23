//
//  TOSMBSessionUploadTask.h
//  Everapp
//
//  Created by Artem Meleshko on 2/14/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TOSMBConstants.h"


@class TOSMBSession;
@class TOSMBCSessionWrapper;

@interface TOSMBSessionUploadTask : NSObject

@property (readonly,weak) TOSMBSession *sessionObject;

@property (readonly, strong) TOSMBCSessionWrapper *dsm_session;

@property (readonly,copy) NSString *sourceFilePath;

@property (readonly,copy) NSString *destinationFilePath;

@property (readonly) TOSMBSessionTransferTaskState state;

- (void)start;

- (void)cancel;

@end

