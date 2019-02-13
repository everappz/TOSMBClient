//
//  TOSMBSessionFile+Private.h
//  TOSMBClient
//
//  Created by Artem on 2/13/19.
//  Copyright © 2019 TOSMB. All rights reserved.
//

#import "TOSMBSessionFile.h"
#import "smb_stat.h"

@interface TOSMBSessionFile()

@property (nonatomic, copy) NSString *fullPath;
@property (nonatomic, assign) BOOL isShareRoot; /** If this item represents the root network share */
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint64_t fileSize;
@property (nonatomic, assign) uint64_t allocationSize;
@property (nonatomic, assign) BOOL directory;
@property (nonatomic, assign) uint64_t modificationTimestamp;
@property (nonatomic, strong) NSDate *modificationTime;
@property (nonatomic, assign) uint64_t creationTimestamp;
@property (nonatomic, strong) NSDate *creationTime;
@property (nonatomic, assign) uint64_t accessTimestamp;
@property (nonatomic, strong) NSDate *accessTime;
@property (nonatomic, assign) uint64_t writeTimestamp;
@property (nonatomic, strong) NSDate *writeTime;
@property (nonatomic, assign) BOOL readOnly;

- (NSDate *)dateFromLDAPTimeStamp:(uint64_t)timestamp;

/**
 * Init a new instance representing a file or folder inside a network share
 *
 * @param stat The opaque pointer for this stat value
 * @param session The session in which this item belongs to
 * @param path The absolute file path to this file's parent directory. Used to generate this file's own file path.
 */
- (instancetype)initWithStat:(smb_stat)stat parentDirectoryFilePath:(NSString *)path;

/**
 * Init a new instance representing the share itself, which in the case of libSMD, is simply another directory
 *
 * @param name The name of the share
 * @param session The session in which this item belongs to
 */
- (instancetype)initWithShareName:(NSString *)name;

- (instancetype)initWithStat:(smb_stat)stat fullPath:(NSString *)fullPath;

+ (instancetype)rootDirectory;

@end
