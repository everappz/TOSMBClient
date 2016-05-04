//
//  TOSMBSessionUploadTask.h
//  MyApp
//
//  Created by Artem Meleshko on 2/14/16.
//  Copyright © 2016 My Company. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TOSMBConstants.h"


@class TOSMBSession;

@interface TOSMBSessionUploadTask : NSObject

@property (readonly,weak) TOSMBSession *sessionObject;

@property (readonly,copy) NSString *sourceFilePath;

@property (readonly,copy) NSString *destinationFilePath;

@property (readonly) TOSMBSessionTransferTaskState state;

- (void)start;

- (void)cancel;

@end

