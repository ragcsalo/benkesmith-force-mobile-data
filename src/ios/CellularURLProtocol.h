#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * CellularURLProtocol — an NSURLProtocol subclass that transparently
 * routes all http/https requests over the cellular (mobile data) interface
 * using Network.framework's NWConnection.
 *
 * How it hooks into cordova-plugin-advanced-http:
 *   CordovaHttpPlugin.m creates an NSURLSessionConfiguration whose
 *   protocolClasses list is prepended with this class when cellular
 *   forcing is active. The SM_AFHTTPSessionManager then routes all
 *   its requests through this protocol, bypassing the WiFi interface.
 *
 * Limitations:
 *   - SSL certificate pinning configured in cordova-plugin-advanced-http
 *     is bypassed (TLS is handled by NWConnection using the system trust store).
 *   - File uploads/downloads use in-memory body buffering; very large files
 *     (>50 MB) may cause memory pressure.
 *   - Requires iOS 12+ (Network.framework).
 */
@interface CellularURLProtocol : NSURLProtocol

/// Enable cellular-forced routing. Call this when ForceMobileData.enable
/// successfully confirms cellular internet is available.
+ (void)setEnabled:(BOOL)enabled;

/// Returns whether cellular-forced routing is currently active.
+ (BOOL)isEnabled;

@end

NS_ASSUME_NONNULL_END
