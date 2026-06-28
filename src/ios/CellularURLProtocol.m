#import "CellularURLProtocol.h"
#import <Network/Network.h>

// Static flag controlled by ForceMobileData.enable / .disable
static BOOL sCellularEnabled = NO;

// Tag applied to requests we've already claimed, preventing infinite re-interception
static NSString *const kHandledKey = @"CellularURLProtocol_Handled";

// ---------------------------------------------------------------------------

@interface CellularURLProtocol ()
@property (nonatomic, nullable) nw_connection_t  nwConnection;
@property (nonatomic)           NSMutableData    *receivedData;
@property (nonatomic)           dispatch_queue_t  queue;
@end

// ---------------------------------------------------------------------------

@implementation CellularURLProtocol

#pragma mark - Public API

+ (void)setEnabled:(BOOL)enabled {
    sCellularEnabled = enabled;
}

+ (BOOL)isEnabled {
    return sCellularEnabled;
}

#pragma mark - NSURLProtocol registration hooks

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // Don't intercept if cellular forcing is off
    if (!sCellularEnabled) return NO;
    // Don't re-intercept our own re-issued requests (breaks infinite loops)
    if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request]) return NO;
    // Only handle http and https schemes
    NSString *scheme = request.URL.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return NO; // We never cache
}

#pragma mark - Loading lifecycle

- (void)startLoading {
    NSURL     *url  = self.request.URL;
    NSString  *host = url.host;

    if (!host || host.length == 0) {
        [self failWithCode:NSURLErrorBadURL];
        return;
    }

    BOOL isHTTPS = [url.scheme.lowercaseString isEqualToString:@"https"];
    int  port    = url.port ? url.port.intValue : (isHTTPS ? 443 : 80);

    // ── NWParameters: TLS for https, plain TCP for http, BOTH forced to cellular ──
    nw_parameters_t params;
    if (isHTTPS) {
        params = nw_parameters_create_secure_tcp(
            NW_PARAMETERS_DEFAULT_CONFIGURATION,   // TLS on
            NW_PARAMETERS_DEFAULT_CONFIGURATION    // TCP
        );
    } else {
        params = nw_parameters_create_secure_tcp(
            NW_PARAMETERS_DISABLE_PROTOCOL,        // TLS off
            NW_PARAMETERS_DEFAULT_CONFIGURATION    // TCP
        );
    }

    // THE KEY LINE: locks this connection to the cellular radio only
    nw_parameters_set_required_interface_type(params, nw_interface_type_cellular);

    nw_endpoint_t endpoint = nw_endpoint_create_host(
        [host UTF8String],
        [[NSString stringWithFormat:@"%d", port] UTF8String]
    );

    self.receivedData = [NSMutableData data];
    self.queue        = dispatch_queue_create("com.forcemobiledata.cellularprotocol",
                                              DISPATCH_QUEUE_SERIAL);
    self.nwConnection = nw_connection_create(endpoint, params);

    __weak typeof(self) weakSelf = self;

    nw_connection_set_queue(self.nwConnection, self.queue);

    nw_connection_set_state_changed_handler(self.nwConnection,
    ^(nw_connection_state_t state, nw_error_t err) {
        switch (state) {
            case nw_connection_state_ready:
                // Connection established over cellular — send the HTTP request
                [weakSelf sendHTTPRequest];
                break;
            case nw_connection_state_failed:
                [weakSelf failWithCode:NSURLErrorNotConnectedToInternet];
                break;
            case nw_connection_state_cancelled:
                // Normal teardown, nothing to do
                break;
            default:
                break;
        }
    });

    nw_connection_start(self.nwConnection);
}

- (void)stopLoading {
    if (self.nwConnection) {
        nw_connection_cancel(self.nwConnection);
        self.nwConnection = nil;
    }
}

#pragma mark - Build and send raw HTTP request

