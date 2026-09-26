#import "ForceMobileData.h"
#import "CellularProxy.h"             // <-- replaces CellularURLProtocol
#import <SystemConfiguration/SystemConfiguration.h>
#import <Network/Network.h>
#import <netinet/in.h>

static BOOL _forceMobileDataActive = NO;

// Mirrors the Android-side ForceMobileData.java constants - kept in sync so both platforms
// behave the same: longer per-probe timeout, retry before declaring a network dead, and a
// real recurring poll (instead of a one-shot check) while cellular is forced.
// Tuned down from 5.0/5.5/1.0 (see ForceMobileData.java's matching comment): those values
// pushed the worst case for the very first, app-startup checkStatus() call - the one the
// "Network: checking..." home-screen label waits on - to over 10s. 2 attempts still guards
// against a one-off transient blip, just with a snappier ceiling.
static const NSTimeInterval kProbeTimeoutSec        = 3.0;
static const NSTimeInterval kProbeWaitSec           = 3.5;
static const NSInteger      kProbeAttempts          = 2;
static const NSTimeInterval kProbeRetryDelaySec     = 0.4;
static const NSTimeInterval kRecoveryPollIntervalSec = 5.0;
// On mobile data only (checkStatus, default route = cellular): one longer probe instead of two short
// ones - a sleeping cellular radio needs a moment to come up, and 3 s often wasn't enough, so a
// perfectly working mobile connection was reported OFFLINE. (The JS side also waits for two OFFLINE
// answers in a row before showing "no internet".)
static const NSTimeInterval kProbeTimeoutCellularSec = 6.0;
static const NSTimeInterval kProbeWaitCellularSec    = 6.5;

static dispatch_queue_t sRecoveryQueue      = nil;
static BOOL             sRecoveryScheduled  = NO;

@interface ForceMobileData ()
- (void)scheduleRecoveryCheck;
- (void)runRecoveryCheck;
- (BOOL)probeInternetConnectivity;
- (BOOL)probeInternetConnectivityWithTimeout:(NSTimeInterval)timeout wait:(NSTimeInterval)wait;
- (BOOL)probeInternetConnectivityForcingCellular;
@end

@implementation ForceMobileData {
    NSString* _eventCallbackId;
}

+ (BOOL)isForceMobileDataActive {
    return _forceMobileDataActive;
}

+ (NSURLSessionConfiguration *)getSessionConfiguration {
    return [NSURLSessionConfiguration defaultSessionConfiguration];
}

// One shared session for the default-route probes: it keeps the connection to the check server
// warm between the 5 s checks (no new DNS + TCP + TLS every time - slow on mobile data), and doesn't
// leak a session per probe (sessions made with sessionWithConfiguration: were never invalidated).
+ (NSURLSession *)probeSession {
    static NSURLSession *session = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        config.URLCache = nil;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
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
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                               messageAsDictionary:json];
        [result setKeepCallbackAsBool:YES];
        [self.commandDelegate sendPluginResult:result callbackId:_eventCallbackId];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// enable
// 1. Confirms cellular internet is actually reachable (NWConnection probe).
// 2. Starts the local CellularProxy on a random loopback port.
// 3. Only sends success to JS once the proxy is listening — so that
//    cordova-plugin-advanced-http's createManager() will find a live port.
// ─────────────────────────────────────────────────────────────────────────────
- (void)enable:(CDVInvokedUrlCommand*)command {
    [self.commandDelegate runInBackground:^{

        BOOL cellularAvailable = [self testInternetConnectivityForcingCellular];
        if (!cellularAvailable) {
            CDVPluginResult* result = [CDVPluginResult
                resultWithStatus:CDVCommandStatus_ERROR
                 messageAsString:@"Cellular not available or unreachable."];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }

        // Start proxy; completion fires on main queue once port is assigned.
        [CellularProxy startWithCompletion:^(BOOL proxyStarted) {
            if (!proxyStarted) {
                CDVPluginResult* result = [CDVPluginResult
                    resultWithStatus:CDVCommandStatus_ERROR
                     messageAsString:@"Failed to start cellular proxy."];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                return;
            }

            _forceMobileDataActive = YES;
            [self sendJsonEventToJSWithStatus:@"ONLINE" data:@"MOBILE"];
            [self scheduleRecoveryCheck];

            CDVPluginResult* result = [CDVPluginResult
                resultWithStatus:CDVCommandStatus_OK
                 messageAsString:@"Cellular proxy active. "
                                  "HTTP plugin calls now routed over mobile data."];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }];
    }];
}

