//
//  NSRemoteShell.m
//
//
//  Created by Lakr Aream on 2022/2/4.
//

#import "NSRemoteShell.h"
#import "NSRemoteEvent.h"
#import "NSRemoteChannel.h"

#import "GenericHeaders.h"
#import "GenericNetworking.h"

#import "Constructor.h"

@interface NSRemoteShell ()

@property(nonatomic, nonnull, strong) NSString *remoteHost;
@property(nonatomic, nonnull, strong) NSNumber *remotePort;
@property(nonatomic, nonnull, strong) NSNumber *operationTimeout;

@property(nonatomic, readwrite, nullable, strong) NSString *resolvedRemoteIpAddress;
@property(nonatomic, readwrite, nullable, strong) NSString *remoteBanner;
@property(nonatomic, readwrite, nullable, strong) NSString *remoteFingerPrint;

@property(nonatomic, readwrite, getter=isConnected) BOOL connected;
@property(nonatomic, readwrite, getter=isAuthenicated) BOOL authenticated;

@property(nonatomic, nullable, assign) CFSocketRef associatedSocket;
@property(nonatomic, nullable, assign) LIBSSH2_SESSION *associatedSession;

@property(nonatomic, nonnull) NSMutableArray<NSRemoteChannel*> *associatedChannel;
@property(nonatomic, nonnull) NSMutableArray *requestInvokations;

@end

@implementation NSRemoteShell

#pragma mark init

-(instancetype)init {
    self = [super init];
    self.remoteHost = @"";
    self.remotePort = @(22);
    self.operationTimeout = @(8);
    self.connected = NO;
    self.authenticated = NO;
    self.resolvedRemoteIpAddress = NULL;
    
    self.associatedSocket = NULL;
    self.associatedSession = NULL;
    self.associatedChannel = [[NSMutableArray alloc] init];
    
    self.requestInvokations = [[NSMutableArray alloc] init];
    
    [[NSRemoteEventLoop sharedLoop] delegatingRemoteWith:self];
    
    return self;
}

-(void)dealloc {
    NSLog(@"shell object at %p deallocating", self);
    [self uncheckedConcurrencyDisconnect];
}

-(instancetype)setupConnectionHost:(NSString *)targetHost {
    @synchronized(self) {
        [self setRemoteHost:targetHost];
    }
    return self;
}

-(instancetype)setupConnectionPort:(NSNumber *)targetPort {
    @synchronized(self) {
        [self setRemotePort:targetPort];
    }
    return self;
}

-(instancetype)setupConnectionTimeout:(NSNumber *)timeout {
    @synchronized(self) {
        [self setOperationTimeout:timeout];
    }
    return self;
}

// MARK: - EVENT LOOP

-(void)eventLoopHandleMessage {
    @synchronized (self.requestInvokations) {
        for (dispatch_block_t invocation in self.requestInvokations) {
            if (invocation) { invocation(); }
        }
        [self.requestInvokations removeAllObjects];
        for (NSRemoteChannel *channelObject in [self.associatedChannel copy]) {
            if (![self uncheckedConcurrencyValidateChannel:channelObject]) {
                continue;
            }
            [channelObject insanityUncheckedEventLoop];
            // channle close will happen inside the validate
            [self uncheckedConcurrencyValidateChannel:channelObject];
        }
    }
}

// MARK: - API

-(instancetype)requestConnectAndWait {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __weak typeof(self) magic = self;
    @synchronized (self.requestInvokations) {
        id block = [^{
            [magic uncheckedConcurrencyConnect];
            dispatch_semaphore_signal(sem);
        } copy];
        [self.requestInvokations addObject:block];
    }
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return self;
}

-(instancetype)requestDisconnectAndWait {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __weak typeof(self) magic = self;
    @synchronized (self.requestInvokations) {
        id block = [^{
            [magic uncheckedConcurrencyDisconnect];
            dispatch_semaphore_signal(sem);
        } copy];
        [self.requestInvokations addObject:block];
    }
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return self;
}

