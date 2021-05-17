//
// TOSMBSession.m
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

#import <arpa/inet.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import "TOSMBSession+Private.h"
#import "TOSMBSession.h"
#import "TOSMBSessionFile+Private.h"
#import "TONetBIOSNameService.h"
#import "TOSMBSessionDownloadTask.h"
#import "TOHost.h"
#import "TOSMBSessionUploadTask.h"
#import "NSString+TOSMB.h"

const NSTimeInterval kTOSMBSessionTimeout = 30.0;

@interface TOSMBSession()

@property (atomic, readwrite) BOOL connected;

@end


@implementation TOSMBSession

#pragma mark - Class Creation -

- (instancetype)init{
    //This class cannot be instantiated on its own.
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (instancetype)initWithHostName:(NSString *)hostName
                       ipAddress:(NSString *)ipAddress
                            port:(NSString *)port
                        userName:(NSString *)userName
                        password:(NSString *)password
                          domain:(NSString *)domain
       useInternalNameResolution:(BOOL)useInternalNameResolution
{
    self = [super init];
    if (self) {
        self.callbackQueue = [[NSOperationQueue alloc] init];
        self.callbackQueue.maxConcurrentOperationCount = 1;
        self.requestsQueue = [[NSOperationQueue alloc] init];
        self.requestsQueue.maxConcurrentOperationCount = 10;
        self.dsm_session = [[TOSMBCSessionWrapper alloc] init];
        self.useInternalNameResolution = useInternalNameResolution;
        self.ipAddress = ipAddress;
        self.hostName = hostName;
        self.port = port;
        self.userName = userName;
        self.password = password;
        self.domain = domain;
    }
    return self;
}

- (void)dealloc{
    [self close];
}

- (void)close{
    [self.requestsQueue cancelAllOperations];
    [self.callbackQueue cancelAllOperations];
    @synchronized (self) {
        [self.dsm_session close];
        self.dsm_session = nil;
    }
}

#pragma mark - Authorization -

- (void)setLoginCredentialsWithUserName:(NSString *)userName
                               password:(NSString *)password
                                 domain:(NSString *)domain{
    self.userName = userName;
    self.password = password;
    self.domain = domain;
}

#pragma mark - Connections/Authentication -

- (void)setLastRequestDate:(NSDate *)lastRequestDate{
    @synchronized (self) {
        [self.dsm_session setLastRequestDate:lastRequestDate];
    }
}

- (NSDate *)lastRequestDate{
    NSDate *date = nil;
    @synchronized (self) {
        date = self.dsm_session.lastRequestDate;
    }
    return date;
}

- (void)reloadSession{
    @synchronized (self) {
        [self.dsm_session close];
        self.dsm_session = [[TOSMBCSessionWrapper alloc] init];
    }
}

- (NSError *)attemptConnectionToAddress:(NSString *)ipaddr
                                   port:(NSString *)port
                              transport:(int)transport
{
    self.ipAddress = ipaddr;
    
    if(self.hostName.length==0){
        self.hostName = [TOHost hostnameForAddress:self.ipAddress];
    }
    
    //If only one piece of information was supplied, use NetBIOS to resolve the other
    if (self.useInternalNameResolution && (self.ipAddress.length == 0 || self.hostName.length == 0)) {
        TONetBIOSNameService *nameService = [TONetBIOSNameService sharedService];
        if (self.ipAddress.length==0){
            self.ipAddress = [nameService resolveIPAddressWithName:self.hostName
                                                              type:TONetBIOSNameServiceTypeFileServer];
        }
        if(self.hostName.length==0){
            self.hostName = [nameService lookupNetworkNameForIPAddress:self.ipAddress];
        }
    }
    
    //If there is STILL no IP address after the resolution, there's no chance of a successful connection
    if (self.ipAddress == nil) {
        return errorForErrorCode(TOSMBSessionErrorCodeUnableToResolveAddress);
    }
    
    if(self.hostName.length==0){
        self.hostName = self.ipAddress;
    }
    
    //Convert the IP Address and hostname values to their C equivalents
    const char *ip = [self.ipAddress cStringUsingEncoding:NSUTF8StringEncoding];
    const char *hostName = [self.hostName cStringUsingEncoding:NSASCIIStringEncoding];
    const char *user_port = NULL;
    if(port.length>0){
        user_port = [port cStringUsingEncoding:NSUTF8StringEncoding];
    }
    
    //If the username or password wasn't supplied, a non-NULL string must still be supplied
    //to avoid NULL input assertions.
    const char *userName = (self.userName.length>0 ? [self.userName cStringUsingEncoding:NSUTF8StringEncoding] : "GUEST");
    const char *password = (self.password.length>0 ? [self.password cStringUsingEncoding:NSUTF8StringEncoding] : "");
    const char *domain = (self.domain.length>0 ? [self.domain cStringUsingEncoding:NSUTF8StringEncoding] : [@"?" cStringUsingEncoding:NSUTF8StringEncoding]);
    
    NSString *dsm_session_domain = [NSString stringWithUTF8String:domain];
    NSString *dsm_session_userName = [NSString stringWithUTF8String:userName];
    NSString *dsm_session_password = [NSString stringWithUTF8String:password];
    NSString *dsm_session_ip_address = self.ipAddress;
    
    @synchronized (self) {
        self.dsm_session.ipAddress = dsm_session_ip_address;
        self.dsm_session.domain = dsm_session_domain;
        self.dsm_session.userName = dsm_session_userName;
        self.dsm_session.password = dsm_session_password;
    }
    
    //Attempt a connection
    __block TOSMBSessionErrorCode errorCode = TOSMBSessionErrorCodeNone;
    __block int guest = -1;
    
    [self inSMBCSession:^(smb_session *session) {
        int result = smb_session_connect(session, hostName, ip, user_port, transport);
        if (result != DSM_SUCCESS) {
            errorCode = TOSMBSessionErrorCodeUnableToConnect;
            return;
        }
        
        //Attempt a login. Even if we're downgraded to guest, the login call will succeed
        smb_session_set_creds(session, domain, userName, password);
        if (smb_session_login(session) != DSM_SUCCESS) {
            errorCode = TOSMBSessionErrorCodeAuthenticationFailed;
            return;
        }
        
        guest = smb_session_is_guest(session);
    }];
    
    if(errorCode != TOSMBSessionErrorCodeNone){
        return errorForErrorCode(errorCode);
    }
    
    self.connected = guest != -1;
    
    return nil;
}

- (NSError *)attemptConnection{
    
    __block BOOL sessionValid = YES;
    [self inSMBCSession:^(smb_session *session) {
        if (session == NULL) {
            sessionValid = NO;
        }
    }];
    
    if ( ( self.lastRequestDate && [[NSDate date] timeIntervalSinceDate:self.lastRequestDate] > kTOSMBSessionTimeout ) ||
        self.needsReloadSession ||
        sessionValid == NO ) {
        [self reloadSession];
        self.needsReloadSession = NO;
        self.connected = NO;
    }
    self.lastRequestDate = [NSDate date];
    
    //Don't attempt another connection if we already made it through
    TOSMBMakeWeakReference();
    [self inSMBCSession:^(smb_session *session) {
        TOSMBMakeStrongFromWeakReference();
        if (session){
            int guest = smb_session_is_guest(session);
            strongSelf.connected = (guest != -1);
        }
    }];
    
    if(self.connected){
        return nil;
    }
    
    //Ensure at least one piece of connection information was supplied
    if (self.ipAddress.length == 0 && self.hostName.length == 0) {
        return errorForErrorCode(TOSMBSessionErrorCodeUnableToResolveAddress);
    }
    
    if(self.ipAddress.length==0){
        NSMutableArray *addressesForHost = [[NSMutableArray alloc] init];
        NSArray *addresses = [TOHost addressesForHostname:self.hostName];
        for(NSString *addr in addresses){
            if([TOHost isValidIPAddress:addr] &&
               [addr isEqualToString:@"127.0.53.53"]==NO){
                [addressesForHost addObject:addr];
            }
        }
        
        __block NSError *connectError = nil;
        NSArray *resultArr = [addressesForHost sortedArrayUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
            return [@([obj1 length]) compare:@([obj2 length])];
        }];
        
        if(resultArr.count>0){
            [resultArr enumerateObjectsUsingBlock:^(NSString *obj, NSUInteger idx, BOOL * _Nonnull stop) {
                connectError = [self attemptConnectionToAddress:obj
                                                           port:self.port
                                                      transport:SMB_TRANSPORT_TCP];
                if(self.connected){
                    *stop = YES;
                }
            }];
        }
        else{
            connectError = [self attemptConnectionToAddress:nil
                                                       port:self.port
                                                  transport:SMB_TRANSPORT_TCP];
        }
        
        if (self.connected == NO) {
            [resultArr enumerateObjectsUsingBlock:^(NSString *obj, NSUInteger idx, BOOL * _Nonnull stop) {
                connectError = [self attemptConnectionToAddress:obj
                                                           port:self.port
                                                      transport:SMB_TRANSPORT_NBT];
                if(self.connected){
                    *stop = YES;
                }
            }];
        }
        
        return self.connected ? nil : connectError;
    }
    else{
        NSError *connectError = [self attemptConnectionToAddress:self.ipAddress
                                                            port:self.port
                                                       transport:SMB_TRANSPORT_TCP];
        if(self.connected==NO){
            connectError = [self attemptConnectionToAddress:self.ipAddress
                                                       port:self.port
                                                  transport:SMB_TRANSPORT_NBT];
        }
        return self.connected ? nil : connectError;
    }
    
    return nil;
}

