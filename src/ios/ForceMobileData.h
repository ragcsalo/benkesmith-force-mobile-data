#import <Cordova/CDV.h>

@interface ForceMobileData : CDVPlugin

// Static flag accessible anywhere in the native app binary
+ (BOOL)isForceMobileDataActive;

// Configuration builder helper for native HTTP clients
+ (NSURLSessionConfiguration *)getSessionConfiguration;

// Cordova-facing execution commands
- (void)enable:(CDVInvokedUrlCommand*)command;
- (void)disable:(CDVInvokedUrlCommand*)command;

@end

