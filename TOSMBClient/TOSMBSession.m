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

#import "TOSMBSession.h"
#import "TOSMBSessionFile.h"
#import "TONetBIOSNameService.h"
#import "TOSMBSessionDownloadTask.h"
#import "TOHost.h"
#import "TOSMBSessionUploadTask.h"

#import "smb_session.h"
#import "smb_share.h"
#import "smb_stat.h"
#import "smb_dir.h"

@interface TOSMBSessionDownloadTask ()

- (instancetype)initWithSession:(TOSMBSession *)session
                       filePath:(NSString *)filePath
                destinationPath:(NSString *)destinationPath
                       delegate:(id<TOSMBSessionDownloadTaskDelegate>)delegate;

- (instancetype)initWithSession:(TOSMBSession *)session
                       filePath:(NSString *)filePath
                destinationPath:(NSString *)destinationPath
                progressHandler:(id)progressHandler
                 successHandler:(id)successHandler
                    failHandler:(id)failHandler;

- (NSBlockOperation *)downloadOperation;

@end


@interface TOSMBSessionUploadTask ()


- (instancetype)initWithSession:(TOSMBSession *)session
                       filePath:(NSString *)filePath
                destinationPath:(NSString *)destinationPath
                progressHandler:(id)progressHandler
                 successHandler:(id)successHandler
                    failHandler:(id)failHandler;

- (NSBlockOperation *)uploadOperation;

@end


@interface TOSMBSession ()

/* The session pointer responsible for this object. */
@property (nonatomic, assign) smb_session *session;

/* 1 == Guest, 0 == Logged in, -1 == Logged out */
@property (nonatomic, assign, readwrite) NSInteger guest;

@property (nonatomic, strong) NSOperationQueue *dataQueue; /* Operation queue for asynchronous data requests. */
@property (nonatomic, strong) NSOperationQueue *transferQueue; /* Operation queue for file transfers. */

@property (nonatomic, strong) NSDate *lastRequestDate;

/* Connection/Authentication handling */
- (BOOL)deviceIsOnWiFi;
- (NSError *)attemptConnection; //Attempt connection for ourselves
- (NSError *)attemptConnectionWithSessionPointer:(smb_session *)session; //Attempt connection on behalf of concurrent download sessions

/* File path parsing */
- (NSString *)shareNameFromPath:(NSString *)path;
- (NSString *)filePathExcludingSharePathFromPath:(NSString *)path;

/* Asynchronous operation management */
- (void)setupDataQueue;
- (void)setupTransferQueue;

@property (nonatomic, strong)dispatch_queue_t callBackQueue;

@end

@implementation TOSMBSession

#pragma mark - Class Creation -

- (instancetype)init{
    if (self = [super init]) {
        self.callBackQueue = dispatch_queue_create([@"com.smb.session.callback.queue" cStringUsingEncoding:NSUTF8StringEncoding], NULL);
        self.session = smb_session_new();
        if (self.session == NULL){
            return nil;
        }
    }
    return self;
}

- (instancetype)initWithHostName:(NSString *)name{
    if (self = [self init]) {
        self.hostName = name;
    }
    return self;
}

- (instancetype)initWithIPAddress:(NSString *)address{
    if (self = [self init]) {
        self.ipAddress = address;
    }
    return self;
}

- (instancetype)initWithHostName:(NSString *)name ipAddress:(NSString *)ipAddress{
    if (self = [self init]) {
        self.hostName = name;
        self.ipAddress = ipAddress;
    }
    return self;
}

- (instancetype)initWithHostNameOrIPAddress:(NSString *)hostNameOrIPaddress{
    if (self = [self init]) {
        if([self isDotQuadIP:hostNameOrIPaddress]){
            self.ipAddress = hostNameOrIPaddress;
        }
        else{
            self.hostName = hostNameOrIPaddress;
        }
    }
    return self;
}

- (BOOL)isDotQuadIP:(NSString *)hostName{
    NSArray *a = [hostName componentsSeparatedByString:@"."];
    if([a count]==4){
        for(NSString *s in a){
            NSCharacterSet* nonNumbers = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
            NSRange r = [s rangeOfCharacterFromSet: nonNumbers];
            if(r.location != NSNotFound){
                return NO;
            }
        }
        return YES;
    }
    return NO;
}