#pragma mark - Directory Content -

- (smb_tid)connectToShareWithName:(NSString *)shareName error:(NSError **)error{
    //Connect to that share
    //If not, make a new connection
    const char *cStringName = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    __block smb_tid shareID = [self cachedShareIDForName:shareName];
    if (shareID == 0) {
        [self inSMBCSession:^(smb_session *session) {
            smb_tree_connect(session, cStringName, &shareID);
        }];
    }
    if (shareID == 0 ) {
        [self removeCachedShareIDForName:shareName];
        if (error) {
            NSError *resultError = errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed);
            *error = resultError;
        }
        return 0;
    }
    else{
        [self cacheShareID:shareID forName:shareName];
    }
    return shareID;
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error{
    
    //Attempt a connection attempt (If it has not already been done)
    NSError *resultError = [self attemptConnection];
    if (error && resultError){
        *error = resultError;
    }
    
    if (self.connected==NO){
        return nil;
    }
    
    //-----------------------------------------------------------------------------
    
    //If the path is nil, or '/', we'll be specifically requesting the
    //parent network share names as opposed to the actual file lists
    if (path.length == 0 || [path isEqualToString:@"/"]) {
        NSMutableArray *shareList = [NSMutableArray array];
        [self inSMBCSession:^(smb_session *session) {
            int smb_result = DSM_ERROR_GENERIC;
            smb_share_list list=NULL;
            size_t shareCount = 0;
            smb_result = smb_share_get_list(session, &list, &shareCount);
            if (smb_result==DSM_SUCCESS){
                for (NSInteger i = 0; i < shareCount; i++) {
                    const char *shareName = smb_share_list_at(list, i);
                    //Skip system shares suffixed by '$'
                    if (shareName[strlen(shareName)-1] == '$'){
                        continue;
                    }
                    NSString *shareNameString = [NSString stringWithCString:shareName encoding:NSUTF8StringEncoding];
                    TOSMBSessionFile *share = [[TOSMBSessionFile alloc] initWithShareName:shareNameString];
                    [shareList addObject:share];
                }
                if(list!=NULL){
                    smb_share_list_destroy(list);
                }
            }
        }];
        return (shareList.count==0)?nil:shareList;
    }
    
    //-----------------------------------------------------------------------------
    
    //Replace any backslashes with forward slashes
    path = [path TOSMB_stringByReplacingOccurrencesOfBackSlashWithForwardSlash];
    
    //Work out just the share name from the path (The first directory in the string)
    NSString *shareName = [TOSMBSession shareNameFromPath:path];
    
    //Connect to that share
    //If not, make a new connection
    smb_tid shareID = [self connectToShareWithName:shareName error:error];
    if(shareID==0){
        return nil;
    }
    
    //work out the remainder of the file path and create the search query
    NSString *relativePath = [TOSMBSession relativeSMBPathFromPath:path];
    //append double backslash if we don't have one
    if (![[relativePath substringFromIndex:relativePath.length-1] isEqualToString:@"\\"]){
        relativePath = [relativePath stringByAppendingString:@"\\"];
    }
    
    //Add the wildcard symbol for everything in this folder
    relativePath = [relativePath stringByAppendingString:@"*"]; //wildcard to search for all files
    
    NSMutableArray *fileList = [NSMutableArray array];
    
    //Query for a list of files in this directory
    [self inSMBCSession:^(smb_session *session) {
        smb_stat_list statList = NULL;
        statList = smb_find(session, shareID, relativePath.UTF8String);
        if(statList!=NULL){
            size_t listCount = smb_stat_list_count(statList);
            if (listCount != 0){
                for (NSInteger i = 0; i < listCount; i++) {
                    smb_stat item = smb_stat_list_at(statList, i);
                    const char* name = smb_stat_name(item);
                    if (name[0] == '.') { //skip hidden files
                        continue;
                    }
                    TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:item parentDirectoryFilePath:path];
                    if(file){
                        [fileList addObject:file];
                    }
                }
            }
            smb_stat_list_destroy(statList);
        }
    }];
    
    if (fileList.count == 0){
        return nil;
    }
    
    NSArray *result = [fileList sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
    return result;
    
}

