# NSRemoteShell 网络IO重构

本次重构彻底改进了网络IO处理，引入了高效的事件驱动机制，并去掉了手动发送方法。

## 主要改进

### 1. 事件驱动IO系统

引入了基于kqueue的高效事件驱动IO系统 (`NSEventDrivenIO`)：

- **真正的异步IO**：使用macOS原生kqueue机制，无需轮询
- **自动写入队列**：数据自动排队发送，无需手动管理
- **高效的事件处理**：只在有真实IO事件时才处理，大幅减少CPU使用

### 2. 移除手动发送方法

- 去掉了 `setRequestDataChain` 回调方式
- 新增异步写入接口：
  ```objc
  - (void)writeData:(NSString *)data;
  - (void)writeDataAsync:(NSData *)data;
  ```

### 3. 改进的事件循环

- 移除了定时器轮询（原来每100ms + 50次/秒）
- 只在有实际IO事件时才触发处理
- 使用事件驱动替代dispatch_source

### 4. 更好的非阻塞IO

- 所有socket默认使用非阻塞模式
- 改进了连接建立逻辑，正确处理EINPROGRESS
- 减少了EAGAIN等待时间（从800us降到100us）

## 使用示例

### 旧的方式（已移除）：
```objc
[channel setRequestDataChain:^NSString * _Nonnull{
    // 手动管理数据发送
    return dataToSend;
}];
```

### 新的方式：
```objc
// 异步发送数据，自动排队
[channel writeData:@"command\n"];
[channel writeDataAsync:someDataObject];
```

### Shell交互示例：
```objc
NSRemoteShell *shell = [[NSRemoteShell alloc] init];
[shell setupConnectionHost:@"example.com"];
[shell requestConnectAndWait];
[shell authenticateWith:@"username" andPassword:@"password"];

[shell beginShellWithTerminalType:@"xterm"
                     withOnCreate:^{
                         NSLog(@"Shell created");
                     }
                 withTerminalSize:^CGSize{
                     return CGSizeMake(80, 24);
                 }
              withWriteDataBuffer:^NSString *{
                     // 这个方法现在会被异步处理
                     return commandToSend;
                 }
             withOutputDataBuffer:^(NSString *output) {
                     NSLog(@"Output: %@", output);
                 }
          withContinuationHandler:^BOOL{
                     return shouldContinue;
                 }];
```

## 性能提升

1. **CPU使用率**：事件驱动减少了无意义的轮询，CPU使用率显著降低
2. **响应性**：真正的异步IO，响应更及时
3. **内存效率**：写入队列按需分配，避免内存浪费
4. **网络效率**：更好的非阻塞处理，避免阻塞操作

## 技术细节

### 事件驱动IO架构

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   NSRemoteShell │────│   TSEventLoop    │────│ NSEventDrivenIO │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │                        │
                                │                        │ kqueue
                                │                        ▼
                       ┌──────────────────┐    ┌─────────────────┐
                       │ NSRemoteChannel  │    │   Kernel Events │
                       │ NSLocalForward   │    │   (Read/Write)  │
                       │ NSRemoteForward  │    └─────────────────┘
                       └──────────────────┘
```

### 写入队列管理

每个NSRemoteChannel都有独立的写入队列：
- 数据异步添加到队列
- 事件循环在写事件就绪时自动处理队列
- 支持部分写入和重试机制

这些改进使得NSRemoteShell更加高效、可靠和易用。
