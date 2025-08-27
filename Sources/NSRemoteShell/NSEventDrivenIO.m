//
//  NSEventDrivenIO.m
//  
//
//  Created by Lakr Aream on 2025/8/28.
//

#import "NSEventDrivenIO.h"
#import <sys/event.h>
#import <sys/time.h>
#import <errno.h>
#import <unistd.h>

@interface NSIOWriteBuffer : NSObject
@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) NSUInteger offset;
@end

@implementation NSIOWriteBuffer
@end

@interface NSEventDrivenIO ()
@property (nonatomic, assign) int kqueueFd;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) NSThread *eventThread;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray<NSIOWriteBuffer *> *> *writeBuffers;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *registeredSockets;
@property (nonatomic, strong) NSLock *buffersLock;
@end

@implementation NSEventDrivenIO

- (instancetype)initWithDelegate:(id<NSIOEventDelegate>)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _kqueueFd = -1;
        _isRunning = NO;
        _writeBuffers = [[NSMutableDictionary alloc] init];
        _registeredSockets = [[NSMutableSet alloc] init];
        _buffersLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self stopEventLoop];
}

- (BOOL)registerSocket:(int)socket forEvents:(NSIOEventType)events {
    if (socket < 0 || _kqueueFd < 0) {
        return NO;
    }
    
    struct kevent kevents[2];
    int nEvents = 0;
    
    if (events & NSIOEventTypeRead) {
        EV_SET(&kevents[nEvents], socket, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
        nEvents++;
    }
    
    if (events & NSIOEventTypeWrite) {
        EV_SET(&kevents[nEvents], socket, EVFILT_WRITE, EV_ADD | EV_ENABLE, 0, 0, NULL);
        nEvents++;
    }
    
    if (kevent(_kqueueFd, kevents, nEvents, NULL, 0, NULL) == -1) {
        NSLog(@"Failed to register socket %d for events: %s", socket, strerror(errno));
        return NO;
    }
    
    [_buffersLock lock];
    [_registeredSockets addObject:@(socket)];
    if (!_writeBuffers[@(socket)]) {
        _writeBuffers[@(socket)] = [[NSMutableArray alloc] init];
    }
    [_buffersLock unlock];
    
    NSLog(@"Registered socket %d for events %lu", socket, (unsigned long)events);
    return YES;
}

- (void)unregisterSocket:(int)socket {
    if (socket < 0 || _kqueueFd < 0) {
        return;
    }
    
    struct kevent kevents[2];
    EV_SET(&kevents[0], socket, EVFILT_READ, EV_DELETE, 0, 0, NULL);
    EV_SET(&kevents[1], socket, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
    
    // 忽略错误，因为socket可能已经关闭
    kevent(_kqueueFd, kevents, 2, NULL, 0, NULL);
    
    [_buffersLock lock];
    [_registeredSockets removeObject:@(socket)];
    [_writeBuffers removeObjectForKey:@(socket)];
    [_buffersLock unlock];
    
    NSLog(@"Unregistered socket %d", socket);
}

- (void)writeData:(NSData *)data toSocket:(int)socket {
    if (!data || data.length == 0 || socket < 0) {
        return;
    }
    
    [_buffersLock lock];
    NSMutableArray *buffers = _writeBuffers[@(socket)];
    if (buffers) {
        NSIOWriteBuffer *buffer = [[NSIOWriteBuffer alloc] init];
        buffer.data = data;
        buffer.offset = 0;
        [buffers addObject:buffer];
        
        // 触发写事件检查
        [self _enableWriteForSocket:socket];
    }
    [_buffersLock unlock];
}

- (void)_enableWriteForSocket:(int)socket {
    if (_kqueueFd < 0) return;
    
    struct kevent kevent_write;
    EV_SET(&kevent_write, socket, EVFILT_WRITE, EV_ENABLE, 0, 0, NULL);
    kevent(_kqueueFd, &kevent_write, 1, NULL, 0, NULL);
}

- (void)_disableWriteForSocket:(int)socket {
    if (_kqueueFd < 0) return;
    
    struct kevent kevent_write;
    EV_SET(&kevent_write, socket, EVFILT_WRITE, EV_DISABLE, 0, 0, NULL);
    kevent(_kqueueFd, &kevent_write, 1, NULL, 0, NULL);
}

- (void)startEventLoop {
    if (_isRunning) {
        return;
    }
    
    _kqueueFd = kqueue();
    if (_kqueueFd == -1) {
        NSLog(@"Failed to create kqueue: %s", strerror(errno));
        return;
    }
    
    _isRunning = YES;
    _eventThread = [[NSThread alloc] initWithTarget:self selector:@selector(_eventLoopThread) object:nil];
    [_eventThread setName:@"NSEventDrivenIO.EventLoop"];
    [_eventThread start];
    
    NSLog(@"Event loop started");
}

- (void)stopEventLoop {
    if (!_isRunning) {
        return;
    }
    
    _isRunning = NO;
    
    if (_kqueueFd >= 0) {
        close(_kqueueFd);
        _kqueueFd = -1;
    }
    
    // 等待线程结束
    if (_eventThread && ![_eventThread isFinished]) {
        while (![_eventThread isFinished]) {
            usleep(1000);
        }
    }
    
    [_buffersLock lock];
    [_writeBuffers removeAllObjects];
    [_registeredSockets removeAllObjects];
    [_buffersLock unlock];
    
    NSLog(@"Event loop stopped");
}

- (void)_eventLoopThread {
    @autoreleasepool {
        struct kevent events[64];
        struct timespec timeout = {0, 100000000}; // 100ms timeout
        
        while (_isRunning) {
            int nEvents = kevent(_kqueueFd, NULL, 0, events, 64, &timeout);
            
            if (nEvents == -1) {
                if (errno == EINTR) {
                    continue;
                }
                NSLog(@"kevent error: %s", strerror(errno));
                break;
            }
            
            for (int i = 0; i < nEvents; i++) {
                struct kevent *event = &events[i];
                int socket = (int)event->ident;
                
                if (event->flags & EV_EOF) {
                    [self _handleSocketClosed:socket];
                    continue;
                }
                
                if (event->flags & EV_ERROR) {
                    NSLog(@"Socket %d error: %ld", socket, event->data);
                    [self _handleSocketError:socket];
                    continue;
                }
                
                switch (event->filter) {
                    case EVFILT_READ:
                        [self _handleReadEvent:socket];
                        break;
                    case EVFILT_WRITE:
                        [self _handleWriteEvent:socket];
                        break;
                    default:
                        break;
                }
            }
        }
    }
}

- (void)_handleReadEvent:(int)socket {
    if (self.delegate && [self.delegate respondsToSelector:@selector(ioEvent:onSocket:)]) {
        [self.delegate ioEvent:NSIOEventTypeRead onSocket:socket];
    }
}

- (void)_handleWriteEvent:(int)socket {
    [_buffersLock lock];
    NSMutableArray *buffers = _writeBuffers[@(socket)];
    BOOL hasMoreData = NO;
    
    if (buffers && buffers.count > 0) {
        NSIOWriteBuffer *buffer = buffers.firstObject;
        
        const char *bytes = (const char *)buffer.data.bytes + buffer.offset;
        size_t remainingLength = buffer.data.length - buffer.offset;
        
        ssize_t written = send(socket, bytes, remainingLength, 0);
        if (written > 0) {
            buffer.offset += written;
            if (buffer.offset >= buffer.data.length) {
                [buffers removeObjectAtIndex:0];
            }
        } else if (written == -1 && errno != EAGAIN && errno != EWOULDBLOCK) {
            NSLog(@"Write error on socket %d: %s", socket, strerror(errno));
            [buffers removeObjectAtIndex:0];
        }
        
        hasMoreData = buffers.count > 0;
    }
    
    if (!hasMoreData) {
        [self _disableWriteForSocket:socket];
    }
    [_buffersLock unlock];
    
    // 通知代理写事件已处理
    if (self.delegate && [self.delegate respondsToSelector:@selector(ioEvent:onSocket:)]) {
        [self.delegate ioEvent:NSIOEventTypeWrite onSocket:socket];
    }
}

- (void)_handleSocketError:(int)socket {
    if (self.delegate && [self.delegate respondsToSelector:@selector(ioEvent:onSocket:)]) {
        [self.delegate ioEvent:NSIOEventTypeError onSocket:socket];
    }
}

- (void)_handleSocketClosed:(int)socket {
    [self unregisterSocket:socket];
    if (self.delegate && [self.delegate respondsToSelector:@selector(ioSocketClosed:)]) {
        [self.delegate ioSocketClosed:socket];
    }
}

@end
