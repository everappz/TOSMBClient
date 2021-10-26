//
// TOSMBFile.m
// Copyright 2015 Timothy Oliver
//
// This file is dual-licensed under both the MIT License, and the LGPL v2.1 License.
//
// -------------------------------------------------------------------------------
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
// -------------------------------------------------------------------------------

#import "TOSMBSessionFile+Private.h"

@implementation TOSMBSessionFile

- (instancetype)init
{
    if (self = [super init]) {
        _fileSize = -1;
        _allocationSize = -1;
    }
    
    return self;
}

- (instancetype)initWithStat:(smb_stat)stat
     parentDirectoryFilePath:(NSString *)parentDirectoryFilePath
{
    if (stat == NULL){
        return nil;
    }
    if (self = [self init]) {
        const char *name = smb_stat_name(stat);
        if (name != NULL) {
            _name = [[[NSString alloc] initWithBytes:name length:strlen(name) encoding:NSUTF8StringEncoding] copy];
            _fullPath = [[parentDirectoryFilePath stringByAppendingPathComponent:_name] copy];
        }
        else{
            @try{NSParameterAssert(NO);}@catch(NSException *exc){}
        }
        _fileSize = smb_stat_get(stat, SMB_STAT_SIZE);
        _allocationSize = smb_stat_get(stat, SMB_STAT_ALLOC_SIZE);
        _directory = (smb_stat_get(stat, SMB_STAT_ISDIR) != 0);
        _modificationTimestamp = smb_stat_get(stat, SMB_STAT_MTIME);
        _creationTimestamp = smb_stat_get(stat, SMB_STAT_CTIME);
        _accessTimestamp = smb_stat_get(stat, SMB_STAT_ATIME);
        _writeTimestamp = smb_stat_get(stat, SMB_STAT_WTIME);
        _modificationTime = [self dateFromLDAPTimeStamp:_modificationTimestamp];
        _creationTime = [self dateFromLDAPTimeStamp:_creationTimestamp];
        [self normalizeFullPath];
    }
    
    return self;
}

- (instancetype)initWithBasicFileInfoStat:(smb_stat)basicFileInfoStat
                     standardFileInfoStat:(smb_stat)standardFileInfoStat
                                 fullPath:(NSString *)fullPath
{
    if (basicFileInfoStat == NULL){
        NSParameterAssert(NO);
        return nil;
    }
    if (standardFileInfoStat == NULL){
        NSParameterAssert(NO);
        return nil;
    }
    if (fullPath == nil){
        NSParameterAssert(NO);
        return nil;
    }
    
    if (self = [self init])
    {
        _name = [[fullPath lastPathComponent] copy];
        _fullPath = [fullPath copy];
        
        _directory = (smb_stat_get(basicFileInfoStat, SMB_STAT_ISDIR) != 0);
        _modificationTimestamp = smb_stat_get(basicFileInfoStat, SMB_STAT_MTIME);
        _creationTimestamp = smb_stat_get(basicFileInfoStat, SMB_STAT_CTIME);
        _accessTimestamp = smb_stat_get(basicFileInfoStat, SMB_STAT_ATIME);
        _writeTimestamp = smb_stat_get(basicFileInfoStat, SMB_STAT_WTIME);
        _modificationTime = [self dateFromLDAPTimeStamp:_modificationTimestamp];
        _creationTime = [self dateFromLDAPTimeStamp:_creationTimestamp];
        
        _fileSize = smb_stat_get(standardFileInfoStat, SMB_STAT_SIZE);
        _allocationSize = smb_stat_get(standardFileInfoStat, SMB_STAT_ALLOC_SIZE);
        
        [self normalizeFullPath];
    }
    return self;
}

- (instancetype)initWithShareName:(NSString *)name{
    if (name.length == 0){
        return nil;
    }
    if (self = [self init]) {
        _name = [name copy];
        _isShareRoot = YES;
        _fileSize = 0;
        _allocationSize = 0;
        _directory = YES;
        _fullPath = [[NSString stringWithFormat:@"/%@", name] copy];
        [self normalizeFullPath];
    }
    return self;
}

+ (instancetype)rootDirectory{
    TOSMBSessionFile *file = [TOSMBSessionFile new];
    if (self) {
        file->_name = @"root";
        file->_fileSize = 0;
        file->_allocationSize = 0;
        file->_directory = YES;
        file->_readOnly = YES;
        file->_fullPath = @"/";
        [file normalizeFullPath];
    }
    return file;
}

- (void)normalizeFullPath{
    NSString *normalizedPath = _fullPath;
    if (normalizedPath.length == 0) {
        normalizedPath = @"/";
    }
    if ([normalizedPath characterAtIndex:normalizedPath.length - 1] != '/' && _directory) {
        normalizedPath = [normalizedPath stringByAppendingString:@"/"];
    }
    NSParameterAssert(normalizedPath);
    _fullPath = [normalizedPath copy];
}

//SO Answer by Dave DeLong - http://stackoverflow.com/a/11978614/599344
- (NSDate *)dateFromLDAPTimeStamp:(uint64_t)timestamp{
    
    NSDateComponents *base = [[NSDateComponents alloc] init];
    [base setDay:1];
    [base setMonth:1];
    [base setYear:1601];
    [base setEra:1]; // AD
    
    NSCalendar *gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSDate *baseDate = [gregorian dateFromComponents:base];
    
    NSTimeInterval newTimestamp = timestamp / 10000000.0f;
    NSDate *finalDate = [baseDate dateByAddingTimeInterval:newTimestamp];
    
    return finalDate;
}

- (NSDate *)accessTime{
    if (_accessTime){
        return _accessTime;
    }
    _accessTime = [self dateFromLDAPTimeStamp:_accessTimestamp];
    return _accessTime;
}

- (NSDate *)writeTime{
    if (_writeTime){
        return _writeTime;
    }
    _writeTime = [self dateFromLDAPTimeStamp:_writeTimestamp];
    return _writeTime;
}

#pragma mark - Debug -

- (NSString *)description{
    if (self.isShareRoot){
        return [NSString stringWithFormat:@"Share - Name: %@", self.name];
    }
    return [NSString stringWithFormat:@"%@ - Name: %@ | Size: %ld", (self.directory ? @"Dir":@"File"), self.name, (long)self.fileSize];
}

@end