-(instancetype)authenticateWith:(NSString *)username andPassword:(NSString *)password {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __weak typeof(self) magic = self;
    @synchronized (self.requestInvokations) {
        id block = [^{
            [magic uncheckedConcurrencyAuthenticateWith:username
                                            andPassword:password];
            dispatch_semaphore_signal(sem);
        } copy];
        [self.requestInvokations addObject:block];
    }
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return self;
}

-(instancetype)authenticateWith:(NSString *)username andPublicKey:(NSString *)publicKey andPrivateKey:(NSString *)privateKey andPassword:(NSString *)password {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __weak typeof(self) magic = self;
    @synchronized (self.requestInvokations) {
        id block = [^{
            [magic uncheckedConcurrencyAuthenticateWith:username
                                           andPublicKey:publicKey
                                          andPrivateKey:privateKey
                                            andPassword:password];
            dispatch_semaphore_signal(sem);
        } copy];
        [self.requestInvokations addObject:block];
    }
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return self;
}

-(instancetype)executeRemote:(NSString *)command
              withExecTimeout:(NSNumber *)timeoutSecond
                   withOutput:(void (^)(NSString * _Nonnull))responseDataBlock
      withContinuationHandler:(BOOL (^)(void))continuationBlock
{
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __weak typeof(self) magic = self;
    @synchronized (self.requestInvokations) {
        id block = [^{
            [magic uncheckedConcurrencyExecuteRemote:command
                                     withExecTimeout:timeoutSecond
                                          withOutput:responseDataBlock
                             withContinuationHandler:continuationBlock
                             withCompletionSemaphore:sem];
        } copy];
        [self.requestInvokations addObject:block];
    }
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return self;
}

-(instancetype)openShellWithTerminal:(nullable NSString*)terminalType
                    withTermianlSize:(nullable CGSize (^)(void))requestTermianlSize
                       withWriteData:(nullable NSString* (^)(void))requestWriteData
                          withOutput:(void (^)(NSString * _Nonnull))responseDataBlock
             withContinuationHandler:(BOOL (^)(void))continuationBlock
{
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __weak typeof(self) magic = self;
    @synchronized (self.requestInvokations) {
        id block = [^{
            [magic uncheckedConcurrencyOpenShellWithTerminal:terminalType
                                            withTermianlSize:requestTermianlSize
                                               withWriteData:requestWriteData
                                                  withOutput:responseDataBlock
                                     withContinuationHandler:continuationBlock
                                     withCompletionSemaphore:sem];
        } copy];
        [self.requestInvokations addObject:block];
    }
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return self;
}

// MARK: - UNCHECKED CONCURRENCY

-(void)uncheckedConcurrencyConnect {
    [self uncheckedConcurrencyDisconnect];
    NSArray *candidateHosts = [GenericNetworking resolveIpAddressesFor:self.remoteHost];
    BOOL constructCompleted = NO;
    for (id candidateAddressData in candidateHosts) {
        constructCompleted = [self uncheckedConcurrencyConstructConnectionAndReturnSuccess: candidateAddressData];
        if (constructCompleted) {
            break;
        }
    }
    CFSocketRef socket = self.associatedSocket;
    if (!constructCompleted || !socket) {
        [self uncheckedConcurrencyDisconnect];
        return;
    }
    
    LIBSSH2_SESSION *constructorSession = libssh2_session_init_ex(0, 0, 0, (__bridge void *)(self));
    if (!constructorSession) {
        [self uncheckedConcurrencyDisconnect];
        return;
    }
    self.associatedSession = constructorSession;
    
    [self uncheckedConcurrencySessionSetTimeoutWith:constructorSession
                                    andTimeoutValue:[self.operationTimeout doubleValue]];
    
    libssh2_session_set_blocking(constructorSession, 0);
    BOOL sessionHandshakeComplete = NO;
    while (true) {
        long rc = libssh2_session_handshake(constructorSession, CFSocketGetNative(socket));
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        sessionHandshakeComplete = (rc == 0);
        break;
    }
    if (!sessionHandshakeComplete) {
        [self uncheckedConcurrencyDisconnect];
    }
    
    do {
        const char *banner = libssh2_session_banner_get(constructorSession);
        if (banner) {
            NSString *generateBanner = [[NSString alloc] initWithUTF8String:banner];
            self.remoteBanner = generateBanner;
        }
    } while (0);
    
    do {
        const char *hash = libssh2_hostkey_hash(constructorSession, LIBSSH2_HOSTKEY_HASH_SHA1);
        if (hash) {
            NSMutableString *fingerprint = [[NSMutableString alloc]
                                            initWithFormat:@"%02X", (unsigned char)hash[0]];
            for (int i = 1; i < 20; i++) {
                [fingerprint appendFormat:@":%02X", (unsigned char)hash[i]];
            }
            self.remoteFingerPrint = [fingerprint copy];
        }
    } while (0);
    
    self.connected = YES;
    NSLog(@"constructed libssh2 session to %@ with %@", self.remoteHost, self.resolvedRemoteIpAddress);
}

