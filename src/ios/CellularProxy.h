#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * CellularProxy — a lightweight local TCP proxy that routes all traffic
 * through the cellular (mobile data) interface using NWConnection.
 *
 * How it works:
 *   1. Starts an nw_listener_t on 127.0.0.1 on a random port.
 *   2. ForceMobileData tells CordovaHttpPlugin to set connectionProxyDictionary
 *      on its NSURLSessionConfiguration to point at 127.0.0.1:PORT.
 *   3. NSURLSession sends a CONNECT tunnel request to the proxy for every
 *      HTTPS call (and regular HTTP request for HTTP calls).
 *   4. The proxy opens an NWConnection locked to nw_interface_type_cellular
 *      to the real target and pipes raw bytes bidirectionally.
 *   5. Because the tunnel is transparent, NSURLSession handles TLS end-to-end —
 *      so SSL pinning and certificate validation still work normally.
 *
 * Requires iOS 12+ (Network.framework).
 */
@interface CellularProxy : NSObject

/// Start the proxy listener. Calls completion on the main queue when ready
/// (with the assigned port) or on failure.
+ (void)startWithCompletion:(void (^)(BOOL success))completion;

/// Stop the proxy and cancel all active tunnels.
+ (void)stop;

/// Port the proxy is listening on (valid only after a successful start).
+ (NSInteger)port;

/// Whether the proxy is currently running.
+ (BOOL)isRunning;

@end

NS_ASSUME_NONNULL_END