- (NSOperation *)contentsOfDirectoryAtPath:(NSString *)path success:(void (^)(NSArray *))successHandler error:(void (^)(NSError *))errorHandler{
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    TOSMBMakeWeakReference();
    TOSMBMakeWeakReferenceForOperation();
    
    id operationBlock = ^{
        
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        
        NSError *error = nil;
        NSArray *files = [strongSelf contentsOfDirectoryAtPath:path error:&error];
        
        if (error) {
            strongSelf.needsReloadSession = YES;
            if (errorHandler) {
                [strongSelf performCallBackWithBlock:^{ if(errorHandler){errorHandler(error);} }];
            }
        }
        else {
            if (successHandler) {
                [strongSelf performCallBackWithBlock:^{ if(successHandler){successHandler(files);} }];
            }
        }
        
    };
    [operation addExecutionBlock:operationBlock];
    [self.requestsQueue addOperation:operation];
    return operation;
    
}

#pragma mark - Download Tasks -

- (TOSMBSessionDownloadTask *)downloadTaskForFileAtPath:(NSString *)path destinationPath:(NSString *)destinationPath delegate:(id<TOSMBSessionDownloadTaskDelegate>)delegate{
    TOSMBSessionDownloadTask *task = [[TOSMBSessionDownloadTask alloc] initWithSession:self filePath:path destinationPath:destinationPath delegate:delegate];
    return task;
}

