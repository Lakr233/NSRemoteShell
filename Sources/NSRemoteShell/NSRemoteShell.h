//
//  NSRemoteShell.h
//
//
//  Created by Lakr Aream on 2022/2/4.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSRemoteShell : NSObject

@property (nonatomic, readonly, getter=isConnected) BOOL connected;
@property (nonatomic, readonly, getter=isAuthenicated) BOOL authenticated;

@property (nonatomic, readonly, nonnull, strong) NSString *remoteHost;
@property (nonatomic, readonly, nonnull, strong) NSNumber *remotePort;
@property (nonatomic, readonly, nonnull, strong) NSNumber *operationTimeout;

@property (nonatomic, readonly, nullable, strong) NSString *resolvedRemoteIpAddress;
@property (nonatomic, readonly, nullable, strong) NSString *remoteBanner;
@property (nonatomic, readonly, nullable, strong) NSString *remoteFingerPrint;

#pragma mark initializer

- (instancetype)init;
- (instancetype)setupConnectionHost:(nonnull NSString *)targetHost;
- (instancetype)setupConnectionPort:(nonnull NSNumber *)targetPort;
- (instancetype)setupConnectionTimeout:(nonnull NSNumber *)timeout;

#pragma mark event loop

- (void)handleRequestsIfNeeded;
- (void)explicitRequestStatusPickup;

#pragma mark connection

- (instancetype)requestConnectAndWait;
- (instancetype)requestDisconnectAndWait;

#pragma mark authenticate

- (instancetype)authenticateWith:(nonnull NSString *)username
                     andPassword:(nonnull NSString *)password;
- (instancetype)authenticateWith:(NSString *)username
                            andPublicKey:(nullable NSString *)publicKey
                            andPrivateKey:(NSString *)privateKey
                             andPassword:(nullable NSString *)password;

#pragma mark execution

- (instancetype)executeRemote:(NSString*)command
             withExecTimeout:(NSNumber*)timeoutSecond
                  withOutput:(nullable void (^)(NSString*))responseDataBlock
     withContinuationHandler:(nullable BOOL (^)(void))continuationBlock;

- (instancetype)openShellWithTerminal:(nullable NSString*)terminalType
                    withTermianlSize:(nullable CGSize (^)(void))requestTermianlSize
                       withWriteData:(nullable NSString* (^)(void))requestWriteData
                          withOutput:(void (^)(NSString * _Nonnull))responseDataBlock
             withContinuationHandler:(BOOL (^)(void))continuationBlock;

@end

NS_ASSUME_NONNULL_END
