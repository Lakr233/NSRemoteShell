//
//  NSRemoteEvent.m
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

// TS: Thread Safe

#import "TSEventLoop.h"

@implementation NSRemoteShellWeakReference

- (instancetype)initWith:(NSRemoteShell *)remoteObject {
    self = [super init];
    if (self) {
        self.representedObject = remoteObject;
    }
    return self;
}

@end

@interface TSEventLoop () 

@property (nonatomic, nonnull, strong) NSThread *associatedThread;
@property (nonatomic, nonnull, strong) NSRunLoop *associatedRunLoop;
@property (nonatomic, nonnull, strong) NSTimer *associatedTimer;
@property (nonatomic, nonnull, strong) NSPort *associatedPort;

@property (nonatomic, nonnull, strong) NSLock *concurrentLock;
@property (nonatomic, nonnull, strong) dispatch_queue_t concurrentQueue;
@property (nonatomic) NSMutableArray<NSRemoteShellWeakReference*> *delegatedObjects;

@end

@implementation TSEventLoop

+(id)sharedLoop {
    static TSEventLoop *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self.concurrentQueue = dispatch_queue_create("wiki.qaq.remote.event.concurrent", DISPATCH_QUEUE_CONCURRENT);
    self.delegatedObjects = [[NSMutableArray alloc] init];
    self.associatedThread = [[NSThread alloc] initWithTarget:self
                                                    selector:@selector(associatedThreadHandler)
                                                      object:NULL];
    self.concurrentLock = [[NSLock alloc] init];
    [self.associatedThread start];
    return [super init];
}

- (void)dealloc {
    NSLog(@"deallocating %p", self);
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
    
    self.associatedTimer = [[NSTimer alloc] initWithFireDate: [[NSDate alloc] init]
                            interval:0.2
                            target:self selector:@selector(associatedLoopHandler)
                            userInfo:NULL
                            repeats:YES];
    [self.associatedRunLoop addTimer:self.associatedTimer forMode:NSRunLoopCommonModes];
    
    NSLog(@"%@ %p run loop started", [self className], self);
    [self.associatedRunLoop run];
    NSLog(@"%@ %p run loop stopped", [self className], self);
    assert(false);
}

- (void)handleMachMessage:(void *)msg {
    // we don't care about the message, if received any, call handler
    [self associatedLoopHandler];
}

- (void)associatedLoopHandler {
    BOOL tryLock = [self.concurrentLock tryLock];
    if (tryLock) {
        [self processUncheckedLoopDispatch];
        [self.concurrentLock unlock];
    }
}

- (void)delegatingRemoteWith:(NSRemoteShell *)object {
    [self.concurrentLock lock];
    NSRemoteShellWeakReference *ref = [[NSRemoteShellWeakReference alloc] initWith:object];
    [self.delegatedObjects addObject:ref];
    [self uncheckedConcurrencyCleanPointerArray];
    [self.concurrentLock unlock];
}

- (void)uncheckedConcurrencyCleanPointerArray {
    NSMutableArray *newArray = [[NSMutableArray<NSRemoteShellWeakReference*> alloc] init];
    for (NSRemoteShellWeakReference *ref in self.delegatedObjects) {
        if (ref.representedObject) { [newArray addObject:ref]; }
    }
    self.delegatedObjects = newArray;
}

- (void)processUncheckedLoopDispatch {
    dispatch_group_t group = dispatch_group_create();
    BOOL garbageFound = NO;
    for (id delegatedObject in self.delegatedObjects) {
        if (!delegatedObject) {
            garbageFound = YES;
            continue;
        }
        if (![delegatedObject isKindOfClass: [NSRemoteShellWeakReference self]]) {
            garbageFound = YES;
            continue;
        }
        NSRemoteShellWeakReference *object = delegatedObject;
        if (!object.representedObject) {
            garbageFound = YES;
            continue;
        }
        dispatch_group_enter(group);
        dispatch_async(self.concurrentQueue, ^{
            [object.representedObject handleRequestsIfNeeded];
            dispatch_group_leave(group);
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    if (garbageFound) {
        [self uncheckedConcurrencyCleanPointerArray];
    }
}

@end