- (void)sendHTTPRequest {
    NSURL    *url    = self.request.URL;
    NSString *method = self.request.HTTPMethod ?: @"GET";

    // ── Path + query string ──
    NSString *path = (url.path.length > 0) ? url.path : @"/";
    if (url.query.length > 0) {
        path = [NSString stringWithFormat:@"%@?%@", path, url.query];
    }

    // ── Request body: prefer HTTPBody, fall back to HTTPBodyStream ──
    NSData *body = self.request.HTTPBody;
    if (!body && self.request.HTTPBodyStream) {
        NSInputStream    *stream    = self.request.HTTPBodyStream;
        NSMutableData    *streamed  = [NSMutableData data];
        uint8_t           buf[4096];
        NSInteger         read;
        [stream open];
        while ((read = [stream read:buf maxLength:sizeof(buf)]) > 0) {
            [streamed appendBytes:buf length:(NSUInteger)read];
        }
        [stream close];
        body = streamed;
    }

    // ── Build HTTP/1.1 request header block ──
    NSMutableString *hdrs = [NSMutableString string];
    [hdrs appendFormat:@"%@ %@ HTTP/1.1\r\n", method, path];
    [hdrs appendFormat:@"Host: %@\r\n",        url.host];
    [hdrs appendString:@"Connection: close\r\n"]; // simplifies response reading

    // Forward all original headers except Host and Connection (we set them above)
    BOOL hasContentLength = NO;
    NSDictionary<NSString *, NSString *> *origHeaders = self.request.allHTTPHeaderFields;
    [origHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *val, BOOL *stop) {
        NSString *lk = key.lowercaseString;
        if ([lk isEqualToString:@"host"] || [lk isEqualToString:@"connection"]) return;
        if ([lk isEqualToString:@"content-length"]) hasContentLength = YES;
        [hdrs appendFormat:@"%@: %@\r\n", key, val];
    }];

    // Add Content-Length if there is a body but the serializer didn't add one
    if (body.length > 0 && !hasContentLength) {
        [hdrs appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    }

    [hdrs appendString:@"\r\n"]; // blank line = end of headers

    // ── Combine headers + body into wire bytes ──
    NSMutableData *wire = [NSMutableData data];
    [wire appendData:[hdrs dataUsingEncoding:NSUTF8StringEncoding]];
    if (body.length > 0) {
        [wire appendData:body];
    }

    // DISPATCH_DATA_DESTRUCTOR_DEFAULT copies the bytes, so 'wire' can be released freely
    dispatch_data_t sendData = dispatch_data_create(wire.bytes, wire.length,
                                                    nil,
                                                    DISPATCH_DATA_DESTRUCTOR_DEFAULT);

    __weak typeof(self) weakSelf = self;

    nw_connection_send(self.nwConnection, sendData,
                       NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
    ^(nw_error_t error) {
        if (error) {
            [weakSelf failWithCode:NSURLErrorCannotConnectToHost];
            return;
        }
        // Send succeeded — start reading the response
        [weakSelf receiveData];
    });
}

#pragma mark - Receive response bytes

- (void)receiveData {
    __weak typeof(self) weakSelf = self;

    // Ask for up to UINT32_MAX bytes in one call; we loop until is_complete
    nw_connection_receive(self.nwConnection, 1, UINT32_MAX,
    ^(dispatch_data_t content, nw_content_context_t ctx, bool is_complete, nw_error_t error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Append whatever arrived
        if (content) {
            dispatch_data_apply(content,
            ^bool(dispatch_data_t region, size_t offset, const void *buf, size_t size) {
                [strongSelf.receivedData appendBytes:buf length:size];
                return true;
            });
        }

        if (is_complete) {
            // Connection closed cleanly — we have the full response
            [strongSelf parseAndDeliverResponse];
        } else if (error) {
            // Connection died mid-stream
            if (strongSelf.receivedData.length > 0) {
                [strongSelf parseAndDeliverResponse]; // try with what we have
            } else {
                [strongSelf failWithCode:NSURLErrorNetworkConnectionLost];
            }
        } else if (content) {
            // Partial data; keep reading
            [weakSelf receiveData];
        }
    });
}

#pragma mark - Parse HTTP response and deliver to NSURLSession

