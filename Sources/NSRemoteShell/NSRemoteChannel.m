//
//  NSRemoteChannel.m
//  
//
//  Created by Lakr Aream on 2022/2/6.
//

#import "NSRemoteChannel.h"

@interface NSRemoteChannelWriteBuffer : NSObject
@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) NSUInteger offset;
@end

@implementation NSRemoteChannelWriteBuffer
@end

@interface NSRemoteChannel ()

@property (nonatomic, nullable, readwrite, assign) LIBSSH2_SESSION *representedSession;
@property (nonatomic, nullable, readwrite, assign) LIBSSH2_CHANNEL *representedChannel;

@property (nonatomic, nullable, strong) NSRemoteChannelRequestDataBlock requestDataBlock;
@property (nonatomic, nullable, strong) NSRemoteChannelReceiveDataBlock receiveDataBlock;
@property (nonatomic, nullable, strong) NSRemoteChannelContinuationBlock continuationDecisionBlock;
@property (nonatomic, nullable, strong) NSRemoteChannelTerminalSizeBlock requestTerminalSizeBlock;

@property (nonatomic) CGSize currentTerminalSize;

@property (nonatomic, nullable, strong) NSDate *scheduledTermination;
@property (nonatomic, nullable, strong) dispatch_block_t terminationBlock;

@property (nonatomic, readwrite) BOOL channelCompleted;
@property (nonatomic, readwrite, assign) int exitStatus;

// 写入队列管理（兼容旧接口的异步实现）
@property (nonatomic, strong) NSMutableArray<NSRemoteChannelWriteBuffer *> *writeQueue;
@property (nonatomic, strong) NSLock *writeQueueLock;

@end

@implementation NSRemoteChannel

// MARK: - LIFE CYCLE

- (instancetype)initWithRepresentedSession:(LIBSSH2_SESSION *)representedSession
                     withRepresentedChanel:(LIBSSH2_CHANNEL *)representedChannel
{
    self = [super init];
    if (self) {
        _representedSession = representedSession;
        _representedChannel = representedChannel;
        _channelCompleted = NO;
        _currentTerminalSize = CGSizeMake(0, 0);
        _exitStatus = 0;
        _writeQueue = [[NSMutableArray alloc] init];
        _writeQueueLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    NSLog(@"channel object at %p deallocating", self);
    [self unsafeDisconnectAndPrepareForRelease];
}

// MARK: - SETUP

- (void)onTermination:(dispatch_block_t)terminationHandler {
    self.terminationBlock = terminationHandler;
}

- (void)setRequestDataChain:(NSRemoteChannelRequestDataBlock _Nonnull)requestData {
    self.requestDataBlock = requestData;
}

- (void)setRecivedDataChain:(NSRemoteChannelReceiveDataBlock _Nonnull)receiveData {
    self.receiveDataBlock = receiveData;
}

- (void)setContinuationChain:(NSRemoteChannelContinuationBlock _Nonnull)continuation {
    self.continuationDecisionBlock = continuation;
}

- (void)setTerminalSizeChain:(NSRemoteChannelTerminalSizeBlock _Nonnull)terminalSize {
    self.requestTerminalSizeBlock = terminalSize;
}

- (void)setChannelTimeoutWith:(double)timeoutValueFromNowInSecond {
    if (timeoutValueFromNowInSecond <= 0) {
#if DEBUG
        NSLog(@"setChannelTimeoutWith was called with negative value or zero, setChannelTimeoutWithScheduled skipped");
#endif
    } else {
        NSDate *schedule = [[NSDate alloc] initWithTimeIntervalSinceNow:timeoutValueFromNowInSecond];
        [self setChannelTimeoutWithScheduled:schedule];
    }
}

- (void)setChannelTimeoutWithScheduled:(NSDate*)timeoutDate {
    self.scheduledTermination = timeoutDate;
}

- (void)setChannelCompleted:(BOOL)channelCompleted {
    if (_channelCompleted != channelCompleted) {
        _channelCompleted = channelCompleted;
        [self unsafeDisconnectAndPrepareForRelease];
    }
}

// MARK: - EXEC

- (BOOL)seatbeltCheckPassed {
    if (!self.representedSession) { self.channelCompleted = YES; return NO; }
    if (!self.representedChannel) { self.channelCompleted = YES; return NO; }
    return YES;
}

- (void)unsafeChannelRead {
    char buffer[BUFFER_SIZE];
    char errorBuffer[BUFFER_SIZE];
    memset(buffer, 0, sizeof(buffer));
    memset(errorBuffer, 0, sizeof(errorBuffer));
    
    long rcout = libssh2_channel_read(self.representedChannel, buffer, (ssize_t)sizeof(buffer));
    long rcerr = libssh2_channel_read_stderr(self.representedChannel, errorBuffer, (ssize_t)sizeof(errorBuffer));
    
    if (rcout != LIBSSH2_ERROR_EAGAIN && rcout > 0) {
        NSString *read = [[NSString alloc] initWithUTF8String:buffer];
        if (self.receiveDataBlock) {
            self.receiveDataBlock(read);
        }
    }
    if (rcerr != LIBSSH2_ERROR_EAGAIN && rcerr > 0) {
        NSString *read = [[NSString alloc] initWithUTF8String:errorBuffer];
        if (self.receiveDataBlock) {
            self.receiveDataBlock(read);
        }
    }
}

- (void)unsafeChannelWrite {
    // 首先处理旧的requestDataBlock方式（兼容现有接口）
    if (self.requestDataBlock) {
        NSString *requestedBuffer = self.requestDataBlock();
        if (requestedBuffer && [requestedBuffer length] > 0) {
            NSData *data = [requestedBuffer dataUsingEncoding:NSUTF8StringEncoding];
            if (data && [data length] > 0) {
                // 将回调数据添加到队列中异步发送
                [self.writeQueueLock lock];
                NSRemoteChannelWriteBuffer *buffer = [[NSRemoteChannelWriteBuffer alloc] init];
                buffer.data = data;
                buffer.offset = 0;
                [self.writeQueue addObject:buffer];
                [self.writeQueueLock unlock];
            }
        }
    }
    
    // 处理写入队列
    [self.writeQueueLock lock];
    
    while (self.writeQueue.count > 0) {
        NSRemoteChannelWriteBuffer *buffer = self.writeQueue.firstObject;
        
        const char *bytes = (const char *)buffer.data.bytes + buffer.offset;
        size_t remainingLength = buffer.data.length - buffer.offset;
        
        long rc = libssh2_channel_write(self.representedChannel, bytes, remainingLength);
        
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            // 稍后重试
            break;
        } else if (rc < 0) {
            NSLog(@"error occurred during channel write: %ld", rc);
            [self.writeQueue removeObjectAtIndex:0];
            break;
        } else if (rc > 0) {
            buffer.offset += rc;
            if (buffer.offset >= buffer.data.length) {
                // 完整发送完毕
                [self.writeQueue removeObjectAtIndex:0];
            }
        }
        
        if ([self unsafeChannelShouldTerminate]) {
            break;
        }
    }
    
    [self.writeQueueLock unlock];
}

