# NSRemoteShell

Remote shell using libssh2 with Objective-C. Thread safe implementation. Available as Swift Package.

## git

`libssh2` prebuilt binaries are required to build this package. Either clone with recursive submodules or update after clone. Bitcode is available.

> git submodule update --init --recursive --remote

See following options to learn more.

- https://github.com/Lakr233/CSSH 
- https://github.com/DimaRU/Libssh2Prebuild

## Usage

In our design, all operation is blocked, and is recommended to call in background thread.

```
NSRemoteShell()
    .setupConnectionHost(host)
    .setupConnectionPort(NSNumber(value: port))
    .requestConnectAndWait()
    .authenticate(with: username, andPassword: password)
    .executeRemote(
        command,
        withExecTimeout: .init(value: 0)
    ) {
        createOutput($0) 
    } withContinuationHandler: {
        commandStatus != .terminating
    }
```

To connect, call setup function to set host and port. Class is designed with Swift function-like syntax chain.

```
-(instancetype)setupConnectionHost:(nonnull NSString *)targetHost;
-(instancetype)setupConnectionPort:(nonnull NSNumber *)targetPort;
-(instancetype)setupConnectionTimeout:(nonnull NSNumber *)timeout;

-(instancetype)requestConnectAndWait;
-(instancetype)requestDisconnectAndWait;
```

There is two authenticate method provided. Authenticate is required after connect.

**Do not change username when authenticateing the same session.**

```
-(instancetype)authenticateWith:(nonnull NSString *)username
                     andPassword:(nonnull NSString *)password;
-(instancetype)authenticateWith:(NSString *)username
                            andPublicKey:(nullable NSString *)publicKey
                            andPrivateKey:(NSString *)privateKey
                             andPassword:(nullable NSString *)password;
```

For various session property, see property list.

```
@property(nonatomic, readwrite, nullable, strong) NSString *resolvedRemoteIpAddress;
@property(nonatomic, readwrite, nullable, strong) NSString *remoteBanner;
@property(nonatomic, readwrite, nullable, strong) NSString *remoteFingerPrint;

@property(nonatomic, readwrite, getter=isConnected) BOOL connected;
@property(nonatomic, readwrite, getter=isAuthenicated) BOOL authenticated;
```

Request either command channel or shell channel with designated API, and do not access unexposed values. It may break the ARC or crash the app.

```
-(instancetype)executeRemote:(NSString*)command
             withExecTimeout:(NSNumber*)timeoutSecond
                  withOutput:(nullable void (^)(NSString*))responseDataBlock
     withContinuationHandler:(nullable BOOL (^)(void))continuationBlock;

-(instancetype)openShellWithTerminal:(nullable NSString*)terminalType
                    withTermianlSize:(nullable CGSize (^)(void))requestTermianlSize
                       withWriteData:(nullable NSString* (^)(void))requestWriteData
                          withOutput:(void (^)(NSString * _Nonnull))responseDataBlock
             withContinuationHandler:(BOOL (^)(void))continuationBlock;
```

## Thread Safe

We implemented thread safe by using NSEventLoop to serialize single NSRemoteShell instance. Multiple NSRemoteShell object will be executed in parallel. Channel operations will be executed in serial for
each NSRemoteShell.

```
@interface NSRemoteEventLoop : NSObject

+(id)sharedLoop;

-(void)delegatingRemoteWith:(NSRemoteShell*)object;

-(void)startup;
-(void)terminate;

@end
```

ARC will take place to disconnect if a shell object is no longer holds. You can close the session manually or let ARC handle it.

```
-(void)dealloc {
    NSLog(@"shell object at %p deallocating", self);
    [self uncheckedConcurrencyDisconnect];
}
```

## LICENSE

NSRemoteShell is licensed under [MIT License - Lakr's Edition].

```
Permissions
- Commercial use
- Modification
- Distribution
- Private use

Limitations
- NO Liability
- NO Warranty

Conditions
- NO Conditions
```

---

Copyright © 2022 Lakr Aream. All Rights Reserved.