- (void)dealloc{
    [self.dataQueue cancelAllOperations];
    [self.transferQueue cancelAllOperations];
    if(self.session!=NULL){
        smb_session_destroy(self.session);
        self.session = NULL;
    }
}

#pragma mark - Authorization -

- (void)setLoginCredentialsWithUserName:(NSString *)userName password:(NSString *)password domain:(NSString *)domain{
    self.userName = userName;
    self.password = password;
    self.domain = domain;
}

#pragma mark - Connections/Authentication -

- (BOOL)deviceIsOnWiFi{
    
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, "8.8.8.8");
    SCNetworkReachabilityFlags flags;
    BOOL success = SCNetworkReachabilityGetFlags(reachability, &flags);
    CFRelease(reachability);
    if (!success) {
        return NO;
    }
    BOOL isReachable = ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
    BOOL needsConnection = ((flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0);
    BOOL isNetworkReachable = (isReachable && !needsConnection);
    
    if (!isNetworkReachable) {
        return NO;
    } else if ((flags & kSCNetworkReachabilityFlagsIsWWAN) != 0) {
        return NO;
    }
    
    return YES;
}

- (NSError *)attemptConnection{
    NSError *error = [self attemptConnectionWithSessionPointer:self.session];
    if (error){
        return error;
    }
    self.guest = smb_session_is_guest(self.session);
    return nil;
}

- (NSError *)attemptConnectionWithSessionPointer:(smb_session *)session{
    
    if(session==NULL){
        return errorForErrorCode(TOSMBSessionErrorCodeUnableToConnect);
    }
    
    //There's no point in attempting a potentially costly TCP attempt if we're not even on a local network.
    if ([self deviceIsOnWiFi] == NO) {
        return errorForErrorCode(TOSMBSessionErrorNotOnWiFi);
    }
    
    if (self.session == session) {
        if (self.lastRequestDate && [[NSDate date] timeIntervalSinceDate:self.lastRequestDate] > 60.0) {
            smb_session_destroy(self.session);
            self.session = smb_session_new();
            session = self.session;
        }
        self.lastRequestDate = [NSDate date];
    }
    
    //Don't attempt another connection if we already made it through
    if (session && smb_session_state(session) >= TOSMBSessionStateDialectOK)
        return nil;
    
    //Ensure at least one piece of connection information was supplied
    if (self.ipAddress.length == 0 && self.hostName.length == 0) {
        return errorForErrorCode(TOSMBSessionErrorCodeUnableToResolveAddress);
    }
    
    //If only one piece of information was supplied, use NetBIOS to resolve the other
    if (self.ipAddress.length == 0 || self.hostName.length == 0) {
        
        if(self.ipAddress == nil){
            NSArray *addresses = [TOHost addressesForHostname:self.hostName];
            NSString *ipv4Address = nil;
            for(NSString *address in addresses){
                if([self isDotQuadIP:address]){
                    ipv4Address = address;
                    break;
                }
            }
            self.ipAddress = ipv4Address;
        }
        
        if(self.hostName==nil){
            self.hostName = [TOHost hostnameForAddress:self.ipAddress];
        }
        
        TONetBIOSNameService *nameService = [[TONetBIOSNameService alloc] init];
        if (self.ipAddress == nil){
            self.ipAddress = [nameService resolveIPAddressWithName:self.hostName type:TONetBIOSNameServiceTypeFileServer];
        }
        if(self.hostName==nil){
            self.hostName = [nameService lookupNetworkNameForIPAddress:self.ipAddress];
        }
        
    }
    
    //If there is STILL no IP address after the resolution, there's no chance of a successful connection
    if (self.ipAddress == nil) {
        return errorForErrorCode(TOSMBSessionErrorCodeUnableToResolveAddress);
    }
    
    if(self.hostName==nil){
        self.hostName = @"";
    }
    
    //Convert the IP Address and hostname values to their C equivalents
    struct in_addr addr;
    inet_aton([self.ipAddress cStringUsingEncoding:NSASCIIStringEncoding], &addr);
    const char *hostName = [self.hostName cStringUsingEncoding:NSUTF8StringEncoding];
    
    //Attempt a connection
    if (!smb_session_connect(session, hostName, addr.s_addr, SMB_TRANSPORT_TCP)) {
        return errorForErrorCode(TOSMBSessionErrorCodeUnableToConnect);
    }
    
    //If the username or password wasn't supplied, a non-NULL string must still be supplied
    //to avoid NULL input assertions.   
    const char *userName = (self.userName ? [self.userName cStringUsingEncoding:NSUTF8StringEncoding] : "guest");
    const char *password = (self.password ? [self.password cStringUsingEncoding:NSUTF8StringEncoding] : "");
    const char *domain = (self.domain ? [self.domain cStringUsingEncoding:NSUTF8StringEncoding] : [self.hostName cStringUsingEncoding:NSUTF8StringEncoding]);
    
    
    //Attempt a login. Even if we're downgraded to guest, the login call will succeed
    smb_session_set_creds(session, domain, userName, password);
    if (!smb_session_login(session)) {
        return errorForErrorCode(TOSMBSessionErrorCodeAuthenticationFailed);
    }
    
    return nil;
}

