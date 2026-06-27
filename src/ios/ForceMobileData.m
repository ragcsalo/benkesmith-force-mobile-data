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
        // Explicitly allow and prioritize mobile data
        config.allowsCellularAccess = YES;
        config.allowsConstrainedNetworkAccess = YES;
        config.allowsExpensiveNetworkAccess = YES;
        
        // Handover mode tells iOS to actively drop failing interfaces (like dead Wi-Fi)
        config.multipathServiceType = NSURLSessionMultipathServiceTypeHandover;
    }
    
    return config;
}

- (void)registerListener:(CDVInvokedUrlCommand*)command {
    // Keep a persistent channel open to send events to JS layer
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
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK 
                                                      messageAsString:@"iOS requests marked to prioritize Cellular Data over Wi-Fi."];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)disable:(CDVInvokedUrlCommand*)command {
    _forceMobileDataActive = _forceMobileDataActive = NO;
    
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK 
                                                      messageAsString:@"iOS requests returned to OS routing defaults."];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)checkStatus:(CDVInvokedUrlCommand*)command {
    [self.commandDelegate runInBackground:^{
        NSMutableDictionary* resultJson = [[NSMutableDictionary alloc] init];
        
        // 1. Get Reachability Flags to evaluate physical hardware states
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
        BOOL hasNetworkHardware = isReachable && !isConnectionRequired;
        
        if (!hasNetworkHardware) {
            [resultJson setObject:@"OFFLINE" forKey:@"status"];
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:resultJson];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            return;
        }
        
        BOOL isWifiHardwareConnected = gotFlags && !(flags & kSCNetworkReachabilityFlagsIsWWAN);
        BOOL isCellularHardwareConnected = gotFlags && (flags & kSCNetworkReachabilityFlagsIsWWAN);
        
        // 2. Perform a low-level diagnostic check to see if the interface has an internet connection
        BOOL hasInternet = [self testInternetConnectivity];
        
        if (hasInternet) {
            [resultJson setObject:@"ONLINE" forKey:@"status"];
            if (isWifiHardwareConnected) {
                [resultJson setObject:@"WIFI" forKey:@"data"];
            } else if (isCellularHardwareConnected) {
                [resultJson setObject:@"MOBILE" forKey:@"data"];
            } else {
                [resultJson setObject:@"UNKNOWN" forKey:@"data"];
            }
        } else {
            // Internet test failed. Check if we're connected to a dead Wi-Fi network.
            if (isWifiHardwareConnected) {
                [resultJson setObject:@"ONLINE_WIFI_DEAD" forKey:@"status"];
                [resultJson setObject:@"WIFI" forKey:@"data"];
            } else {
                [resultJson setObject:@"OFFLINE" forKey:@"status"];
            }
        }
        
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:resultJson];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    } e];
}

- (BOOL)testInternetConnectivity {
    __block BOOL success = NO;
    
    // Create an explicit network validation session
    NSURL *url = [NSURL URLWithString:@"https://connectivitycheck.gstatic.com/generate_204"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:3.0];
    [request setHTTPMethod:@"HEAD"];
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    // Use default baseline configurations (do not lock to mobile data during evaluation check)
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error == nil && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if ([httpResponse statusCode] == 204 || [httpResponse statusCode] == 200) {
                success = YES;
            }
        }
        dispatch_semaphore_signal(semaphore);
    }];
    
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)));
    
    return success;
}

@end
