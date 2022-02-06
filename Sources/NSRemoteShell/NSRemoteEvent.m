//
//  NSRemoteEvent.m
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

#import "NSRemoteEvent.h"

@implementation NSRemoteShellRef

-(instancetype)initWith:(NSRemoteShell *)remoteObject {
    self = [super init];
    if (self) {
        self.representedObject = remoteObject;
    }
    return self;
}

@end



@interface NSRemoteEventLoop ()

typedef enum _EVENT_LOOP_STATUS {
    EVENT_LOOP_STATUS_STOPPED = 0,
    EVENT_LOOP_STATUS_RUNNING = 1 << 1,
    EVENT_LOOP_STATUS_PENDING_MAINTAIN = 1 << 2,
    EVENT_LOOP_STATUS_DONE_MAINTAIN = 1 << 3,
    EVENT_LOOP_STATUS_MAINTAIN = 1 << 4,
    EVENT_LOOP_STATUS_TERMINATING = 1 << 5,
} EVENT_LOOP_STATUS;

@property (atomic) EVENT_LOOP_STATUS loopStatus;
@property (atomic) dispatch_queue_t loopQueue;
@property (atomic) dispatch_queue_t loopConcurrentDispatchQueue;

@property (nonatomic) NSMutableArray<NSRemoteShellRef*> *remoteObjects;

@end

@implementation NSRemoteEventLoop

+ (id)sharedLoop {
    static NSRemoteEventLoop *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

-(instancetype)init {
    self.loopStatus = EVENT_LOOP_STATUS_STOPPED;
    self.loopQueue = dispatch_queue_create("wiki.qaq.remote.event", 0);
    self.loopConcurrentDispatchQueue = dispatch_queue_create("wiki.qaq.remote.event.concurrent", DISPATCH_QUEUE_CONCURRENT);
    self.remoteObjects = [[NSMutableArray alloc] init];
    return [super init];
}

-(void)startup {
    if (self.loopStatus != EVENT_LOOP_STATUS_STOPPED) {
        NSLog(@"could not start duplicated event loop");
        return;
    }
    self.loopStatus = EVENT_LOOP_STATUS_RUNNING;
    dispatch_async(self.loopQueue, ^{
        [self processUncheckedLoopRun];
    });
}

-(void)maintenanceDelegatedObjects:(void (^)(void))requestBlock {
    if (self.loopStatus != EVENT_LOOP_STATUS_RUNNING) {
        NSLog(@"event loop not running");
        return;
    }
    self.loopStatus = EVENT_LOOP_STATUS_PENDING_MAINTAIN;
    while (self.loopStatus == EVENT_LOOP_STATUS_PENDING_MAINTAIN) {
        // wait for loop to pickup
    }
    if (requestBlock) { requestBlock(); }
    self.loopStatus = EVENT_LOOP_STATUS_DONE_MAINTAIN;
}

-(void)delegatingRemoteWith:(NSRemoteShell *)object {
    [self maintenanceDelegatedObjects:^{
        [self uncheckedConcurrencyCleanPointerArray];
        NSRemoteShellRef *ref = [[NSRemoteShellRef alloc] initWith:object];
        [self.remoteObjects addObject:ref];
    }];
}

-(void)uncheckedConcurrencyCleanPointerArray {
    NSMutableArray *newArray = [[NSMutableArray<NSRemoteShellRef*> alloc] init];
    for (NSRemoteShellRef *ref in self.remoteObjects) {
        if (ref.representedObject) { [newArray addObject:ref]; }
    }
    self.remoteObjects = newArray;
}

-(void)processUncheckedLoopRun {
    while (true) {
        usleep(0.01 * 1000000);
        if (self.loopStatus == EVENT_LOOP_STATUS_PENDING_MAINTAIN) {
            self.loopStatus = EVENT_LOOP_STATUS_MAINTAIN;
            continue;
        }
        if (self.loopStatus == EVENT_LOOP_STATUS_MAINTAIN) {
            continue;
        }
        if (self.loopStatus == EVENT_LOOP_STATUS_DONE_MAINTAIN) {
            self.loopStatus = EVENT_LOOP_STATUS_RUNNING;
        }
        
        if (self.loopStatus != EVENT_LOOP_STATUS_RUNNING) {
            NSLog(@"terminating event loop");
            self.loopStatus = EVENT_LOOP_STATUS_STOPPED;
            return;
        }
        // MARK: - ENTER PROCESS
        
        dispatch_group_t group = dispatch_group_create();
        BOOL garbageFound = NO;
        for (id delegatedObject in self.remoteObjects) {
            if (!delegatedObject) {
                garbageFound = YES;
                continue;
            }
            if (![delegatedObject isKindOfClass: [NSRemoteShellRef self]]) {
                garbageFound = YES;
                continue;
            }
            NSRemoteShellRef *object = delegatedObject;
            if (!object.representedObject) {
                garbageFound = YES;
                continue;
            }
            dispatch_group_enter(group);
            dispatch_async(self.loopConcurrentDispatchQueue, ^{
                [object.representedObject eventLoopHandleMessage];
                dispatch_group_leave(group);
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        
        if (garbageFound) {
            [self uncheckedConcurrencyCleanPointerArray];
        }
        
        // MARK:   EXIT PROCESS -
    }
}

-(void)terminate {
    if (self.loopStatus != EVENT_LOOP_STATUS_RUNNING) {
        NSLog(@"could not terminate none running loop");
        return;
    }
    self.loopStatus = EVENT_LOOP_STATUS_TERMINATING;
    while (self.loopStatus == EVENT_LOOP_STATUS_TERMINATING) {
        // wait for loop to stop
    }
    NSLog(@"event loop stopped!");
}

@end
