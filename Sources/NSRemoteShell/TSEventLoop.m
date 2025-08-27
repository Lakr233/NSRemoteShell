//
//  TSEventLoop.m
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

// TS: Thread Safe

#import "TSEventLoop.h"

@interface TSEventLoop () 

@property (nonatomic, nonnull, strong) NSThread *associatedThread;
@property (nonatomic, nonnull, strong) NSRunLoop *associatedRunLoop;
@property (nonatomic, nonnull, strong) NSPort *associatedPort;
@property (nonatomic, nullable, weak) NSRemoteShell *parent;
@property (nonatomic, nonnull, strong) NSEventDrivenIO *eventIO;
@property (nonatomic, assign) BOOL shouldStop;

@end

@implementation TSEventLoop

- (instancetype)initWithParent:(__weak NSRemoteShell*)parent {
    if (self = [super init]) {
        _parent = parent;
        _shouldStop = NO;
        _eventIO = [[NSEventDrivenIO alloc] initWithDelegate:self];
        
        _associatedThread = [[NSThread alloc] initWithTarget:self
                                                    selector:@selector(associatedThreadHandler)
                                                      object:NULL];
        NSString *threadName = [[NSString alloc] initWithFormat:@"wiki.qaq.shell.%p", parent];
        [_associatedThread setName:threadName];
        NSLog(@"opening thread %@", threadName);
        [_associatedThread start];
    }
    return self;
}

- (void)dealloc {
    NSLog(@"TSEventLoop object at %p deallocating", self);
    [self destroyLoop];
}

- (NSEventDrivenIO *)eventIO {
    return _eventIO;
}

- (void)explicitRequestHandle {
    [self.associatedPort sendBeforeDate:[[NSDate alloc] init]
                             components:NULL
                                   from:NULL
                               reserved:NO];
}

- (void)associatedThreadHandler {
    self.associatedRunLoop = [NSRunLoop currentRunLoop];
    
    self.associatedPort = [[NSPort alloc] init];
    self.associatedPort.delegate = self;
    [self.associatedRunLoop addPort:self.associatedPort forMode:NSRunLoopCommonModes];
    
    // 启动事件驱动IO
    [self.eventIO startEventLoop];
    
    // 运行事件循环，但不再使用定时器轮询
    while (!self.shouldStop && [self.associatedRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]) {
        // 处理RunLoop事件
    }
    
    NSLog(@"thread %@ exiting", [[NSThread currentThread] name]);
}

- (void)handleMachMessage:(void *)msg {
    // 当收到显式请求时，立即处理
    [self associatedLoopHandler];
}

- (void)associatedLoopHandler {
    if (!self.parent) {
        [self destroyLoop];
        return;
    }
#if DEBUG
    NSString *name = [[NSThread currentThread] name];
    NSString *want = [[NSString alloc] initWithFormat:@"wiki.qaq.shell.%p", self.parent];
    if (![name isEqualToString:want]) {
        NSLog(@"\n\n");
        NSLog(@"[E] shell name mismatch");
        NSLog(@"expect: %@", want);
        NSLog(@" found: %@", name);
        NSLog(@"\n\n");
    }
#endif
    [self.parent handleRequestsIfNeeded];
}

- (void)destroyLoop {
    self.shouldStop = YES;
    
    // 停止事件驱动IO
    [self.eventIO stopEventLoop];
    
    // 移除端口并停止RunLoop
    if (self.associatedRunLoop && self.associatedPort) {
        [self.associatedRunLoop removePort:self.associatedPort forMode:NSRunLoopCommonModes];
    }
    
    CFRunLoopRef runLoop = [self.associatedRunLoop getCFRunLoop];
    if (runLoop) { 
        CFRunLoopStop(runLoop); 
    }
}

#pragma mark - NSIOEventDelegate

- (void)ioEvent:(NSIOEventType)eventType onSocket:(int)socket {
    // 当有IO事件时，立即触发事件处理
    dispatch_async(dispatch_get_main_queue(), ^{
        [self explicitRequestHandle];
    });
}

- (void)ioSocketClosed:(int)socket {
    NSLog(@"Socket %d closed by event system", socket);
    // 通知父对象socket已关闭
    dispatch_async(dispatch_get_main_queue(), ^{
        [self explicitRequestHandle];
    });
}

@end