#pragma mark - Directory Content -

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error{
    
    //Attempt a connection attempt (If it has not already been done)
    NSError *resultError = [self attemptConnection];
    if (error && resultError){
        *error = resultError;
    }
    
    if (resultError){
        return nil;
    }
    
    //-----------------------------------------------------------------------------
    
    //If the path is nil, or '/', we'll be specifically requesting the
    //parent network share names as opposed to the actual file lists
    if (path.length == 0 || [path isEqualToString:@"/"]) {
        smb_share_list list;
        size_t shareCount = smb_share_get_list(self.session, &list);
        if (shareCount == 0)
            return nil;
        
        NSMutableArray *shareList = [NSMutableArray array];
        for (NSInteger i = 0; i < shareCount; i++) {
            const char *shareName = smb_share_list_at(list, i);
            
            //Skip system shares suffixed by '$'
            if (shareName[strlen(shareName)-1] == '$')
                continue;
            
            NSString *shareNameString = [NSString stringWithCString:shareName encoding:NSUTF8StringEncoding];
            TOSMBSessionFile *share = [[TOSMBSessionFile alloc] initWithShareName:shareNameString];
            [shareList addObject:share];
        }
        
        smb_share_list_destroy(list);
        
        return [NSArray arrayWithArray:shareList];
    }
    
    //-----------------------------------------------------------------------------
    
    //Replace any backslashes with forward slashes
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    
    //Work out just the share name from the path (The first directory in the string)
    NSString *shareName = [self shareNameFromPath:path];
    
    //Connect to that share
    //If not, make a new connection
    const char *cStringName = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    smb_tid shareID = smb_tree_connect(self.session, cStringName);
    if (shareID < 0) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed);
            *error = resultError;
        }
        return nil;
    }
    
    //work out the remainder of the file path and create the search query
    NSString *relativePath = [self filePathExcludingSharePathFromPath:path];
    //prepend double backslashes
    relativePath = [NSString stringWithFormat:@"\\%@",relativePath];
    //replace any additional forward slashes with backslashes
    relativePath = [relativePath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]; //replace forward slashes with backslashes
    //append double backslash if we don't have one
    if (![[relativePath substringFromIndex:relativePath.length-1] isEqualToString:@"\\"]){
        relativePath = [relativePath stringByAppendingString:@"\\"];
    }
    
    //Add the wildcard symbol for everything in this folder
    relativePath = [relativePath stringByAppendingString:@"*"]; //wildcard to search for all files
    
    NSMutableArray *fileList = [NSMutableArray array];
    
    //Query for a list of files in this directory
    smb_stat_list statList = smb_find(self.session, shareID, relativePath.UTF8String);
    
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
    
    smb_tree_disconnect(self.session, shareID);
    
    if (fileList.count == 0){
        return nil;
    }

    return [fileList sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
}

