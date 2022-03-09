//
//  GenericNetworking.h
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

#import <Foundation/Foundation.h>

#import "GenericHeaders.h"

NS_ASSUME_NONNULL_BEGIN

@interface GenericNetworking : NSObject

+ (NSArray *)resolveIpAddressesFor:(NSString*)candidateHost;

+ (nullable CFSocketRef)connectSocketWith:(id)candidateHostData
                                 withPort:(long)candidatePort
                              withTimeout:(double)candidateTimeout
                            withIpAddress:(NSMutableString*)resolvedAddress;

+ (BOOL)validatePort:(NSNumber*)port;

+ (void)createSocketListnerWithLocalPortV4:(NSNumber*)localPort
             settingV4SocketFileDescriptor:(int*)v4Socket
             settingV6SocketFileDescriptor:(int*)v6Socket;

+ (void)destroyNativeSocket:(int)socketDescriptor;

@end

NS_ASSUME_NONNULL_END
