#import "ForceMobileData.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <netinet/in.h>

static BOOL _forceMobileDataActive = NO;

@implementation ForceMobileData {
    NSString* _eventCallbackId;
}

+ (BOOL)isForceMobileDataActive {
    return _forceMobileDataActive;
}

+ (NSURLSessionConfiguration *)getSessionConfiguration {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    
    if (_forceMobileDataActive) {
        config.allowsCellularAccess = YES;
        config.allowsConstrainedNetworkAccess = YES;
        config.allowsExpensiveNetworkAccess = YES;
        config.multipathServiceType = NSURLSessionMultipathServiceTypeHandover;
        
        // THE TRICK: Tell this session that Wi-Fi proxies are completely restricted.
        // Emptying or manipulating the proxy dictionary forces immediate fallback logic 
        // down to the secondary cellular radio layer.
        config.connectionProxyDictionary = @{}; 
    }
    
    return config;
}

- (void)registerListener:(CDVInvokedUrlCommand*)command {
    _eventCallbackId = command.callbackId;
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendJsonEventToJSWithStatus:(NSString*)status data:(NSString*)data {
    if (_eventCallbackId != nil) {
        NSMutableDictionary* json = [[NSMutableDictionary alloc] init];
        [json setObject:status forKey:@"status"];
        if (data != nil) {
            [json setObject:data forKey:@"data"];
        }
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:json];
        [result setKeepCallbackAsBool:YES];
        [self.commandDelegate sendPluginResult:result callbackId:_eventCallbackId];
    }
}

- (void)enable:(CDVInvokedUrlCommand*)command {
    _forceMobileDataActive = YES;
    [self sendJsonEventToJSWithStatus:@"ONLINE" data:@"MOBILE"];
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Forced Cellular active."];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)disable:(CDVInvokedUrlCommand*)command {
    _forceMobileDataActive = NO;
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Returned to default."];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)checkStatus:(CDVInvokedUrlCommand*)command {
    [self.commandDelegate runInBackground:^{
        NSMutableDictionary* resultJson = [[NSMutableDictionary alloc] init];
        
        struct sockaddr_in zeroAddress;
        bzero(&zeroAddress, sizeof(zeroAddress));
        zeroAddress.sin_len = sizeof(zeroAddress);
        zeroAddress.sin_family = AF_INET;
        
        SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);
        SCNetworkReachabilityFlags flags;
        BOOL gotFlags = SCNetworkReachabilityGetFlags(reachability, &flags);
        CFRelease(reachability);
        
        BOOL isReachable = gotFlags && (flags & kSCNetworkReachabilityFlagsReachable);
        BOOL isConnectionRequired = flags & kSCNetworkReachabilityFlagsConnectionRequired;
        
        if (!isReachable || isConnectionRequired) {
            [resultJson setObject:@"OFFLINE" forKey:@"status"];
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:resultJson] callbackId:command.callbackId];
            return;
        }
        
        BOOL isWifi = gotFlags && !(flags & kSCNetworkReachabilityFlagsIsWWAN);
        BOOL isMobile = gotFlags && (flags & kSCNetworkReachabilityFlagsIsWWAN);
        BOOL hasInternet = [self testInternetConnectivity];
        
        if (hasInternet) {
            [resultJson setObject:@"ONLINE" forKey:@"status"];
            [resultJson setObject:(isWifi ? @"WIFI" : @"MOBILE") forKey:@"data"];
        } else {
            if (isWifi) {
                [resultJson setObject:@"ONLINE_WIFI_DEAD" forKey:@"status"];
                [resultJson setObject:@"WIFI" forKey:@"data"];
            } else {
                [resultJson setObject:@"OFFLINE" forKey:@"status"];
            }
        }
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:resultJson] callbackId:command.callbackId];
    }];
}

- (BOOL)testInternetConnectivity {
    __block BOOL success = NO;
    NSURL *url = [NSURL URLWithString:@"https://connectivitycheck.gstatic.com/generate_204"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:3.0];
    [request setHTTPMethod:@"HEAD"];
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error == nil && ((NSHTTPURLResponse *)response).statusCode == 204) {
            success = YES;
        }
        dispatch_semaphore_signal(semaphore);
    }] resume];
    
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)));
    return success;
}

@end