- (NSOperation *)contentsOfDirectoryAtPath:(NSString *)path success:(void (^)(NSArray *))successHandler error:(void (^)(NSError *))errorHandler{
    
    [self setupDataQueue];
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    __weak typeof(self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    
    id operationBlock = ^{
        if (weakOperation.isCancelled) { return; }
        
        NSError *error = nil;
        NSArray *files = [weakSelf contentsOfDirectoryAtPath:path error:&error];
        
        if (weakOperation.isCancelled) { return; }
        
        if (error) {
            if (errorHandler) {
                [weakSelf performCallBackWithBlock:^{ errorHandler(error); }];
            }
        }
        else {
            if (successHandler) {
                [weakSelf performCallBackWithBlock:^{ successHandler(files); }];
            }
        }
    };
    [operation addExecutionBlock:operationBlock];
    [self.dataQueue addOperation:operation];
    return operation;
}

#pragma mark - Download Tasks -

- (TOSMBSessionDownloadTask *)downloadTaskForFileAtPath:(NSString *)path destinationPath:(NSString *)destinationPath delegate:(id<TOSMBSessionDownloadTaskDelegate>)delegate{
    [self setupTransferQueue];
    TOSMBSessionDownloadTask *task = [[TOSMBSessionDownloadTask alloc] initWithSession:self filePath:path destinationPath:destinationPath delegate:delegate];
    return task;
}

- (TOSMBSessionDownloadTask *)downloadTaskForFileAtPath:(NSString *)path
                                        destinationPath:(NSString *)destinationPath
                                        progressHandler:(void (^)(uint64_t totalBytesWritten, uint64_t totalBytesExpected))progressHandler
                                      completionHandler:(void (^)(NSString *filePath))completionHandler
                                            failHandler:(void (^)(NSError *error))failHandler{
    [self setupTransferQueue];
    TOSMBSessionDownloadTask *task = [[TOSMBSessionDownloadTask alloc] initWithSession:self filePath:path destinationPath:destinationPath progressHandler:progressHandler successHandler:completionHandler failHandler:failHandler];
    return task;
}

#pragma mark - Open Connection -

- (NSOperation *)openConnection:(void (^)(void))successHandler error:(void (^)(NSError *))errorHandler{
    //setup operation queue as needed
    [self setupDataQueue];
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    __weak typeof(self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    
    id operationBlock = ^{
        if (weakOperation.isCancelled) { return; }
        
        NSError *error = [weakSelf attemptConnection];
        
        if (weakOperation.isCancelled) { return; }
        
        if (error) {
            if (errorHandler) {
                [weakSelf performCallBackWithBlock:^{ errorHandler(error); }];
            }
        }
        else {
            if (successHandler) {
                [weakSelf performCallBackWithBlock:^{ successHandler(); }];
            }
        }
    };
    [operation addExecutionBlock:operationBlock];
    [self.dataQueue addOperation:operation];
    return operation;
}

#pragma mark - Item Info -

- (TOSMBSessionFile *)itemAttributesAtPath:(NSString *)path error:(NSError **)error{
    
    TOSMBSessionFile *file = nil;
    
    //Attempt a connection attempt (If it has not already been done)
    NSError *resultError = [self attemptConnection];
    if (error && resultError)
        *error = resultError;
    
    if (resultError){
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
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    
    //Work out just the share name from the path (The first directory in the string)
    NSString *shareName = [self shareNameFromPath:path];
    
    //Connect to that share
    //If not, make a new connection
    const char *cStringName = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    smb_tid shareID = smb_tree_connect(self.session, cStringName);
    if (shareID < 0) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed);
            *error = resultError;
        }
        return nil;
    }
    
    //work out the remainder of the file path and create the search query
    NSString *relativePath = [self filePathExcludingSharePathFromPath:path];
    //prepend double backslashes
    relativePath = [NSString stringWithFormat:@"\\%@",relativePath];
    //replace any additional forward slashes with backslashes
    relativePath = [relativePath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]; //replace forward slashes with backslashes
    
    smb_stat stat = smb_fstat(self.session, shareID, relativePath.UTF8String);
    
    if(stat==NULL){
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeFileNotFound);
            *error = resultError;
        }
    }
    else{
        file = [[TOSMBSessionFile alloc] initWithName:path.lastPathComponent stat:stat parentDirectoryFilePath:[path stringByDeletingLastPathComponent]];
        smb_stat_destroy(stat);
    }
    smb_tree_disconnect(self.session, shareID);
    return file;
}