-(void)uncheckedConcurrencyDisconnect {
    for (NSRemoteChannel *channel in [self.associatedChannel copy]) {
        [channel uncheckedConcurrencyChannelCloseIfNeeded];
    }
    [self.associatedChannel removeAllObjects];
    
    [self uncheckedConcurrencySessionCloseFor:self.associatedSession];
    self.associatedSession = NULL;
    
    if (self.associatedSocket) {
        CFSocketInvalidate(self.associatedSocket);
        CFRelease(self.associatedSocket);
    }
    self.associatedSocket = NULL;
    
    self.connected = NO;
    self.authenticated = NO;
    
    self.resolvedRemoteIpAddress = NULL;
    self.remoteBanner = NULL;
    self.remoteFingerPrint = NULL;
}

-(void)uncheckedConcurrencySessionCloseFor:(LIBSSH2_SESSION*)session {
    if (!session) return;
    while (libssh2_session_disconnect(session, "closed by client") == LIBSSH2_ERROR_EAGAIN) {};
    while (libssh2_session_free(session) == LIBSSH2_ERROR_EAGAIN) {};
    self.associatedSession = NULL;
}

-(void)uncheckedConcurrencySessionSetTimeoutWith:(LIBSSH2_SESSION*)session
                                  andTimeoutValue:(double)timeoutValue
{
    if (!session) return;
    libssh2_session_set_timeout(session, timeoutValue);
}

-(BOOL)uncheckedConcurrencyConstructConnectionAndReturnSuccess:(id)withCandidateAddressData {
    int port = [self.remotePort integerValue];
    double timeout = [self.operationTimeout doubleValue];
    NSMutableString *resolvedIpAddress = [[NSMutableString alloc] init];
    _Nullable CFSocketRef socket = [GenericNetworking connectSocketWith:withCandidateAddressData
                                                               withPort: port
                                                            withTimeout:timeout
                                                          withIpAddress:resolvedIpAddress];
    if (!socket) {
        return NO;
    }
    self.associatedSocket = socket;
    self.resolvedRemoteIpAddress = resolvedIpAddress;
    return YES;
}

-(BOOL)uncheckedConcurrencyValidateSession
{
    do {
        if (!self.associatedSocket) { break; }
        if (!self.associatedSession) { break; }
        if (!self.connected) { break; }
        return YES;
    } while (0);
    [self uncheckedConcurrencyDisconnect];
    return NO;
}

-(void)uncheckedConcurrencyChannelCleanup {
    NSMutableArray *newArray = [[NSMutableArray alloc] init];
    for (NSRemoteChannel *channel in [self.associatedChannel copy]) {
        // will be closed if not valid
        if (!channel.representedChannel) { continue; }
        [newArray addObject:channel];
    }
    self.associatedChannel = newArray;
}

