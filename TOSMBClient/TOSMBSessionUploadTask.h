//
//  TOSMBSessionUploadTask.h
//  Everapp
//
//  Created by Artem Meleshko on 2/14/16.
//  Copyright © 2016 Everappz. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TOSMBSessionTransferTask.h"

@interface TOSMBSessionUploadTask : TOSMBSessionTransferTask

- (instancetype)initWithSession:(TOSMBSession *)session
                       filePath:(NSString *)filePath
                destinationPath:(NSString *)destinationPath
                progressHandler:(TOSMBSessionTransferTaskProgressHandler)progressHandler
                 successHandler:(TOSMBSessionTransferTaskSuccessHandler)successHandler
                    failHandler:(TOSMBSessionTransferTaskFailHandler)failHandler;

@end

