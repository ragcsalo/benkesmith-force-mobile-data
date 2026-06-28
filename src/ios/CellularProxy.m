#import "CellularProxy.h"
#import <Network/Network.h>

static nw_listener_t  sListener  = nil;
static NSInteger      sPort      = 0;
static BOOL           sRunning   = NO;
static dispatch_queue_t sQueue   = nil;

// ─────────────────────────────────────────────────────────────────────────────

@implementation CellularProxy

#pragma mark - Lifecycle

+ (void)startWithCompletion:(void (^)(BOOL success))completion {
    if (sRunning) {
        if (completion) completion(YES);
        return;
    }

    if (!sQueue) {
        sQueue = dispatch_queue_create("com.forcemobiledata.proxy", DISPATCH_QUEUE_SERIAL);
    }

    // Plain TCP, no TLS on the listener itself (proxy is loopback-local only)
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION
    );

    sListener = nw_listener_create(params);
    nw_listener_set_queue(sListener, sQueue);

    // ── Handle incoming connections from NSURLSession ──
    nw_listener_set_new_connection_handler(sListener, ^(nw_connection_t clientConn) {
        [CellularProxy handleClientConnection:clientConn];
    });

    // ── Track listener state ──
    nw_listener_set_state_changed_handler(sListener,
    ^(nw_listener_state_t state, nw_error_t error) {
        if (state == nw_listener_state_ready) {
            sPort    = (NSInteger)nw_listener_get_port(sListener);
            sRunning = YES;
            NSLog(@"[CellularProxy] Listening on 127.0.0.1:%ld", (long)sPort);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(YES);
            });
        } else if (state == nw_listener_state_failed) {
            NSLog(@"[CellularProxy] Listener failed: %@", error);
            sRunning = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO);
            });
        } else if (state == nw_listener_state_cancelled) {
            sRunning = NO;
            sPort    = 0;
        }
    });

    nw_listener_start(sListener);
}

+ (void)stop {
    if (sListener) {
        nw_listener_cancel(sListener);
        sListener = nil;
    }
    sRunning = NO;
    sPort    = 0;
}

+ (NSInteger)port    { return sPort; }
+ (BOOL)isRunning    { return sRunning; }

#pragma mark - Connection handling