-(BOOL)uncheckedConcurrencyValidateChannel:(NSRemoteChannel*)channel
{
    do {
        if (![self uncheckedConcurrencyValidateSession]) {
            break;
        }
        if (channel.channelCompleted) {
            break;
        }
        if (![self uncheckedConcurrencyValidateRawChannel:channel.representedChannel]) {
            break;
        }
        return YES;
    } while (0);
    [channel uncheckedConcurrencyChannelCloseIfNeeded];
    [self uncheckedConcurrencyChannelCleanup];
    return NO;
}

-(BOOL)uncheckedConcurrencyValidateRawChannel:(LIBSSH2_CHANNEL*)channel
{
    if (!channel) { return NO; }
    return YES;
}

-(void)uncheckedConcurrencyAuthenticateWith:(NSString *)username
                                 andPassword:(NSString *)password
{
    if (![self uncheckedConcurrencyValidateSession]) {
        [self uncheckedConcurrencyDisconnect];
        return;
    }
    if (self.authenticated) {
        return;
    }
    LIBSSH2_SESSION *session = self.associatedSession;
    BOOL authenticated = NO;
    while (true) {
        int rc = libssh2_userauth_password(session, [username UTF8String], [password UTF8String]);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        authenticated = (rc == 0);
        break;
    }
    if (authenticated) {
        self.authenticated = YES;
        NSLog(@"authenticate success");
    }
}

-(void)uncheckedConcurrencyAuthenticateWith:(NSString *)username
                                andPublicKey:(NSString *)publicKey
                               andPrivateKey:(NSString *)privateKey
                                 andPassword:(NSString *)password
{
    if (![self uncheckedConcurrencyValidateSession]) {
        [self uncheckedConcurrencyDisconnect];
        return;
    }
    if (self.authenticated) {
        return;
    }
    LIBSSH2_SESSION *session = self.associatedSession;
    BOOL authenticated = NO;
    while (true) {
        int rc = libssh2_userauth_publickey_frommemory(session,
                                                       [username UTF8String], [username length],
                                                       [publicKey UTF8String] ?: nil, [publicKey length] ?: 0,
                                                       [privateKey UTF8String] ?: nil, [privateKey length] ?: 0,
                                                       [password UTF8String]);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        authenticated = (rc == 0);
        break;
    }
    if (authenticated) {
        self.authenticated = YES;
        NSLog(@"authenticate success");
    }
}

-(void)uncheckedConcurrencyExecuteRemote:(NSString *)command
                          withExecTimeout:(NSNumber *)timeoutSecond
                               withOutput:(void (^)(NSString * _Nonnull))responseDataBlock
                  withContinuationHandler:(BOOL (^)(void))continuationBlock
                  withCompletionSemaphore:(dispatch_semaphore_t)completionSemaphore
{
    if (![self uncheckedConcurrencyValidateSession]) {
        [self uncheckedConcurrencyDisconnect];
        dispatch_semaphore_signal(completionSemaphore);
        return;
    }
    if (!self.authenticated) {
        dispatch_semaphore_signal(completionSemaphore);
        return;
    }
    LIBSSH2_SESSION *session = self.associatedSession;
    LIBSSH2_CHANNEL *channel = NULL;
    while (true) {
        LIBSSH2_CHANNEL *channelBuilder = libssh2_channel_open_session(session);
        if (channelBuilder) {
            channel = channelBuilder;
            break;
        }
        long rc = libssh2_session_last_errno(session);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        break;
    }
    if (!channel) {
        NSLog(@"failed to allocate channel");
        dispatch_semaphore_signal(completionSemaphore);
        return;
    }
    NSRemoteChannel *channelObject = [[NSRemoteChannel alloc] initWithRepresentedSession:session
                                                                   withRepresentedChanel:channel];
    
    BOOL channelStartupCompleted = NO;
    while (true) {
        long rc = libssh2_channel_exec(channel, [command UTF8String]);
        if (rc == LIBSSH2_ERROR_EAGAIN) { continue; }
        channelStartupCompleted = (rc == 0);
        break;
    }
    if (!channelStartupCompleted) {
        [channelObject uncheckedConcurrencyChannelCloseIfNeeded];
        dispatch_semaphore_signal(completionSemaphore);
        return;
    }
    
    [channelObject setChannelTimeoutWith:[timeoutSecond doubleValue]];
    
    if (responseDataBlock) { [channelObject setRecivedDataChain:responseDataBlock]; }
    if (continuationBlock) { [channelObject setContinuationChain:continuationBlock]; }
    
    if (completionSemaphore) {
        [channelObject onTermination:^{
            dispatch_semaphore_signal(completionSemaphore);
        }];
    }
    
    [self.associatedChannel addObject:channelObject];
}