- (TOSMBSessionDownloadTask *)downloadTaskForFileAtPath:(NSString *)path
                                        destinationPath:(NSString *)destinationPath
                                        progressHandler:(void (^)(uint64_t totalBytesWritten, uint64_t totalBytesExpected))progressHandler
                                      completionHandler:(void (^)(NSString *filePath))completionHandler
                                            failHandler:(void (^)(NSError *error))failHandler{
    TOSMBSessionDownloadTask *task = [[TOSMBSessionDownloadTask alloc] initWithSession:self filePath:path destinationPath:destinationPath progressHandler:progressHandler successHandler:completionHandler failHandler:failHandler];
    return task;
}

#pragma mark - Open Connection -

- (NSOperation *)openConnection:(void (^)(void))successHandler error:(void (^)(NSError *))errorHandler{
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    TOSMBMakeWeakReference();
    TOSMBMakeWeakReferenceForOperation();
    
    id operationBlock = ^{
        
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        
        NSError *error = [strongSelf attemptConnection];
        
        if (error) {
            strongSelf.needsReloadSession = YES;
            if (errorHandler) {
                [strongSelf performCallBackWithBlock:^{ if(errorHandler){errorHandler(error);} }];
            }
        }
        else {
            if (successHandler) {
                [strongSelf performCallBackWithBlock:^{ if(successHandler){successHandler();} }];
            }
        }
    };
    [operation addExecutionBlock:operationBlock];
    [self.requestsQueue addOperation:operation];
    return operation;
    
}

#pragma mark - Item Info -

- (TOSMBSessionFile *)itemAttributesAtPath:(NSString *)path error:(NSError **)error{
    
    TOSMBSessionFile *file = nil;
    
    //Attempt a connection attempt (If it has not already been done)
    NSError *resultError = [self attemptConnection];
    if (error && resultError){
        *error = resultError;
    }
    
    if (self.connected==NO){
        return nil;
    }
    
    if (path.length == 0 || [path isEqualToString:@"/"]) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeFileNotFound);
            *error = resultError;
        }
        return nil;
    }
    
    //Replace any backslashes with forward slashes
    path = [path TOSMB_stringByReplacingOccurrencesOfBackSlashWithForwardSlash];
    
    //Work out just the share name from the path (The first directory in the string)
    NSString *shareName = [TOSMBSession shareNameFromPath:path];
    
    //Connect to that share
    //If not, make a new connection
    smb_tid shareID = [self connectToShareWithName:shareName error:error];
    if(shareID==0){
        return nil;
    }
    
    //work out the remainder of the file path and create the search query
    NSString *relativePath = [TOSMBSession relativeSMBPathFromPath:path];
    
    __block smb_stat stat = NULL;
    [self inSMBCSession:^(smb_session *session) {
        stat = smb_fstat(session, shareID, relativePath.UTF8String);
    }];
    
    if(stat==NULL){
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeFileNotFound);
            *error = resultError;
        }
    }
    else{
        if([[path stringByDeletingLastPathComponent] isEqualToString:@"/"]){
            file = [[TOSMBSessionFile alloc] initWithShareName:shareName];
        }
        else{
            file = [[TOSMBSessionFile alloc] initWithStat:stat fullPath:path];
        }
        [self inSMBCSession:^(smb_session *session) {
            smb_stat_destroy(stat);
        }];
    }
    
    return file;
    
}

