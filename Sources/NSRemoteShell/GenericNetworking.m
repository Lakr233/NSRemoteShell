//
//  GenericNetworking.m
//
//
//  Created by Lakr Aream on 2022/2/5.
//

#import "GenericNetworking.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <netdb.h>

@implementation GenericNetworking

+ (NSArray *)resolveIpAddressesFor:(NSString*)candidateHost
{
	if (!candidateHost) return [[NSArray alloc] init];
	NSArray<NSString *> *components = [candidateHost componentsSeparatedByString:@":"];
	NSInteger componentsCount = [components count];
	if (!components || componentsCount < 1) {
		return [[NSArray alloc] init];
	};

	// making target address
	NSString *resolvingAddress = components[0];

	// IPv6 Fixup
	if (componentsCount >= 4) {
		// handle case [{IPv6}]:{port}
		NSString *first = [components firstObject];
		NSString *last = [components lastObject];
		if ([first hasPrefix:@"["] && [last hasSuffix:@"]"]) {
			NSRange trailing = [candidateHost rangeOfString:@"]" options:NSBackwardsSearch];
			NSRange subRange = NSMakeRange(1, trailing.location - 1);
			resolvingAddress = [candidateHost substringWithRange:subRange];
		}
	} else if (componentsCount >= 3) {
		// handle case {IPv6}
		resolvingAddress = candidateHost;
	}
	if (!resolvingAddress || [resolvingAddress length] < 1) {
		return [[NSArray alloc] init];
	};

    NSArray<NSData*> *candidateHostData = [[NSArray alloc] init];
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = PF_UNSPEC;        // PF_INET if you want only IPv4 addresses
    hints.ai_protocol = IPPROTO_TCP;
    struct addrinfo *addrs, *addr;
    getaddrinfo([resolvingAddress UTF8String], NULL, &hints, &addrs);
    for (addr = addrs; addr; addr = addr->ai_next) {
        char host[NI_MAXHOST];
        getnameinfo(addr->ai_addr, addr->ai_addrlen, host, sizeof(host), NULL, 0, NI_NUMERICHOST);
        if (strlen(host) <= 0) { continue; }
        NSString *hostStr = [[NSString alloc] initWithUTF8String:host];
        NSLog(@"resolving host %@ loading result: %@", resolvingAddress, hostStr);
        NSData *build = [[NSData alloc] initWithBytes:addr->ai_addr length: addr->ai_addrlen];
        candidateHostData = [candidateHostData arrayByAddingObject:build];
    }
    freeaddrinfo(addrs);
    return candidateHostData;
}

+ (nullable CFSocketRef)connectSocketWith:(id)candidateHostData
                                 withPort:(long)candidatePort
                              withTimeout:(double)candidateTimeout
                            withIpAddress:(NSMutableString*)resolvedAddress
{
    NSString *ipAddress;
    CFDataRef address = NULL;
    SInt32 addressFamily;
    
    if ([candidateHostData length] == sizeof(struct sockaddr_in)) {
        struct sockaddr_in address4;
        [candidateHostData getBytes:&address4 length:sizeof(address4)];
        address4.sin_port = htons(candidatePort);
        char str[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &(address4.sin_addr), str, INET_ADDRSTRLEN);
        ipAddress = [NSString stringWithCString:str encoding:NSUTF8StringEncoding];
        addressFamily = AF_INET;
        address =
        CFDataCreate(kCFAllocatorDefault, (UInt8 *)&address4, sizeof(address4));
    } else if ([candidateHostData length] == sizeof(struct sockaddr_in6)) {
        struct sockaddr_in6 address6;
        [candidateHostData getBytes:&address6 length:sizeof(address6)];
        address6.sin6_port = htons(candidatePort);
        char str[INET6_ADDRSTRLEN];
        inet_ntop(AF_INET6, &(address6.sin6_addr), str, INET6_ADDRSTRLEN);
        ipAddress = [NSString stringWithCString:str encoding:NSUTF8StringEncoding];
        addressFamily = AF_INET6;
        address =
        CFDataCreate(kCFAllocatorDefault, (UInt8 *)&address6, sizeof(address6));
    } else {
        NSLog(@"unrecognized address candidate size");
        return NULL;
    }
    
    [resolvedAddress setString:ipAddress];
    NSLog(@"creating connection to %@", ipAddress);
    
    CFSocketRef constructingSocket = nil;
    constructingSocket =
    CFSocketCreate(kCFAllocatorDefault, addressFamily, SOCK_STREAM,
                   IPPROTO_IP, kCFSocketNoCallBack, NULL, NULL);
    if (!constructingSocket) {
        CFRelease(address);
        return NULL;
    }
    
    int set = 1;
    // Upon successful completion, the value 0 is returned; otherwise the value -1
    // is returned and the global variable errno is set to indicate the error.
    if (setsockopt(CFSocketGetNative(constructingSocket), SOL_SOCKET,
                   SO_NOSIGPIPE, (void *)&set, sizeof(set))) {
        NSLog(@"failed to set socket option");
        CFRelease(address);
        CFSocketInvalidate(constructingSocket);
        CFRelease(constructingSocket);
        return NULL;
    }
    
    CFSocketError error = CFSocketConnectToAddress(constructingSocket, address, candidateTimeout);
    
    CFRelease(address);
    
    if (error) {
        NSLog(@"failed to connect socket with reason %li", error);
        CFSocketInvalidate(constructingSocket);
        CFRelease(constructingSocket);
        return NULL;
    }
    
    return constructingSocket;
}

