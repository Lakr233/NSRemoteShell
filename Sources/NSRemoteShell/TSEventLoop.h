//
//  TSEventLoop.h
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

#import <Foundation/Foundation.h>

#import "GenericHeaders.h"
#import "NSRemoteShell.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSRemoteShellWeakReference : NSObject

@property (nonatomic, readwrite, weak) NSRemoteShell* representedObject;

- (instancetype)initWith:(NSRemoteShell*)remoteObject;

@end

@interface TSEventLoop : NSObject <NSPortDelegate>

+(id)sharedLoop;

- (void)explicitRequestHandle;
- (void)delegatingRemoteWith:(NSRemoteShell*)object;

@end

NS_ASSUME_NONNULL_END