- (NSOperation *)itemAttributesAtPath:(NSString *)path success:(void (^)(TOSMBSessionFile *))successHandler error:(void (^)(NSError *))errorHandler{
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    TOSMBMakeWeakReference();
    TOSMBMakeWeakReferenceForOperation();
    
    id operationBlock = ^{
        
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        
        NSError *error = nil;
        TOSMBSessionFile *file = [strongSelf itemAttributesAtPath:path error:&error];
        
        if (error) {
            strongSelf.needsReloadSession = YES;
            if (errorHandler) {
                [strongSelf performCallBackWithBlock:^{ if(errorHandler){errorHandler(error);} }];
            }
        }
        else {
            if (successHandler) {
                [strongSelf performCallBackWithBlock:^{ if(successHandler){successHandler(file);} }];
            }
        }
        
    };
    [operation addExecutionBlock:operationBlock];
    [self.requestsQueue addOperation:operation];
    return operation;
}

#pragma mark - Move Item -

- (BOOL)moveItemAtPath:(NSString *)fromPath toPath:(NSString *)toPath error:(NSError **)error{
    
    NSError *resultError = [self attemptConnection];
    if (error && resultError){
        *error = resultError;
    }
    
    if (self.connected==NO){
        return NO;
    }
    
    if (fromPath.length == 0 || [fromPath isEqualToString:@"/"] || toPath.length == 0 || [toPath isEqualToString:@"/"]) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeUnknown);
            *error = resultError;
        }
        return NO;
    }
    
    //Replace any backslashes with forward slashes
    fromPath = [fromPath TOSMB_stringByReplacingOccurrencesOfBackSlashWithForwardSlash];
    toPath = [toPath TOSMB_stringByReplacingOccurrencesOfBackSlashWithForwardSlash];
    
    //Work out just the share name from the path (The first directory in the string)
    NSString *shareName = [TOSMBSession shareNameFromPath:fromPath];
    
    //Connect to that share
    //If not, make a new connection
    smb_tid shareID = [self connectToShareWithName:shareName error:error];
    if(shareID==0){
        return NO;
    }
    
    NSString *relativeFromPath = [TOSMBSession relativeSMBPathFromPath:fromPath];
    NSString *relativeToPath = [TOSMBSession relativeSMBPathFromPath:toPath];
    
    const char *relativeFromPathCString = [relativeFromPath cStringUsingEncoding:NSUTF8StringEncoding];
    const char *relativeToPathCString = [relativeToPath cStringUsingEncoding:NSUTF8StringEncoding];
    
    __block int result = DSM_ERROR_GENERIC;
    [self inSMBCSession:^(smb_session *session) {
        result = smb_file_mv(session, shareID, relativeFromPathCString, relativeToPathCString);
    }];
    
    if (result != DSM_SUCCESS) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeUnableToMoveFile);
            *error = resultError;
        }
    }
    
    return (result==DSM_SUCCESS);
    
}

- (NSOperation *)moveItemAtPath:(NSString *)fromPath
                         toPath:(NSString *)toPath
                        success:(void (^)(TOSMBSessionFile *newFile))successHandler
                          error:(void (^)(NSError *))errorHandler{
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    TOSMBMakeWeakReference();
    TOSMBMakeWeakReferenceForOperation();
    
    id operationBlock = ^{
        
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        
        NSError *error = nil;
        BOOL success = [strongSelf moveItemAtPath:fromPath toPath:toPath error:&error];
        
        if (success==NO || error) {
            strongSelf.needsReloadSession = YES;
            if (errorHandler) {
                [strongSelf performCallBackWithBlock:^{ if(errorHandler){errorHandler(error);} }];
            }
        }
        else {
            TOSMBSessionFile *file = [weakSelf itemAttributesAtPath:toPath error:&error];
            if (successHandler) {
                [strongSelf performCallBackWithBlock:^{ if(successHandler){successHandler(file);} }];
            }
        }
        
    };
    [operation addExecutionBlock:operationBlock];
    [self.requestsQueue addOperation:operation];
    return operation;
    
}

#pragma mark - Create Directory -

- (BOOL)createDirectoryAtPath:(NSString *)path error:(NSError **)error{
    
    NSError *resultError = [self attemptConnection];
    if (error && resultError){
        *error = resultError;
    }
    
    if (self.connected==NO){
        return NO;
    }
    
    if (path.length == 0 || [path isEqualToString:@"/"]) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeUnknown);
            *error = resultError;
        }
        return NO;
    }
    
    //Replace any backslashes with forward slashes
    path = [path TOSMB_stringByReplacingOccurrencesOfBackSlashWithForwardSlash];
    
    //Work out just the share name from the path (The first directory in the string)
    NSString *shareName = [TOSMBSession shareNameFromPath:path];
    
    //Connect to that share
    //If not, make a new connection
    smb_tid shareID = [self connectToShareWithName:shareName error:error];
    if(shareID==0){
        return NO;
    }
    
    NSString *relativePath = [TOSMBSession relativeSMBPathFromPath:path];
    const char *relativePathCString = [relativePath cStringUsingEncoding:NSUTF8StringEncoding];
    
    __block int result = DSM_ERROR_GENERIC;
    [self inSMBCSession:^(smb_session *session) {
        result = smb_directory_create(session,shareID,relativePathCString);
    }];
    
    if(result!=DSM_SUCCESS){
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeUnableToCreateDirectory);
            *error = resultError;
        }
    }
    
    return (result==DSM_SUCCESS);
    
}