+ (BOOL)validatePort:(NSNumber*)port {
    int p = [port intValue];
    // we are treating 0 as a valid port and technically it should work!
    if (!(p >= 0 && p <= 65535)) {
        return YES;
    }
    return NO;
}

+ (void)createSocketListnerWithLocalPortV4:(NSNumber*)localPort
             settingV4SocketFileDescriptor:(int*)v4Socket
             settingV6SocketFileDescriptor:(int*)v6Socket
{
    int port = [localPort intValue];
    if (!(port >= 0 && port <= 65535)) {
        NSLog(@"port passed to createSocketListnerWithLocalPortV4 is not valid %d", port);
        return;
    }
    
    *v4Socket = NULL;
    *v6Socket = NULL;
    
    struct sockaddr_in server4;
    struct sockaddr_in6 server6;
    
    int socket_desc4 = socket(AF_INET, SOCK_STREAM, 0);
    int socket_desc6 = socket(AF_INET6, SOCK_STREAM, 0);
    if (socket_desc4 == -1 || socket_desc6 == -1) {
        if (socket_desc4 <= 0) {
            NSLog(@"failed to create socket for ipv4 at port %d", port);
        } else {
            close(socket_desc4);
        }
        if (socket_desc6 <= 0) {
            NSLog(@"failed to create socket for ipv6 at port %d", port);
        } else {
            close(socket_desc6);
        }
        return;
    }
    
    server4.sin_family = AF_INET;
    server4.sin_addr.s_addr = INADDR_ANY;
    server4.sin_port = htons(port);
    server6.sin6_family = AF_INET6;
    server6.sin6_addr = in6addr_any;
    server6.sin6_port = htons(port);
    
#define SHUTDOWN_POSSIBLE_SOCKET do { \
    if (socket_desc4 > 0) { close(socket_desc4); } \
    if (socket_desc6 > 0) { close(socket_desc6); } \
} while (0);
    
    // Upon successful completion, the value 0 is returned; otherwise the value -1 is
    // returned and the global variable errno is set to indicate the error.
    if (setsockopt(socket_desc4, SOL_SOCKET, SO_REUSEPORT, &(int){1}, sizeof(int)) == -1) {
        NSLog(@"failed to setsockopt for ipv4 at port %d", port);
        SHUTDOWN_POSSIBLE_SOCKET
        return;
    }
    if (setsockopt(socket_desc6, SOL_SOCKET, SO_REUSEPORT, &(int){1}, sizeof(int)) == -1) {
        NSLog(@"failed to setsockopt for ipv6 at port %d", port);
        SHUTDOWN_POSSIBLE_SOCKET
        return;
    }
    
    if (bind(socket_desc4, (struct sockaddr*)&server4, sizeof(server4)) < 0) {
        NSLog(@"failed to bind socket for ipv4 at port %d", port);
        SHUTDOWN_POSSIBLE_SOCKET
        return;
    } else {
        NSLog(@"bound listener v4 for port %d", port);
    }
    
    if (bind(socket_desc6, (struct sockaddr*)&server6, sizeof(server6)) < 0) {
        NSLog(@"failed to bind socket for ipv6 at port %d", port);
        SHUTDOWN_POSSIBLE_SOCKET
        return;
    } else {
        NSLog(@"bound listener v6 for port %d", port);
    }
    
    if (fcntl(socket_desc4, F_SETFL, fcntl(socket_desc4, F_GETFL, 0) | O_NONBLOCK) == -1) {
        NSLog(@"failed to call fcntl for none-blocking ipv4 at port %d", port);
        SHUTDOWN_POSSIBLE_SOCKET
        return;
    }
    if (fcntl(socket_desc6, F_SETFL, fcntl(socket_desc6, F_GETFL, 0) | O_NONBLOCK) == -1) {
        NSLog(@"failed to call fcntl for none-blocking ipv6 at port %d", port);
        SHUTDOWN_POSSIBLE_SOCKET
        return;
    }
    
    if (listen(socket_desc4, SOCKET_QUEUE_MAXSIZE) == -1) {
        NSLog(@"failed to call fcntl for none-blocking ipv6 at port %d", port);
        SHUTDOWN_POSSIBLE_SOCKET
        return;
    }
    if (listen(socket_desc6, SOCKET_QUEUE_MAXSIZE) == -1) {
        NSLog(@"failed to call fcntl for none-blocking ipv6 at port %d", port);
        SHUTDOWN_POSSIBLE_SOCKET
        return;
    }
    
    NSLog(@"socket listener for port %d booted", port);
    *v4Socket = socket_desc4;
    *v6Socket = socket_desc6;
}


+ (void)destroyNativeSocket:(int)socketDescriptor {
    if (socketDescriptor > 0) {
        NSLog(@"closing socket fd %d", socketDescriptor);
        close(socketDescriptor);
    }
}

@end