-(void)uncheckedConcurrencyOpenShellWithTerminal:(nullable NSString*)terminalType
                                withTermianlSize:(nullable CGSize (^)(void))requestTermianlSize
                                   withWriteData:(nullable NSString* (^)(void))requestWriteData
                                      withOutput:(void (^)(NSString * _Nonnull))responseDataBlock
                         withContinuationHandler:(BOOL (^)(void))continuationBlock
                         withCompletionSemaphore:(dispatch_semaphore_t)completionSemaphore
{
    if (![self uncheckedConcurrencyValidateSession]) {
        [self uncheckedConcurrencyDisconnect];
        dispatch_semaphore_signal(completionSemaphore);
        return;
    }
    if (!self.authenticated) {
        dispatch_semaphore_signal(completionSemaphore);
        return;
    }
    LIBSSH2_SESSION *session = self.associatedSession;
    LIBSSH2_CHANNEL *channel = NULL;
    while (true) {
        LIBSSH2_CHANNEL *channelBuilder = libssh2_channel_open_session(session);
        if (channelBuilder) {
            channel = channelBuilder;
            break;
        }
        long rc = libssh2_session_last_errno(session);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        break;
    }
    if (!channel) {
        NSLog(@"failed to allocate channel");
        dispatch_semaphore_signal(completionSemaphore);
        return;
    }
    NSRemoteChannel *channelObject = [[NSRemoteChannel alloc] initWithRepresentedSession:session
                                                                   withRepresentedChanel:channel];
    if (requestTermianlSize) { [channelObject setTerminalSizeChain:requestTermianlSize]; }
    if (requestWriteData) { [channelObject setRequestDataChain:requestWriteData]; }
    if (responseDataBlock) { [channelObject setRecivedDataChain:responseDataBlock]; }
    if (continuationBlock) { [channelObject setContinuationChain:continuationBlock]; }
    
    do {
        NSString *requestPseudoTermial = @"xterm";
        if (terminalType) { requestPseudoTermial = terminalType; }
        BOOL requestedPty = NO;
        while (true) {
            long rc = libssh2_channel_request_pty(channel, [requestPseudoTermial UTF8String]);
            if (rc == LIBSSH2_ERROR_EAGAIN) {
                continue;
            }
            requestedPty = (rc == 0);
            break;
        }
        if (!requestedPty) {
            NSLog(@"failed to request pty");
            [channelObject uncheckedConcurrencyChannelCloseIfNeeded];
            dispatch_semaphore_signal(completionSemaphore);
            return;
        }
    } while (0);
    
    [channelObject uncheckedConcurrencyChannelTerminalSizeUpdate];
    
    do {
        BOOL channelStartupCompleted = NO;
        while (true) {
            long rc = libssh2_channel_shell(channel);
            if (rc == LIBSSH2_ERROR_EAGAIN) { continue; }
            channelStartupCompleted = (rc == 0);
            break;
        }
        if (!channelStartupCompleted) {
            [channelObject uncheckedConcurrencyChannelCloseIfNeeded];
            dispatch_semaphore_signal(completionSemaphore);
            return;
        }
    } while (0);
    
    if (completionSemaphore) {
        [channelObject onTermination:^{
            dispatch_semaphore_signal(completionSemaphore);
        }];
    }
    
    [self.associatedChannel addObject:channelObject];
    
}


@end