// ─────────────────────────────────────────────────────────────────────────────
// disable
// ─────────────────────────────────────────────────────────────────────────────
- (void)disable:(CDVInvokedUrlCommand*)command {
    _forceMobileDataActive = NO;
    sRecoveryScheduled = NO;
    [CellularProxy stop];

    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                     messageAsString:@"Returned to default."];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

// ─────────────────────────────────────────────────────────────────────────────
// Recovery polling
// Actively re-probes both interfaces every kRecoveryPollIntervalSec while cellular is
// forced, instead of relying on any one-shot reachability callback - iOS gives no
// equivalent of Android's ConnectivityManager.NetworkCallback.onAvailable for "this
// already-connected Wi-Fi network's internet just came back", so this has to poll.
// Wi-Fi is always preferred back as soon as it's healthy. Mirrors the Android-side
// startWifiInternetMonitor() in ForceMobileData.java.
// ─────────────────────────────────────────────────────────────────────────────
- (void)scheduleRecoveryCheck {
    if (sRecoveryScheduled) return;
    sRecoveryScheduled = YES;

    if (!sRecoveryQueue) {
        sRecoveryQueue = dispatch_queue_create("com.fmd.recovery.poll", DISPATCH_QUEUE_SERIAL);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRecoveryPollIntervalSec * NSEC_PER_SEC)),
                    sRecoveryQueue, ^{
        [self runRecoveryCheck];
    });
}

- (void)runRecoveryCheck {
    if (!_forceMobileDataActive) {
        sRecoveryScheduled = NO;
        return;
    }

    // Prefer Wi-Fi: the default-route probe goes over Wi-Fi whenever iOS still considers
    // it the primary interface, which stays true even while our proxy is forcing plugin
    // HTTP calls over cellular.
    if ([self testInternetConnectivity]) {
        NSLog(@"[ForceMobileData] Wi-Fi internet recovered, reverting from forced cellular.");
        _forceMobileDataActive = NO;
        sRecoveryScheduled = NO;
        [CellularProxy stop];
        [self sendJsonEventToJSWithStatus:@"ONLINE" data:@"WIFI"];
        return;
    }

    if (![self testInternetConnectivityForcingCellular]) {
        NSLog(@"[ForceMobileData] Forced cellular route has no working internet either.");
        [self sendJsonEventToJSWithStatus:@"OFFLINE" data:nil];
    }

    if (_forceMobileDataActive) {
        sRecoveryScheduled = NO;
        [self scheduleRecoveryCheck];
    } else {
        sRecoveryScheduled = NO;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// checkStatus
// ─────────────────────────────────────────────────────────────────────────────
- (void)checkStatus:(CDVInvokedUrlCommand*)command {
    [self.commandDelegate runInBackground:^{
        NSMutableDictionary* resultJson = [[NSMutableDictionary alloc] init];

        // the interface first: it decides how to probe (and no probe at all when nothing is up)
        struct sockaddr_in zeroAddress;
        bzero(&zeroAddress, sizeof(zeroAddress));
        zeroAddress.sin_len = sizeof(zeroAddress);
        zeroAddress.sin_family = AF_INET;

        SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(
            kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);
        SCNetworkReachabilityFlags flags = 0;
        BOOL gotFlags = SCNetworkReachabilityGetFlags(reachability, &flags);
        CFRelease(reachability);

        BOOL isReachable     = gotFlags && (flags & kSCNetworkReachabilityFlagsReachable);
        BOOL needsConnection = gotFlags && (flags & kSCNetworkReachabilityFlagsConnectionRequired);
        BOOL isWWAN          = gotFlags && (flags & kSCNetworkReachabilityFlagsIsWWAN);
        BOOL looksLikeWifi   = isReachable && !needsConnection && !isWWAN;

        // Nothing reachable (airplane mode, no Wi-Fi and no mobile data): no need to wait for a probe.
        // NOTE: "connection required" alone is NOT offline - on mobile data it is set while the radio
        // is idle (the connection comes up on the first traffic; Apple's Reachability sample treats
        // WWAN as reachable then). Treating it as OFFLINE flagged a working mobile connection.
        BOOL hasInternet = NO;
        if (isReachable) {
            if (isWWAN) {
                hasInternet = [self probeInternetConnectivityWithTimeout:kProbeTimeoutCellularSec wait:kProbeWaitCellularSec];
            } else {
                hasInternet = [self testInternetConnectivity];
            }
        }

        if (hasInternet) {
            // the probe got through - that's what counts, whatever the flags say
            [resultJson setObject:@"ONLINE" forKey:@"status"];
            [resultJson setObject:(isWWAN ? @"MOBILE" : @"WIFI") forKey:@"data"];
        } else if (looksLikeWifi) {
            [resultJson setObject:@"ONLINE_WIFI_DEAD" forKey:@"status"];
            [resultJson setObject:@"WIFI" forKey:@"data"];
        } else {
            [resultJson setObject:@"OFFLINE" forKey:@"status"];
        }
        NSLog(@"[ForceMobileData] checkStatus: reachable=%d connectionRequired=%d wwan=%d internet=%d -> %@",
              isReachable, needsConnection, isWWAN, hasInternet, resultJson[@"status"]);

        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                messageAsDictionary:resultJson];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

// Retries a couple of times before concluding the default route's internet is actually
// dead - a single timed-out or blipped probe otherwise flips the UI on a purely transient
// hiccup (matches Android's isInternetWorking()).
- (BOOL)testInternetConnectivity {
    for (NSInteger attempt = 1; attempt <= kProbeAttempts; attempt++) {
        if ([self probeInternetConnectivity]) {
            return YES;
        }
        if (attempt < kProbeAttempts) {
            [NSThread sleepForTimeInterval:kProbeRetryDelaySec];
        }
    }
    return NO;
}

// Tests internet via the OS default route (goes over WiFi if WiFi is connected).
- (BOOL)probeInternetConnectivity {
    return [self probeInternetConnectivityWithTimeout:kProbeTimeoutSec wait:kProbeWaitSec];
}

- (BOOL)probeInternetConnectivityWithTimeout:(NSTimeInterval)timeout wait:(NSTimeInterval)wait {
    __block BOOL success = NO;
    NSURL *url = [NSURL URLWithString:@"https://connectivitycheck.gstatic.com/generate_204"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:timeout];
    [request setHTTPMethod:@"HEAD"];

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[ForceMobileData probeSession] dataTaskWithRequest:request
                                                                   completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e == nil && [r isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)r).statusCode == 204) {
            success = YES;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];

    long timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)));
    if (timedOut != 0) {
        [task cancel];   // don't leave it running on the shared session
    }
    return success;
}