- (NSOperation *)createDirectoryAtPath:(NSString *)path
                               success:(void (^)(TOSMBSessionFile *createdDirectory))successHandler
                                 error:(void (^)(NSError *))errorHandler{
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    TOSMBMakeWeakReference();
    TOSMBMakeWeakReferenceForOperation();
    
    id operationBlock = ^{
        
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        
        NSError *error = nil;
        BOOL success = [strongSelf createDirectoryAtPath:path error:&error];
        
        if (success==NO || error) {
            strongSelf.needsReloadSession = YES;
            if (errorHandler) {
                [strongSelf performCallBackWithBlock:^{ if(errorHandler){errorHandler(error);} }];
            }
        }
        else {
            TOSMBSessionFile *file = [strongSelf itemAttributesAtPath:path error:&error];
            if (successHandler) {
                [strongSelf performCallBackWithBlock:^{ if(successHandler){successHandler(file);} }];
            }
        }
    };
    
    [operation addExecutionBlock:operationBlock];
    [self.requestsQueue addOperation:operation];
    
    return operation;
}


#pragma mark - Delete Item -


- (BOOL)recursiveContentOfDirectoryAtPath:(NSString *)dirPath
                                  inShare:(smb_tid)shareID
                                    items:(NSMutableArray **)items
                                    error:(NSError **)error{
    
    if (dirPath.length == 0 || [dirPath isEqualToString:@"/"]) {
        if (error) {
            NSError *resultError = errorForErrorCode(TOSMBSessionErrorCodeUnknown);
            *error = resultError;
        }
        return NO;
    }
    
    NSString *path = dirPath;
    path = [path TOSMB_stringByReplacingOccurrencesOfBackSlashWithForwardSlash];
    
    NSParameterAssert([self cachedShareIDForName:[TOSMBSession shareNameFromPath:path]]==shareID);
    
    NSString *relativePath = [TOSMBSession relativeSMBPathFromPath:path];
    //append double backslash if we don't have one
    if (![[relativePath substringFromIndex:relativePath.length-1] isEqualToString:@"\\"]){
        relativePath = [relativePath stringByAppendingString:@"\\"];
    }
    relativePath = [relativePath stringByAppendingString:@"*"];
    const char *relativePathCString = [relativePath cStringUsingEncoding:NSUTF8StringEncoding];
    
    __block smb_stat_list statList = NULL;
    [self inSMBCSession:^(smb_session *session) {
        statList = smb_find(session, shareID, relativePathCString);
    }];
    
    if(statList==NULL){
        if (error) {
            NSError *resultError = errorForErrorCode(TOSMBSessionErrorCodeUnknown);
            *error = resultError;
        }
        return NO;
    }
    
    NSMutableArray *directories = [[NSMutableArray alloc] init];
    NSMutableArray *fileItems = [NSMutableArray new];
    
    [self inSMBCSession:^(smb_session *session) {
        size_t listCount = 0;
        listCount = smb_stat_list_count(statList);
        if (listCount > 0){
            for (NSInteger i = 0; i < listCount; i++) {
                smb_stat item = smb_stat_list_at(statList, i);
                const char* name = smb_stat_name(item);
                NSString *itemName = [[NSString alloc] initWithBytes:name length:strlen(name) encoding:NSUTF8StringEncoding];
                if([itemName isEqualToString:@"."] || [itemName isEqualToString:@".."]){
                    continue;
                }
                TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:item parentDirectoryFilePath:path];
                if(file){
                    if(file.directory){
                        [directories addObject:file];
                    }
                    else{
                        [fileItems addObject:file];
                    }
                }
            }
        }
        smb_stat_list_destroy(statList);
    }];
    
    if(items){
        [*items addObjectsFromArray:fileItems];
    }
    
    for(TOSMBSessionFile *dir in directories){
        BOOL result = [self recursiveContentOfDirectoryAtPath:dir.fullPath
                                                      inShare:shareID
                                                        items:items
                                                        error:error];
        if(result==NO){
            return NO;
        }
    }
    
    return YES;
}