- (BOOL)unsafeChannelShouldTerminate {
    do {
        if (self.scheduledTermination && [self.scheduledTermination timeIntervalSinceNow] < 0) {
            NSLog(@"channel terminating due to timeout schedule");
            break;
        }
        if (self.continuationDecisionBlock && !self.continuationDecisionBlock()) {
            break;
        }
        long rc = libssh2_channel_eof(self.representedChannel);
        if (rc == 1) {
            break;
        }
        if (rc < 0 && rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        return NO;
    } while (0);
    self.channelCompleted = YES;
    return YES;
}

- (void)unsafeChannelTerminalSizeUpdate {
    // may called from outside
    if (![self seatbeltCheckPassed]) { return; }
    if (!self.requestTerminalSizeBlock) {
        return;
    }
    CGSize targetSize = self.requestTerminalSizeBlock();
    if (CGSizeEqualToSize(targetSize, self.currentTerminalSize)) {
        return;
    }
    self.currentTerminalSize = targetSize;
    while (true) {
        long rc = libssh2_channel_request_pty_size(self.representedChannel,
                                                   targetSize.width,
                                                   targetSize.height);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        // don't check error here?
        break;
    }
}

- (void)unsafeCallNonblockingOperations {
    if (self.channelCompleted) { return; }
    if (![self seatbeltCheckPassed]) { return; }
    [self unsafeChannelRead];
    [self unsafeChannelTerminalSizeUpdate];
    [self unsafeChannelWrite];
    [self unsafeChannelShouldTerminate];
}

- (BOOL)unsafeInsanityCheckAndReturnDidSuccess {
    do {
        if (self.channelCompleted) { break; }
        if (![self seatbeltCheckPassed]) { break; }
        return YES;
    } while (0);
    return NO;
}

- (void)unsafeDisconnectAndPrepareForRelease {
    if (!self.channelCompleted) { self.channelCompleted = YES; }
    
    // 清理写入队列
    [self.writeQueueLock lock];
    [self.writeQueue removeAllObjects];
    [self.writeQueueLock unlock];
    
    if (!self.representedSession) { return; }
    if (!self.representedChannel) { return; }
    LIBSSH2_CHANNEL *channel = self.representedChannel;
    self.representedChannel = NULL;
    self.representedSession = NULL;
    while (libssh2_channel_send_eof(channel) == LIBSSH2_ERROR_EAGAIN) {};
    while (libssh2_channel_close(channel) == LIBSSH2_ERROR_EAGAIN) {};
    while (libssh2_channel_wait_closed(channel) == LIBSSH2_ERROR_EAGAIN) {};
    int es = libssh2_channel_get_exit_status(channel);
    NSLog(@"channel get exit status returns: %d", es);
    self.exitStatus = es;
    while (libssh2_channel_free(channel) == LIBSSH2_ERROR_EAGAIN) {};
    if (self.terminationBlock) { self.terminationBlock(); }
    self.terminationBlock = NULL;
}

@end