// Retries a couple of times before concluding cellular itself has no working internet.
- (BOOL)testInternetConnectivityForcingCellular {
    for (NSInteger attempt = 1; attempt <= kProbeAttempts; attempt++) {
        if ([self probeInternetConnectivityForcingCellular]) {
            return YES;
        }
        if (attempt < kProbeAttempts) {
            [NSThread sleepForTimeInterval:kProbeRetryDelaySec];
        }
    }
    return NO;
}

// Tests internet specifically over the cellular radio via NWConnection,
// bypassing WiFi even when WiFi is connected. Requires iOS 12+.
- (BOOL)probeInternetConnectivityForcingCellular {
    __block BOOL success  = NO;
    __block BOOL signaled = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DEFAULT_CONFIGURATION,
        NW_PARAMETERS_DEFAULT_CONFIGURATION
    );
    nw_parameters_set_required_interface_type(params, nw_interface_type_cellular);

    nw_endpoint_t   endpoint = nw_endpoint_create_host("connectivitycheck.gstatic.com", "443");
    nw_connection_t conn     = nw_connection_create(endpoint, params);

    dispatch_queue_t q = dispatch_queue_create("com.fmd.cellular.probe", DISPATCH_QUEUE_SERIAL);
    nw_connection_set_queue(conn, q);

    nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state, nw_error_t err) {
        if (state == nw_connection_state_ready) {
            success = YES;
            nw_connection_cancel(conn);
            if (!signaled) { signaled = YES; dispatch_semaphore_signal(semaphore); }
        } else if (state == nw_connection_state_failed ||
                   state == nw_connection_state_cancelled) {
            if (!signaled) { signaled = YES; dispatch_semaphore_signal(semaphore); }
        }
    });

    nw_connection_start(conn);
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kProbeWaitSec * NSEC_PER_SEC)));
    return success;
}

@end