- (void)parseAndDeliverResponse {
    // ── Locate header/body separator: \r\n\r\n ──
    const uint8_t sep[4] = {'\r','\n','\r','\n'};
    NSData  *sepData      = [NSData dataWithBytes:sep length:4];
    NSRange  sepRange     = [self.receivedData rangeOfData:sepData
                                                   options:0
                                                     range:NSMakeRange(0, self.receivedData.length)];
    if (sepRange.location == NSNotFound) {
        [self failWithCode:NSURLErrorBadServerResponse];
        return;
    }

    // ── Parse status line and headers ──
    NSData   *headerData = [self.receivedData subdataWithRange:
                            NSMakeRange(0, sepRange.location)];
    NSString *headerStr  = [[NSString alloc] initWithData:headerData
                                                 encoding:NSASCIIStringEncoding];
    if (!headerStr) {
        [self failWithCode:NSURLErrorBadServerResponse];
        return;
    }

    NSArray<NSString *> *lines = [headerStr componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) {
        [self failWithCode:NSURLErrorBadServerResponse];
        return;
    }

    // Status line: "HTTP/1.1 200 OK"
    NSArray<NSString *> *statusParts = [lines[0] componentsSeparatedByString:@" "];
    if (statusParts.count < 2) {
        [self failWithCode:NSURLErrorBadServerResponse];
        return;
    }
    NSInteger statusCode = [statusParts[1] integerValue];

    // Header fields (key lowercased for consistency with NSURLSession behaviour)
    NSMutableDictionary<NSString *, NSString *> *responseHeaders =
        [NSMutableDictionary dictionary];
    for (NSInteger i = 1; i < (NSInteger)lines.count; i++) {
        NSString *line       = lines[i];
        NSRange   colonRange = [line rangeOfString:@":"];
        if (colonRange.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:colonRange.location].lowercaseString;
        NSString *val = [[line substringFromIndex:colonRange.location + 1]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        responseHeaders[key] = val;
    }

    // ── Extract body ──
    NSUInteger bodyStart = sepRange.location + sepRange.length;
    NSData    *bodyData  = [self.receivedData subdataWithRange:
                            NSMakeRange(bodyStart, self.receivedData.length - bodyStart)];

    // Decode chunked transfer encoding when present
    NSString *te = responseHeaders[@"transfer-encoding"];
    if ([te.lowercaseString isEqualToString:@"chunked"]) {
        NSData *decoded = [self decodeChunkedData:bodyData];
        if (decoded) bodyData = decoded;
    }

    // ── Construct the NSHTTPURLResponse ──
    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                    statusCode:statusCode
                                   HTTPVersion:@"HTTP/1.1"
                                  headerFields:responseHeaders];

    // ── Deliver to the NSURLSession / AFNetworking stack ──
    [self.client URLProtocol:self
          didReceiveResponse:response
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];

    if (bodyData.length > 0) {
        [self.client URLProtocol:self didLoadData:bodyData];
    }

    [self.client URLProtocolDidFinishLoading:self];

    if (self.nwConnection) {
        nw_connection_cancel(self.nwConnection);
        self.nwConnection = nil;
    }
}

#pragma mark - Chunked Transfer Encoding decoder

- (nullable NSData *)decodeChunkedData:(NSData *)data {
    NSMutableData    *result = [NSMutableData data];
    const uint8_t   *bytes   = data.bytes;
    NSUInteger        length  = data.length;
    NSUInteger        offset  = 0;

    while (offset < length) {
        // Find end of chunk-size line (\r\n)
        NSUInteger lineEnd = offset;
        while (lineEnd + 1 < length &&
               !(bytes[lineEnd] == '\r' && bytes[lineEnd + 1] == '\n')) {
            lineEnd++;
        }
        if (lineEnd + 1 >= length) break;

        // Parse hex chunk size (strip any chunk extensions after ";")
        NSString *sizeLine = [[NSString alloc] initWithBytes:bytes + offset
                                                      length:lineEnd - offset
                                                    encoding:NSASCIIStringEncoding];
        NSRange semiRange = [sizeLine rangeOfString:@";"];
        if (semiRange.location != NSNotFound) {
            sizeLine = [sizeLine substringToIndex:semiRange.location];
        }
        sizeLine = [sizeLine stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];

        unsigned long long chunkSize = 0;
        NSScanner *scanner = [NSScanner scannerWithString:sizeLine];
        if (![scanner scanHexLongLong:&chunkSize]) break;
        if (chunkSize == 0) break; // terminal zero-length chunk

        offset = lineEnd + 2; // skip \r\n after size

        if (offset + (NSUInteger)chunkSize > length) break; // malformed

        [result appendBytes:bytes + offset length:(NSUInteger)chunkSize];
        offset += (NSUInteger)chunkSize + 2; // skip chunk data + trailing \r\n
    }

    return result;
}

#pragma mark - Error helper

- (void)failWithCode:(NSURLErrorCode)code {
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil];
    [self.client URLProtocol:self didFailWithError:error];
    if (self.nwConnection) {
        nw_connection_cancel(self.nwConnection);
        self.nwConnection = nil;
    }
}

@end