- (NSOperation *)itemAttributesAtPath:(NSString *)path success:(void (^)(TOSMBSessionFile *))successHandler error:(void (^)(NSError *))errorHandler{
    
    //setup operation queue as needed
    [self setupDataQueue];
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    __weak typeof(self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    
    id operationBlock = ^{
        if (weakOperation.isCancelled) { return; }
        
        NSError *error = nil;
        TOSMBSessionFile *file = [weakSelf itemAttributesAtPath:path error:&error];
        
        if (weakOperation.isCancelled) { return; }
        
        if (error) {
            if (errorHandler) {
                [weakSelf performCallBackWithBlock:^{ errorHandler(error); }];
            }
        }
        else {
            if (successHandler) {
                [weakSelf performCallBackWithBlock:^{ successHandler(file); }];
            }
        }
    };
    [operation addExecutionBlock:operationBlock];
    [self.dataQueue addOperation:operation];
    return operation;
}

#pragma mark - Move Item -

- (BOOL)moveItemAtPath:(NSString *)fromPath toPath:(NSString *)toPath error:(NSError **)error{
    
    NSError *resultError = [self attemptConnection];
    if (error && resultError){
        *error = resultError;
    }
    
    if (resultError){
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
    fromPath = [fromPath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    toPath = [toPath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    
    //Work out just the share name from the path (The first directory in the string)
    NSString *shareName = [self shareNameFromPath:fromPath];
    
    //Connect to that share
    //If not, make a new connection
    const char *cStringName = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    smb_tid shareID = smb_tree_connect(self.session, cStringName);
    if (shareID < 0) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed);
            *error = resultError;
        }
        return NO;
    }
    
    NSString *relativeFromPath = [self filePathExcludingSharePathFromPath:fromPath];
    relativeFromPath = [NSString stringWithFormat:@"\\%@",relativeFromPath];
    relativeFromPath = [relativeFromPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    
    NSString *relativeToPath = [self filePathExcludingSharePathFromPath:toPath];
    relativeToPath = [NSString stringWithFormat:@"\\%@",relativeToPath];
    relativeToPath = [relativeToPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    
    const char *relativeFromPathCString = [relativeFromPath cStringUsingEncoding:NSUTF8StringEncoding];
    const char *relativeToPathCString = [relativeToPath cStringUsingEncoding:NSUTF8StringEncoding];
    
    int result = smb_file_mv(self.session, shareID, relativeFromPathCString, relativeToPathCString);
    
    if(result!=0){
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeUnableToMoveFile);
            *error = resultError;
        }
    }
    
    smb_tree_disconnect(self.session, shareID);
    
    return (result==0);
}

- (NSOperation *)moveItemAtPath:(NSString *)fromPath toPath:(NSString *)toPath success:(void (^)(TOSMBSessionFile *newFile))successHandler error:(void (^)(NSError *))errorHandler{
    [self setupDataQueue];
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    __weak typeof(self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    id operationBlock = ^{
        if (weakOperation.isCancelled) { return; }
        NSError *error = nil;
        BOOL success = [weakSelf moveItemAtPath:fromPath toPath:toPath error:&error];
        if (weakOperation.isCancelled) { return; }
        if (success==NO || error) {
            if (errorHandler) {
                [weakSelf performCallBackWithBlock:^{ errorHandler(error); }];
            }
        }
        else {
            TOSMBSessionFile *file = [weakSelf itemAttributesAtPath:toPath error:&error];
            if (successHandler) {
                [weakSelf performCallBackWithBlock:^{ successHandler(file); }];
            }
        }
    };
    [operation addExecutionBlock:operationBlock];
    [self.dataQueue addOperation:operation];
    return operation;
}


#pragma mark - Create Directory -

- (BOOL)createDirectoryAtPath:(NSString *)path error:(NSError **)error{
    
    NSError *resultError = [self attemptConnection];
    if (error && resultError){
        *error = resultError;
    }
    
    if (resultError){
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
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    
    //Work out just the share name from the path (The first directory in the string)
    NSString *shareName = [self shareNameFromPath:path];
    
    //Connect to that share
    //If not, make a new connection
    const char *cStringName = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    smb_tid shareID = smb_tree_connect(self.session, cStringName);
    if (shareID < 0) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed);
            *error = resultError;
        }
        return NO;
    }
    
    NSString *relativePath = [self filePathExcludingSharePathFromPath:path];
    relativePath = [NSString stringWithFormat:@"\\%@",relativePath];
    relativePath = [relativePath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    
    const char *relativePathCString = [relativePath cStringUsingEncoding:NSUTF8StringEncoding];

    int result = smb_directory_create(self.session,shareID,relativePathCString);
    
    if(result!=0){
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeUnableToCreateDirectory);
            *error = resultError;
        }
    }
    
    smb_tree_disconnect(self.session, shareID);
    
    return (result==0);
}

