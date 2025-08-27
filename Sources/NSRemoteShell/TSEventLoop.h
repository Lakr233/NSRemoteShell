//
//  TSEventLoop.h
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

#import <Foundation/Foundation.h>

#import "GenericHeaders.h"
#import "NSRemoteShell.h"
#import "NSEventDrivenIO.h"

NS_ASSUME_NONNULL_BEGIN

@interface TSEventLoop : NSObject <NSPortDelegate, NSIOEventDelegate>

- (instancetype)initWithParent:(__weak NSRemoteShell*)parent;
- (void)explicitRequestHandle;
- (void)destroyLoop;

// 事件驱动IO接口
- (NSEventDrivenIO *)eventIO;

@end

NS_ASSUME_NONNULL_END
