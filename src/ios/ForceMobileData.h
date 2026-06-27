#import <Cordova/CDV.h>

@interface ForceMobileData : CDVPlugin

// Static flag accessible anywhere in the native app binary to configure your HTTP engine
+ (BOOL)isForceMobileDataActive;

// Configuration builder helper for native HTTP clients
+ (NSURLSessionConfiguration *)getSessionConfiguration;

// Cordova-facing execution commands
- (void)enable:(CDVInvokedUrlCommand*)command;
- (void)disable:(CDVInvokedUrlCommand*)command;
- (void)registerListener:(CDVInvokedUrlCommand*)command;
- (void)checkStatus:(CDVInvokedUrlCommand*)command;

@end