- (NSOperation *)createDirectoryAtPath:(NSString *)path success:(void (^)(TOSMBSessionFile *createdDirectory))successHandler error:(void (^)(NSError *))errorHandler{
    [self setupDataQueue];
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    __weak typeof(self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    id operationBlock = ^{
        if (weakOperation.isCancelled) { return; }
        NSError *error = nil;
        BOOL success = [weakSelf createDirectoryAtPath:path error:&error];
        if (weakOperation.isCancelled) { return; }
        if (success==NO || error) {
            if (errorHandler) {
                [weakSelf performCallBackWithBlock:^{ errorHandler(error); }];
            }
        }
        else {
            TOSMBSessionFile *file = [weakSelf itemAttributesAtPath:path error:&error];
            if (successHandler) {
                [weakSelf performCallBackWithBlock:^{ successHandler(file); }];
            }
        }
    };
    [operation addExecutionBlock:operationBlock];
    [self.dataQueue addOperation:operation];
    return operation;
}


#pragma mark - Delete Item -


- (BOOL)recursiveContentOfDirectoryAtPath:(NSString *)dirPath inShare:(smb_tid)shareID items:(NSMutableArray **)items error:(NSError **)error{
    
    if (dirPath.length == 0 || [dirPath isEqualToString:@"/"]) {
        if (error) {
            NSError *resultError = errorForErrorCode(TOSMBSessionErrorCodeUnknown);
            *error = resultError;
        }
        return NO;
    }
    
    NSString *path = dirPath;
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    
    NSString *relativePath = [self filePathExcludingSharePathFromPath:path];
    relativePath = [NSString stringWithFormat:@"\\%@",relativePath];
    relativePath = [relativePath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    if (![[relativePath substringFromIndex:relativePath.length-1] isEqualToString:@"\\"]){
        relativePath = [relativePath stringByAppendingString:@"\\"];
    }
    relativePath = [relativePath stringByAppendingString:@"*"];
    const char *relativePathCString = [relativePath cStringUsingEncoding:NSUTF8StringEncoding];
    smb_stat_list statList = smb_find(self.session, shareID, relativePathCString);
    
    if(statList==NULL){
        if (error) {
            NSError *resultError = errorForErrorCode(TOSMBSessionErrorCodeUnknown);
            *error = resultError;
        }
        return NO;
    }

    size_t listCount = smb_stat_list_count(statList);
    
    NSMutableArray *directories = [[NSMutableArray alloc] init];
    
    if (listCount > 0){
        for (NSInteger i = 0; i < listCount; i++) {
            smb_stat item = smb_stat_list_at(statList, i);
            const char* name = smb_stat_name(item);
            NSString *itemName = [[NSString alloc] initWithBytes:name length:strlen(name) encoding:NSUTF8StringEncoding];
            if([itemName isEqualToString:@"."] || [itemName isEqualToString:@".."]){
                continue;
            }
            TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:item parentDirectoryFilePath:path];
            
            if(items){
                [*items addObject:file];
            }
            
            if(file.directory){
                [directories addObject:file];
            }
        }
    }
    smb_stat_list_destroy(statList);
    
    for(TOSMBSessionFile *dir in directories){
        BOOL result = [self recursiveContentOfDirectoryAtPath:dir.filePath inShare:shareID items:items error:error];
        if(result==NO){
            return NO;
        }
    }
    
    return YES;
}


- (BOOL)deleteDirectoryAtPath:(NSString *)dirPath inShare:(smb_tid)shareID error:(NSError **)error{
    
    if (dirPath.length == 0 || [dirPath isEqualToString:@"/"]) {
        if (error) {
            NSError *resultError = errorForErrorCode(TOSMBSessionErrorCodeUnknown);
            *error = resultError;
        }
        return NO;
    }
    
    NSString *path = dirPath;
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSString *relativePath = [self filePathExcludingSharePathFromPath:path];
    relativePath = [NSString stringWithFormat:@"\\%@",relativePath];
    relativePath = [relativePath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    
    const char *relativePathCString = [relativePath cStringUsingEncoding:NSUTF8StringEncoding];
    
    uint32_t result = smb_directory_rm(self.session, shareID, relativePathCString);
    
    if(result!=0){
        if (error) {
            *error = errorForErrorCode(TOSMBSessionErrorCodeUnableToDeleteItem);
        }
    }
    
    return (result==0);
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
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    
    NSString *relativePath = [self filePathExcludingSharePathFromPath:path];
    relativePath = [NSString stringWithFormat:@"\\%@",relativePath];
    relativePath = [relativePath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    
    const char *relativePathCString = [relativePath cStringUsingEncoding:NSUTF8StringEncoding];
    
    uint32_t result = smb_file_rm(self.session, shareID, relativePathCString);

    if(result!=0){
        if (error) {
            *error = errorForErrorCode(TOSMBSessionErrorCodeUnableToDeleteItem);
        }
    }

    return (result==0);
}

- (BOOL)deleteItemAtPath:(NSString *)path error:(NSError **)error{
    
    NSError *resultError = [self attemptConnection];
    int result = -1;
    if (error && resultError){
        *error = resultError;
    }
    
    if (resultError){
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
    path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    
    //Work out just the share name from the path (The first directory in the string)
    NSString *shareName = [self shareNameFromPath:path];
    
    //Connect to that share
    //If not, make a new connection
    const char *cStringName = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    smb_tid shareID = smb_tree_connect(self.session, cStringName);
    if (shareID < 0) {
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed);
            *error = resultError;
        }
        return NO;
    }
    
    NSString *relativePath = [self filePathExcludingSharePathFromPath:path];
    relativePath = [NSString stringWithFormat:@"\\%@",relativePath];
    relativePath = [relativePath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    
    const char *relativePathCString = [relativePath cStringUsingEncoding:NSUTF8StringEncoding];
    
    smb_stat stat = smb_fstat(self.session, shareID, relativePathCString);
    
    if(stat==NULL){
        if (error) {
            resultError = errorForErrorCode(TOSMBSessionErrorCodeFileNotFound);
            *error = resultError;
        }
    }
    else{
        
        BOOL directory = (smb_stat_get(stat, SMB_STAT_ISDIR) != 0);
        smb_stat_destroy(stat);

        if(directory){
            
            NSMutableArray *childItems = [[NSMutableArray alloc] init];
            BOOL fetchResultSuccess = [self recursiveContentOfDirectoryAtPath:path inShare:shareID items:&childItems error:nil];
            
            if(fetchResultSuccess){
                if(childItems.count>0){
                    for(NSInteger index = childItems.count-1;index>=0;index--){
                        TOSMBSessionFile *file = [childItems objectAtIndex:index];
                        BOOL success = NO;
                        if(file.directory){
                           success = [self deleteDirectoryAtPath:file.filePath inShare:shareID error:nil];
                        }
                        else{
                            success = [self deleteFileAtPath:file.filePath inShare:shareID error:nil];
                        }
                        if(success==NO){
                            break;
                        }
                    }
                }
                result = [self deleteDirectoryAtPath:path inShare:shareID error:error];
            }
            else{
                result = -1;
            }
            
        }
        else{
            result = [self deleteFileAtPath:path inShare:shareID error:error];
        }

        if(result!=0){
            
            //double check
            smb_stat stat = smb_fstat(self.session, shareID, relativePathCString);
            if(stat==NULL){
                if(error){
                    *error = nil;
                }
                result = 0;
            }
            else{
                smb_stat_destroy(stat);
                if (error) {
                    resultError = errorForErrorCode(TOSMBSessionErrorCodeUnableToDeleteItem);
                    *error = resultError;
                }
                
            }
        }
    }
    
    smb_tree_disconnect(self.session, shareID);
    
    return (result==0);
}

- (NSOperation *)deleteItemAtPath:(NSString *)path success:(void (^)(void))successHandler error:(void (^)(NSError *))errorHandler{
    [self setupDataQueue];
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    __weak typeof(self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    id operationBlock = ^{
        if (weakOperation.isCancelled) { return; }
        NSError *error = nil;
        BOOL success = [weakSelf deleteItemAtPath:path error:&error];
        if (weakOperation.isCancelled) { return; }
        if (success==NO) {
            if (errorHandler) {
                [weakSelf performCallBackWithBlock:^{ errorHandler(error); }];
            }
        }
        else {
            if (successHandler) {
                [weakSelf performCallBackWithBlock:^{ successHandler(); }];
            }
        }
    };
    [operation addExecutionBlock:operationBlock];
    [self.dataQueue addOperation:operation];
    return operation;
}


#pragma mark - Upload Task -

- (TOSMBSessionUploadTask *)uploadTaskForFileAtPath:(NSString *)path
                                    destinationPath:(NSString *)destinationPath
                                    progressHandler:(void (^)(uint64_t totalBytesWritten, uint64_t totalBytesExpected))progressHandler
                                  completionHandler:(void (^)(NSString *filePath))completionHandler
                                        failHandler:(void (^)(NSError *error))errorHandler{
    [self setupTransferQueue];
    TOSMBSessionUploadTask *task = [[TOSMBSessionUploadTask alloc] initWithSession:self filePath:path destinationPath:destinationPath progressHandler:progressHandler successHandler:completionHandler failHandler:errorHandler];
    return task;
}

#pragma mark - Concurrency Management -

- (void)setupDataQueue{
    if (self.dataQueue){
        return;
    }
    self.dataQueue = [[NSOperationQueue alloc] init];
    self.dataQueue.maxConcurrentOperationCount = 1;
}

- (void)setupTransferQueue{
    if (self.transferQueue){
        return;
    }
    self.transferQueue = [[NSOperationQueue alloc] init];
    self.transferQueue.maxConcurrentOperationCount = 1;
}

- (void)performCallBackWithBlock:(void(^)(void))block{
    __weak typeof (self) weakSelf = self;
    NSParameterAssert(self.callBackQueue);
    dispatch_async(self.callBackQueue, ^{
        @synchronized(weakSelf){
            if(block){
                block();
            }
        }
    });
}

#pragma mark - String Parsing -
- (NSString *)shareNameFromPath:(NSString *)path
{
    path = [path copy];
    
    //Remove any potential slashes at the start
    if ([[path substringToIndex:2] isEqualToString:@"//"]) {
        path = [path substringFromIndex:2];
    }
    else if ([[path substringToIndex:1] isEqualToString:@"/"]) {
        path = [path substringFromIndex:1];
    }
    
    NSRange range = [path rangeOfString:@"/"];
    
    if (range.location != NSNotFound)
        path = [path substringWithRange:NSMakeRange(0, range.location)];
    
    return path;
}

- (NSString *)filePathExcludingSharePathFromPath:(NSString *)path
{
    path = [path copy];
    
    //Remove any potential slashes at the start
    if ([[path substringToIndex:2] isEqualToString:@"//"] || [[path substringToIndex:2] isEqualToString:@"\\\\"]) {
        path = [path substringFromIndex:2];
    }
    else if ([[path substringToIndex:1] isEqualToString:@"/"] || [[path substringToIndex:1] isEqualToString:@"\\"]) {
        path = [path substringFromIndex:1];
    }
    
    NSRange range = [path rangeOfString:@"/"];
    if (range.location == NSNotFound) {
        range = [path rangeOfString:@"\\"];
    }
    
    if (range.location != NSNotFound)
        path = [path substringFromIndex:range.location+1];
    
    return path;
}

#pragma mark - Accessors -
- (NSInteger)guest
{
    if (self.session == NULL)
        return -1;
    
    return smb_session_is_guest(self.session);
}

- (TOSMBSessionState)state
{
    if (self.session == NULL)
        return TOSMBSessionStateError;
    
    return smb_session_state(self.session);
}

- (BOOL)isConnected{
    return self.state==TOSMBSessionStateSessionOK;
}

@end
