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

#import "smb_session.h"
#import "smb_share.h"
#import "smb_stat.h"

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

@interface TOSMBSession ()

/* The session pointer responsible for this object. */
@property (nonatomic, assign) smb_session *session;

/* 1 == Guest, 0 == Logged in, -1 == Logged out */
@property (nonatomic, assign, readwrite) NSInteger guest;

@property (nonatomic, strong) NSOperationQueue *dataQueue; /* Operation queue for asynchronous data requests. */
@property (nonatomic, strong) NSOperationQueue *downloadsQueue; /* Operation queue for file downloads. */

@property (nonatomic, strong, readwrite) NSArray *downloadTasks;

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
- (void)setupDownloadQueue;

@property (nonatomic, strong)dispatch_queue_t callBackQueue;

@end

@implementation TOSMBSession

#pragma mark - Class Creation -

- (instancetype)init{
    if (self = [super init]) {
        self.callBackQueue = dispatch_queue_create([@"com.smbsession.callback.queue" cStringUsingEncoding:NSUTF8StringEncoding], NULL);
        _session = smb_session_new();
        if (_session == NULL)
            return nil;
    }
    return self;
}

- (instancetype)initWithHostName:(NSString *)name{
    if (self = [self init]) {
        _hostName = [name copy];
    }
    return self;
}

- (instancetype)initWithIPAddress:(NSString *)address{
    if (self = [self init]) {
        _ipAddress = [address copy];
    }
    return self;
}

- (instancetype)initWithHostName:(NSString *)name ipAddress:(NSString *)ipAddress{
    if (self = [self init]) {
        _hostName = [name copy];
        _ipAddress = [ipAddress copy];
    }
    return self;
}

- (instancetype)initWithHostNameOrIPAddress:(NSString *)hostNameOrIPaddress{
    if (self = [self init]) {
        if([self isDotQuadIP:hostNameOrIPaddress]){
            _ipAddress = [hostNameOrIPaddress copy];
        }
        else{
            _hostName = [hostNameOrIPaddress copy];
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
    smb_session_destroy(self.session);
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
    if (error)
        return error;
    
    self.guest = smb_session_is_guest(self.session);
    return nil;
}

- (NSError *)attemptConnectionWithSessionPointer:(smb_session *)session{
    
    //There's no point in attempting a potentially costly TCP attempt if we're not even on a local network.
    if ([self deviceIsOnWiFi] == NO) {
        return errorForErrorCode(TOSMBSessionErrorNotOnWiFi);
    }
    
    if (self.session == session) {
        if (self.lastRequestDate && [[NSDate date] timeIntervalSinceDate:self.lastRequestDate] > 60) {
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
    if (error && resultError)
        *error = resultError;
    
    if (resultError)
        return nil;
    
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
            TOSMBSessionFile *share = [[TOSMBSessionFile alloc] initWithShareName:shareNameString session:self];
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
    
    //Query for a list of files in this directory
    smb_stat_list statList = smb_find(self.session, shareID, relativePath.UTF8String);
    size_t listCount = smb_stat_list_count(statList);
    if (listCount == 0)
        return nil;
    
    NSMutableArray *fileList = [NSMutableArray array];
    
    for (NSInteger i = 0; i < listCount; i++) {
        smb_stat item = smb_stat_list_at(statList, i);
        const char* name = smb_stat_name(item);
        if (name[0] == '.') { //skip hidden files
            continue;
        }
        
        TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:item session:self parentDirectoryFilePath:path];
        [fileList addObject:file];
    }
    smb_stat_list_destroy(statList);
    smb_tree_disconnect(self.session, shareID);
    
    if (fileList.count == 0)
        return nil;
    
    return [fileList sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
}

- (NSOperation *)contentsOfDirectoryAtPath:(NSString *)path success:(void (^)(NSArray *))successHandler error:(void (^)(NSError *))errorHandler{
    
    //setup operation queue as needed
    [self setupDataQueue];
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    __weak typeof(self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    
    id operationBlock = ^{
        if (weakOperation.cancelled) { return; }
        
        NSError *error = nil;
        NSArray *files = [weakSelf contentsOfDirectoryAtPath:path error:&error];
        
        if (weakOperation.cancelled) { return; }
        
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
    [self setupDownloadQueue];
    TOSMBSessionDownloadTask *task = [[TOSMBSessionDownloadTask alloc] initWithSession:self filePath:path destinationPath:destinationPath delegate:delegate];
    self.downloadTasks = [self.downloadTasks ? : @[] arrayByAddingObjectsFromArray:@[task]];
    return task;
}

- (TOSMBSessionDownloadTask *)downloadTaskForFileAtPath:(NSString *)path
                                        destinationPath:(NSString *)destinationPath
                                        progressHandler:(void (^)(uint64_t totalBytesWritten, uint64_t totalBytesExpected))progressHandler
                                      completionHandler:(void (^)(NSString *filePath))completionHandler
                                            failHandler:(void (^)(NSError *error))failHandler{
    [self setupDownloadQueue];
    TOSMBSessionDownloadTask *task = [[TOSMBSessionDownloadTask alloc] initWithSession:self filePath:path destinationPath:destinationPath progressHandler:progressHandler successHandler:completionHandler failHandler:failHandler];
    self.downloadTasks = [self.downloadTasks ? : @[] arrayByAddingObjectsFromArray:@[task]];
    return task;
}

#pragma mark - Open Connection -

- (NSOperation *)requestOpenConnection:(void (^)(void))successHandler error:(void (^)(NSError *))errorHandler{
    //setup operation queue as needed
    [self setupDataQueue];
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    __weak typeof(self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    
    id operationBlock = ^{
        if (weakOperation.cancelled) { return; }
        
        NSError *error = [weakSelf attemptConnection];
        
        if (weakOperation.cancelled) { return; }
        
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

- (TOSMBSessionFile *)requestItemAtPath:(NSString *)path error:(NSError **)error{
    
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
        return nil;
    }
    
    TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithName:path.lastPathComponent stat:stat session:self parentDirectoryFilePath:[path stringByDeletingLastPathComponent]];
    
    smb_stat_destroy(stat);
    smb_tree_disconnect(self.session, shareID);
    
    return file;
}

- (NSOperation *)requestItemAtPath:(NSString *)path success:(void (^)(TOSMBSessionFile *))successHandler error:(void (^)(NSError *))errorHandler{
    
    //setup operation queue as needed
    [self setupDataQueue];
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    __weak typeof(self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    
    id operationBlock = ^{
        if (weakOperation.cancelled) { return; }
        
        NSError *error = nil;
        TOSMBSessionFile *file = [weakSelf requestItemAtPath:path error:&error];
        
        if (weakOperation.cancelled) { return; }
        
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


#pragma mark - Concurrency Management -

- (void)setupDataQueue{
    if (self.dataQueue){
        return;
    }
    self.dataQueue = [[NSOperationQueue alloc] init];
    self.dataQueue.maxConcurrentOperationCount = 1;
}

- (void)setupDownloadQueue{
    if (self.downloadsQueue){
        return;
    }
    self.downloadsQueue = [[NSOperationQueue alloc] init];
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