- (BOOL)deleteDirectoryAtPath:(NSString *)dirPath
                      inShare:(smb_tid)shareID
                        error:(NSError **)error
{
    
    if (dirPath.length == 0 || [dirPath isEqualToString:@"/"]) {
        if (error) {
            NSError *resultError = errorForErrorCode(TOSMBSessionErrorCodeUnknown);
            *error = resultError;
        }
        return NO;
    }
    
    NSString *path = dirPath;
    path = [path TOSMB_stringByReplacingOccurrencesOfBackSlashWithForwardSlash];
    
    NSParameterAssert([self cachedShareIDForName:[TOSMBSession shareNameFromPath:path]]==shareID);
    
    NSString *relativePath = [TOSMBSession relativeSMBPathFromPath:path];
    const char *relativePathCString = [relativePath cStringUsingEncoding:NSUTF8StringEncoding];
    
    __block int result = DSM_ERROR_GENERIC;
    [self inSMBCSession:^(smb_session *session) {
        result = smb_directory_rm(session, shareID, relativePathCString);
    }];
    
    if(result!=DSM_SUCCESS){
        if (error) {
            *error = errorForErrorCode(TOSMBSessionErrorCodeUnableToDeleteItem);
        }
    }
    
    return (result==DSM_SUCCESS);
}

- (BOOL)deleteFileAtPath:(NSString *)filePath inShare:(smb_tid)shareID error:(NSError **)error{
    
    if (filePath.length == 0 || [filePath isEqualToString:@"/"]) {
        if (error) {
            NSError *resultError = errorForErrorCode(TOSMBSessionErrorCodeUnknown);
            *error = resultError;
        }
        return NO;
    }
    
    NSString *path = filePath;
    path = [path TOSMB_stringByReplacingOccurrencesOfBackSlashWithForwardSlash];
    
    NSParameterAssert([self cachedShareIDForName:[TOSMBSession shareNameFromPath:path]]==shareID);
    
    NSString *relativePath = [TOSMBSession relativeSMBPathFromPath:path];
    const char *relativePathCString = [relativePath cStringUsingEncoding:NSUTF8StringEncoding];
    
    __block int result = DSM_ERROR_GENERIC;
    [self inSMBCSession:^(smb_session *session) {
        result = smb_file_rm(session, shareID, relativePathCString);
    }];
    
    if(result!=DSM_SUCCESS){
        if (error) {
            *error = errorForErrorCode(TOSMBSessionErrorCodeUnableToDeleteItem);
        }
    }
    
    return (result==DSM_SUCCESS);
    
}

- (BOOL)deleteItemAtPath:(NSString *)path error:(NSError **)error{
    
    NSError *resultError = [self attemptConnection];
    int result = -1;
    if (error && resultError){
        *error = resultError;
    }
    
    if (self.connected==NO){
        return NO;
    }
    
    if (path.length == 0 || [path isEqualToString:@"/"]) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeUnknown);
            *error = resultError;
        }
        return NO;
    }
    
    //Replace any backslashes with forward slashes
    path = [path TOSMB_stringByReplacingOccurrencesOfBackSlashWithForwardSlash];
    
    //Work out just the share name from the path (The first directory in the string)
    NSString *shareName = [TOSMBSession shareNameFromPath:path];
    
    //Connect to that share
    //If not, make a new connection
    smb_tid shareID = [self connectToShareWithName:shareName error:error];
    if(shareID==0){
        return NO;
    }
    
    NSString *relativePath = [TOSMBSession relativeSMBPathFromPath:path];
    const char *relativePathCString = [relativePath cStringUsingEncoding:NSUTF8StringEncoding];
    
    __block smb_stat stat = NULL;
    [self inSMBCSession:^(smb_session *session) {
        stat = smb_fstat(session, shareID, relativePathCString);
    }];
    
    if (stat == NULL) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeFileNotFound);
            *error = resultError;
        }
    }
    else{
        __block BOOL directory = NO;
        [self inSMBCSession:^(smb_session *session) {
            directory = (smb_stat_get(stat, SMB_STAT_ISDIR) != 0);
            smb_stat_destroy(stat);
        }];
        
        if(directory){
            
            NSMutableArray *childItems = [[NSMutableArray alloc] init];
            BOOL fetchResultSuccess = [self recursiveContentOfDirectoryAtPath:path inShare:shareID items:&childItems error:nil];
            
            if(fetchResultSuccess){
                if(childItems.count>0){
                    for(NSInteger index = childItems.count-1;index>=0;index--){
                        TOSMBSessionFile *file = [childItems objectAtIndex:index];
                        BOOL success = NO;
                        if(file.directory){
                            success = [self deleteDirectoryAtPath:file.fullPath inShare:shareID error:nil];
                        }
                        else{
                            success = [self deleteFileAtPath:file.fullPath inShare:shareID error:nil];
                        }
                        if(success==NO){
                            break;
                        }
                    }
                }
                result = ([self deleteDirectoryAtPath:path inShare:shareID error:error]?0:-1);
            }
            else{
                result = -1;
            }
            
        }
        else{
            result = ([self deleteFileAtPath:path inShare:shareID error:error]?0:-1);
        }
        
        if(result!=0){
            
            //double check
            __block smb_stat stat = NULL;
            [self inSMBCSession:^(smb_session *session) {
                stat = smb_fstat(session, shareID, relativePathCString);
            }];
            
            if(stat==NULL){
                if(error){
                    *error = nil;
                }
                result = 0;
            }
            else{
                [self inSMBCSession:^(smb_session *session) {
                    smb_stat_destroy(stat);
                }];
                if (error) {
                    resultError = errorForErrorCode(TOSMBSessionErrorCodeUnableToDeleteItem);
                    *error = resultError;
                }
            }
        }
    }
    
    return (result==0);
}

