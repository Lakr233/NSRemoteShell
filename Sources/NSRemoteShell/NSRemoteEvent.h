//
//  NSRemoteEventLoop.h
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

#import <Foundation/Foundation.h>

#import "GenericHeaders.h"
#import "NSRemoteShell.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSRemoteShellRef : NSObject

@property (nonatomic, readwrite, weak) NSRemoteShell* representedObject;

-(instancetype)initWith:(NSRemoteShell*)remoteObject;

@end

@interface NSRemoteEventLoop : NSObject

+(id)sharedLoop;

-(void)delegatingRemoteWith:(NSRemoteShell*)object;

-(void)startup;
-(void)terminate;

@end

NS_ASSUME_NONNULL_END
