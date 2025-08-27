//
//  NSEventDrivenIO.h
//  
//
//  Created by Lakr Aream on 2025/8/28.
//

#import "GenericHeaders.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, NSIOEventType) {
    NSIOEventTypeRead = 1,
    NSIOEventTypeWrite = 2,
    NSIOEventTypeError = 4
};

@protocol NSIOEventDelegate <NSObject>
- (void)ioEvent:(NSIOEventType)eventType onSocket:(int)socket;
- (void)ioSocketClosed:(int)socket;
@end

@interface NSEventDrivenIO : NSObject

@property (nonatomic, weak, nullable) id<NSIOEventDelegate> delegate;

- (instancetype)initWithDelegate:(id<NSIOEventDelegate>)delegate;

// 注册socket用于监听事件
- (BOOL)registerSocket:(int)socket forEvents:(NSIOEventType)events;
- (void)unregisterSocket:(int)socket;

// 异步写入数据（自动排队）
- (void)writeData:(NSData *)data toSocket:(int)socket;

// 启动和停止事件循环
- (void)startEventLoop;
- (void)stopEventLoop;

@end

NS_ASSUME_NONNULL_END