- (NSOperation *)deleteItemAtPath:(NSString *)path
                          success:(void (^)(void))successHandler
                            error:(void (^)(NSError *))errorHandler{
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    TOSMBMakeWeakReference();
    TOSMBMakeWeakReferenceForOperation();
    
    id operationBlock = ^{
        TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn();
        TOSMBCheckIfWeakReferenceIsNilAndReturn();
        TOSMBMakeStrongFromWeakReference();
        
        NSError *error = nil;
        BOOL success = [strongSelf deleteItemAtPath:path error:&error];
        
        if (success==NO) {
            strongSelf.needsReloadSession = YES;
            if (errorHandler) {
                [strongSelf performCallBackWithBlock:^{ if(errorHandler){errorHandler(error);} }];
            }
        }
        else {
            if (successHandler) {
                [strongSelf performCallBackWithBlock:^{ if(successHandler){successHandler();} }];
            }
        }
    };
    
    [operation addExecutionBlock:operationBlock];
    [self.requestsQueue addOperation:operation];
    
    return operation;
}

#pragma mark - Upload Task -

- (TOSMBSessionUploadTask *)uploadTaskForFileAtPath:(NSString *)path
                                    destinationPath:(NSString *)destinationPath
                                    progressHandler:(void (^)(uint64_t totalBytesWritten, uint64_t totalBytesExpected))progressHandler
                                  completionHandler:(void (^)(NSString *filePath))completionHandler
                                        failHandler:(void (^)(NSError *error))errorHandler{
    TOSMBSessionUploadTask *task = [[TOSMBSessionUploadTask alloc] initWithSession:self
                                                                          filePath:path
                                                                   destinationPath:destinationPath
                                                                   progressHandler:progressHandler
                                                                    successHandler:completionHandler
                                                                       failHandler:errorHandler];
    return task;
}

#pragma mark - Concurrency Management -

- (void)performCallBackWithBlock:(void(^)(void))block{
    NSParameterAssert(self.callbackQueue);
    NSParameterAssert(block);
    if(block){
        NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:block];
        [self.callbackQueue addOperation:op];
    }
}

- (void)addRequestOperation:(NSOperation *)op{
    NSParameterAssert(op);
    if (op) {
        [self.requestsQueue addOperation:op];
    }
}

- (void)cancelAllRequests{
    [self.requestsQueue cancelAllOperations];
}

#pragma mark - SMB Session -

- (void)inSMBCSession:(void (^)(smb_session *session))block {
    TOSMBCSessionWrapper *dsm_session = nil;
    @synchronized (self) {
        dsm_session = self.dsm_session;
    }
    [self inSMBCSession:block];
}

- (smb_tid)cachedShareIDForName:(NSString *)shareName{
    NSParameterAssert(shareName.length>0);
    __block smb_tid share_id = 0;
    @synchronized (self) {
        share_id = [self.dsm_session cachedShareIDForName:shareName];
    }
    return share_id;
}

- (void)cacheShareID:(smb_tid)shareID forName:(NSString *)shareName{
    @synchronized (self) {
        [self.dsm_session cacheShareID:shareID forName:shareName];
    }
}

- (void)removeCachedShareIDForName:(NSString *)shareName{
    @synchronized (self) {
        [self removeCachedShareIDForName:shareName];
    }
}

#pragma mark - String Parsing -

+ (NSString *)shareNameFromPath:(NSString *)path{
    return [path TOSMB_shareNameFromPath];
}

+ (NSString *)filePathExcludingShareNameFromPath:(NSString *)path{
    return [path TOSMB_filePathExcludingShareNameFromPath];
}

+ (NSString *)relativeSMBPathFromPath:(NSString *)path{
    return [path TOSMB_relativeSMBPathFromPath];
}

@end