/// Called for every new TCP connection that NSURLSession opens to our proxy.
+ (void)handleClientConnection:(nw_connection_t)clientConn {
    nw_connection_set_queue(clientConn, sQueue);
    nw_connection_start(clientConn);

    // Read the opening HTTP verb (CONNECT for HTTPS, or GET/POST/etc for HTTP)
    nw_connection_receive(clientConn, 1, 8192,
    ^(dispatch_data_t content, nw_content_context_t ctx, bool is_complete, nw_error_t error) {
        if (!content) {
            nw_connection_cancel(clientConn);
            return;
        }

        // Collect received bytes
        NSMutableData *requestData = [NSMutableData data];
        dispatch_data_apply(content, ^bool(dispatch_data_t r, size_t off, const void *buf, size_t sz) {
            [requestData appendBytes:buf length:sz];
            return true;
        });

        NSString *requestStr = [[NSString alloc] initWithData:requestData
                                                     encoding:NSUTF8StringEncoding];
        if (!requestStr) {
            nw_connection_cancel(clientConn);
            return;
        }

        // First line: "CONNECT host:port HTTP/1.1"  OR  "GET http://host/path HTTP/1.1"
        NSString *firstLine = [[requestStr componentsSeparatedByString:@"\r\n"] firstObject] ?: @"";
        NSArray<NSString *> *parts = [firstLine componentsSeparatedByString:@" "];
        if (parts.count < 2) {
            nw_connection_cancel(clientConn);
            return;
        }

        NSString *method  = parts[0];
        NSString *target  = parts[1]; // "host:port" for CONNECT, full URL for HTTP

        if ([method isEqualToString:@"CONNECT"]) {
            // ── HTTPS tunnel ──
            // target = "api.example.com:443"
            NSArray<NSString *> *hp = [target componentsSeparatedByString:@":"];
            NSString *host = hp.firstObject ?: @"";
            NSString *port = (hp.count > 1) ? hp.lastObject : @"443";
            [CellularProxy openTunnelFromClient:clientConn
                                           host:host
                                           port:port
                                     httpForward:nil];
        } else {
            // ── Plain HTTP request ──
            // Extract Host header for the real server address
            NSString *host = nil;
            NSString *port = @"80";
            NSArray<NSString *> *lines = [requestStr componentsSeparatedByString:@"\r\n"];
            for (NSString *line in lines) {
                if ([line.lowercaseString hasPrefix:@"host:"]) {
                    NSString *hostVal = [[line substringFromIndex:5]
                                        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    NSArray<NSString *> *hp = [hostVal componentsSeparatedByString:@":"];
                    host = hp.firstObject;
                    if (hp.count > 1) port = hp.lastObject;
                    break;
                }
            }
            if (!host) {
                nw_connection_cancel(clientConn);
                return;
            }
            // Forward the original request bytes (including method/headers/body)
            // straight to the server over cellular
            [CellularProxy openTunnelFromClient:clientConn
                                           host:host
                                           port:port
                                     httpForward:requestData];
        }
    });
}

#pragma mark - Tunnel establishment

/// Opens a cellular NWConnection to host:port and wires up bidirectional piping.
/// For CONNECT (HTTPS): sends "200 Connection Established" first, then pipes.
/// For plain HTTP: forwards the original requestData immediately, then pipes.
+ (void)openTunnelFromClient:(nw_connection_t)clientConn
                        host:(NSString *)host
                        port:(NSString *)port
                 httpForward:(nullable NSData *)httpForward {

    // TCP-only, locked to cellular — the proxy NEVER does TLS itself.
    // For HTTPS, NSURLSession does TLS end-to-end through our transparent pipe.
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,        // no TLS in proxy
        NW_PARAMETERS_DEFAULT_CONFIGURATION    // TCP
    );
    nw_parameters_set_required_interface_type(params, nw_interface_type_cellular);

    nw_endpoint_t   endpoint   = nw_endpoint_create_host([host UTF8String], [port UTF8String]);
    nw_connection_t serverConn = nw_connection_create(endpoint, params);
    nw_connection_set_queue(serverConn, sQueue);

    nw_connection_set_state_changed_handler(serverConn,
    ^(nw_connection_state_t state, nw_error_t err) {
        if (state == nw_connection_state_ready) {
            NSLog(@"[CellularProxy] Cellular tunnel open to %@:%@", host, port);

            if (!httpForward) {
                // HTTPS CONNECT: tell NSURLSession the tunnel is ready
                NSString *ok       = @"HTTP/1.1 200 Connection Established\r\n\r\n";
                NSData   *okData   = [ok dataUsingEncoding:NSUTF8StringEncoding];
                dispatch_data_t dd = dispatch_data_create(okData.bytes, okData.length,
                                                          nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                nw_connection_send(clientConn, dd, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false,
                ^(nw_error_t sendErr) {
                    if (!sendErr) {
                        // Start transparent bidirectional pipe
                        [CellularProxy pipe:clientConn to:serverConn];
                        [CellularProxy pipe:serverConn to:clientConn];
                    } else {
                        nw_connection_cancel(serverConn);
                        nw_connection_cancel(clientConn);
                    }
                });
            } else {
                // Plain HTTP: forward the buffered request bytes to the server
                dispatch_data_t dd = dispatch_data_create(httpForward.bytes, httpForward.length,
                                                          nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                nw_connection_send(serverConn, dd, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false,
                ^(nw_error_t sendErr) {
                    if (!sendErr) {
                        [CellularProxy pipe:clientConn to:serverConn];
                        [CellularProxy pipe:serverConn to:clientConn];
                    } else {
                        nw_connection_cancel(serverConn);
                        nw_connection_cancel(clientConn);
                    }
                });
            }

        } else if (state == nw_connection_state_failed) {
            NSLog(@"[CellularProxy] Cellular connection to %@:%@ failed", host, port);
            // Tell NSURLSession the tunnel failed
            if (!httpForward) {
                NSString *fail   = @"HTTP/1.1 502 Bad Gateway\r\n\r\n";
                NSData   *fd     = [fail dataUsingEncoding:NSUTF8StringEncoding];
                dispatch_data_t dd = dispatch_data_create(fd.bytes, fd.length,
                                                          nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                nw_connection_send(clientConn, dd, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                ^(nw_error_t e) { nw_connection_cancel(clientConn); });
            } else {
                nw_connection_cancel(clientConn);
            }
        }
    });

    nw_connection_start(serverConn);
}

#pragma mark - Bidirectional pipe

/// Reads all data from `from` and writes it to `to`, recursively, until either
/// side closes or errors. This is the transparent tunnel core.
+ (void)pipe:(nw_connection_t)from to:(nw_connection_t)to {
    nw_connection_receive(from, 1, UINT32_MAX,
    ^(dispatch_data_t content, nw_content_context_t ctx, bool is_complete, nw_error_t error) {

        if (content) {
            // Forward the chunk. `is_complete` signals EOF from source.
            nw_connection_send(to, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, is_complete,
            ^(nw_error_t sendErr) {
                if (!sendErr && !is_complete) {
                    // Source has more data — keep piping
                    [CellularProxy pipe:from to:to];
                }
                // On sendErr or is_complete we stop; the other direction's
                // receive will eventually notice the close and stop itself.
            });
        }

        if (!content || is_complete || error) {
            // Source closed or errored with nothing to forward
            if (!content || error) {
                nw_connection_cancel(to);
                nw_connection_cancel(from);
            }
        }
    });
}

@end
