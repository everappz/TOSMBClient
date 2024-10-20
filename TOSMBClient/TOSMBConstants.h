//
// TOSMBConstants.h
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

#import <Foundation/Foundation.h>

#define TOSMBMakeWeakReference()  __weak typeof(self) weakSelf = self;
#define TOSMBMakeStrongFromWeakReference()  __strong typeof(weakSelf) strongSelf = weakSelf;

#define TOSMBMakeWeakReferenceForOperation()  __weak typeof(operation) weakOperation = operation;
#define TOSMBMakeStrongFromWeakReferenceForOperation()  __strong typeof(weakOperation) strongOperation = weakOperation;

#define TOSMBCheckIfWeakReferenceForOperationIsCancelledOrNilAndReturn()  if ( weakOperation.isCancelled || weakOperation == nil ) { return; }
#define TOSMBCheckIfWeakReferenceIsNilAndReturn()  if ( weakSelf == nil ) { return; }


/** SMB Error Values */
typedef NS_ENUM(NSInteger, TOSMBSessionErrorCode)
{
    TOSMBSessionErrorCodeNone = 0,
    TOSMBSessionErrorCodeUnknown = 1,                               /* Error code was not specified. */
    TOSMBSessionErrorCodeUnableToResolveAddress = 1001,             /* Not enough connection information to resolve was supplied. */
    TOSMBSessionErrorCodeUnableToConnect = 1002,                    /* The connection attempt failed. */
    TOSMBSessionErrorCodeAuthenticationFailed = 1003,               /* The username/password failed (And guest login is not available) */
    TOSMBSessionErrorCodeShareConnectionFailed = 1004,              /* Connection attempt to a share in the device failed. */
    TOSMBSessionErrorCodeFileNotFound = 1005,                       /* Unable to locate the requested file. */
    TOSMBSessionErrorCodeDirectoryDownloaded = 1006,                /* A directory was attempted to be downloaded. */
    
    TOSMBSessionErrorCodeFileDownloadFailed = 1007,                /* The file could not be downloaded, possible network error. */
    
    TOSMBSessionErrorCodeUnableToMoveFile,
    TOSMBSessionErrorCodeUnableToCreateDirectory,
    TOSMBSessionErrorCodeUnableToDeleteItem,
    TOSMBSessionErrorCodeDirectoryUploaded,
    TOSMBSessionErrorCodeFailToUpload,
    TOSMBSessionErrorCodeCancelled, 
};

/** NetBIOS Service Device Types */
typedef NS_ENUM(NSInteger, TONetBIOSNameServiceType) {
    TONetBIOSNameServiceTypeWorkStation,
    TONetBIOSNameServiceTypeMessenger,
    TONetBIOSNameServiceTypeFileServer,
    TONetBIOSNameServiceTypeDomainMaster
};

/** SMB File Download Connection State */
typedef NS_ENUM(NSInteger, TOSMBSessionTransferTaskState) {
    TOSMBSessionTransferTaskStateReady,
    TOSMBSessionTransferTaskStateRunning,
    TOSMBSessionTransferTaskStateSuspended,
    TOSMBSessionTransferTaskStateCancelled,
    TOSMBSessionTransferTaskStateCompleted,
    TOSMBSessionTransferTaskStateFailed
};

extern TONetBIOSNameServiceType TONetBIOSNameServiceTypeForCType(char type);
extern char TONetBIOSNameServiceCTypeForType(char type);

extern NSString *localizedStringForErrorCode(TOSMBSessionErrorCode errorCode);
extern NSError *errorForErrorCode(TOSMBSessionErrorCode errorCode);

extern uint16_t TOSMBShareIDUnknown;
