#import "ForceMobileData.h"

static BOOL _forceMobileDataActive = NO;

@implementation ForceMobileData

+ (BOOL)isForceMobileDataActive {
    return _forceMobileDataActive;
}

+ (NSURLSessionConfiguration *)getSessionConfiguration {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    
    if (_forceMobileDataActive) {
        // Explicitly allow and prioritize mobile data
        config.allowsCellularAccess = YES;
        config.allowsConstrainedNetworkAccess = YES;
        config.allowsExpensiveNetworkAccess = YES;
        
        // Handover mode tells iOS to actively drop failing interfaces (like dead Wi-Fi)
        config.multipathServiceType = NSURLSessionMultipathServiceTypeHandover;
    }
    
    return config;
}

- (void)enable:(CDVInvokedUrlCommand*)command {
    _forceMobileDataActive = YES;
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK 
                                                      messageAsString:@"iOS requests marked to prioritize Cellular Data over Wi-Fi."];
    
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)disable:(CDVInvokedUrlCommand*)command {
    _forceMobileDataActive = NO;
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK 
                                                      messageAsString:@"iOS requests returned to OS routing defaults."];
    
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

@end