// Z-Ts macOS Native Backend Shim — Cocoa (`NSApplication` / `NSWindow`) + `WKWebView` (`M3-01`).
//
// This file is the ENTIRE Objective-C surface of Z-Ts. Everything it exposes is a flat C ABI
// (`zts_macos_*`) so the Zig side (`src/webview/macos.zig`) never needs `@cImport`, `addTranslateC`,
// or Objective-C runtime knowledge — keeping cold-compile time at ~2s and the boundary auditable.
//
// Design guarantees (mirrors `src/webview/linux.zig`):
// 1. **Step-driven event loop**: `zts_macos_step(h, block)` pumps exactly one AppKit run-loop
//    iteration (`nextEventMatchingMask:untilDate:inMode:dequeue:`) so the caller keeps main-thread
//    control, `defer` scopes, and 60/120fps render loops (`step(.poll)`).
// 2. **Raw `WKURLSchemeTask` NEVER escapes the main thread**: the shim retains the task in a
//    token table and hands Zig only `(window_id, token)` + copied bytes.
// 3. **`stopURLSchemeTask:` race immunity**: tokens are removed from the table the moment WebKit
//    stops the task, so a late completion finds `nil` and is dropped. Zig additionally validates a
//    generational `RequestId`, giving two independent layers of ABA protection.
// 4. **CSS top-left ⇔ Cocoa bottom-left**: only `zts_macos_window_set_position` takes native Cocoa
//    coordinates; the Zig wrapper performs the Y-axis conversion (unit-tested on any OS).

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <stdlib.h>
#include <string.h>

#pragma mark - C ABI types

typedef void (*zts_macos_scheme_cb)(
    void *userdata,
    unsigned long long win,
    unsigned long long token,
    const char *scheme,
    const char *method,
    const char *uri,
    const char *const *names,
    const char *const *values,
    unsigned long count,
    const void *body,
    unsigned long body_len);

typedef void (*zts_macos_message_cb)(void *userdata, unsigned long long win, const char *json);
typedef void (*zts_macos_close_cb)(void *userdata, unsigned long long win);

@class ZtsBackend;

#pragma mark - Window delegate

@interface ZtsWindowDelegate : NSObject <NSWindowDelegate>
@property (nonatomic, assign) void *backend;
@property (nonatomic, assign) unsigned long long ident;
@end

#pragma mark - JS -> Zig message bridge (`window.webkit.messageHandlers.__zts`)

@interface ZtsMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, assign) void *backend;
@property (nonatomic, assign) unsigned long long ident;
@end

#pragma mark - In-flight scheme task token

@interface ZtsSchemeTask : NSObject
@property (nonatomic, strong) id<WKURLSchemeTask> task;
@property (nonatomic, assign) unsigned long long token;
@property (nonatomic, assign) unsigned long long ident;
@end

#pragma mark - Window record

@interface ZtsWindow : NSObject
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) WKWebView *webview;
@property (nonatomic, strong) WKUserContentController *ucc;
@property (nonatomic, strong) ZtsWindowDelegate *delegate;
@property (nonatomic, assign) unsigned long long ident;
@property (nonatomic, assign) BOOL closed;
/// Host view this web view was embedded into (`M3-03`); `nil` for regular toplevel windows.
@property (nonatomic, weak) NSView *parentView;
@property (nonatomic, assign) BOOL has_min;
@property (nonatomic, assign) BOOL has_max;
@property (nonatomic, assign) double min_w;
@property (nonatomic, assign) double min_h;
@property (nonatomic, assign) double max_w;
@property (nonatomic, assign) double max_h;
@end

#pragma mark - `WKWebView` subclass remembering the last mouse-down (for `performWindowDragWithEvent:`)

@interface ZtsWebView : WKWebView
@property (nonatomic, strong) NSEvent *ztsLastMouseDown;
@end

#pragma mark - Backend

@interface ZtsBackend : NSObject
@property (nonatomic, strong) WKWebViewConfiguration *config;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<WKURLSchemeHandler>> *schemeHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, ZtsSchemeTask *> *tasks;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, ZtsWindow *> *windows;
@property (nonatomic, assign) unsigned long long nextToken;
@property (nonatomic, assign) unsigned long long nextWindow;
@property (atomic, assign) BOOL quit;
@property (atomic, assign) BOOL had_windows;
@property (atomic, assign) unsigned long long preflights;
@property (nonatomic, assign) BOOL regular;
@property (nonatomic, assign) void *msgUserdata;
@property (nonatomic, assign) zts_macos_message_cb msgCb;
@property (nonatomic, assign) void *closeUserdata;
@property (nonatomic, assign) zts_macos_close_cb closeCb;
@end

#pragma mark - Scheme handler

@interface ZtsSchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic, assign) void *backend;
@property (nonatomic, assign) void *userdata;
@property (nonatomic, assign) zts_macos_scheme_cb cb;
@property (nonatomic, copy) NSString *scheme;
@end

#pragma mark - Helpers

static inline ZtsBackend *ZtsB(void *h) { return (__bridge ZtsBackend *)h; }

static inline NSString *ZtsStr(const char *s) {
    if (s == NULL) return nil;
    return [NSString stringWithUTF8String:s];
}

static inline const char *ZtsCStr(NSString *s) {
    if (s == nil) return NULL;
    return [s UTF8String];
}

/// Reads `request.HTTPBodyStream` synchronously (WebKit delivers `fetch(..., {body})` payloads as a
/// stream for custom schemes, never as `HTTPBody`).
static NSData *ZtsReadBodyStream(NSInputStream *stream, NSUInteger cap) {
    if (stream == nil) return [NSData data];

    NSMutableData *out = [NSMutableData data];
    [stream open];
    uint8_t buf[16 * 1024];
    for (;;) {
        NSInteger n = [stream read:buf maxLength:(NSInteger)sizeof(buf)];
        if (n <= 0) break;
        [out appendBytes:buf length:(NSUInteger)n];
        if (out.length > cap) break;
    }
    [stream close];
    return out;
}

/// Case-insensitive `NSURLRequest.allHTTPHeaderFields` lookup (WebKit normalizes `fetch` headers to
/// lower case while AppKit-level requests keep their original casing).
static inline NSString *ZtsHeader(NSDictionary<NSString *, NSString *> *headers, NSString *name) {
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) return headers[key];
    }
    return nil;
}

/// WKWebView applies CORS to `fetch()` across custom schemes. Without these headers the unmodified
/// `@tauri-apps/api` v2 client cannot read the body or the `Tauri-Response` header at all.
static void ZtsApplyCorsHeaders(NSMutableDictionary<NSString *, NSString *> *headers) {
    if (headers[@"Access-Control-Allow-Origin"] == nil) {
        headers[@"Access-Control-Allow-Origin"] = @"*";
    }
    if (headers[@"Access-Control-Expose-Headers"] == nil) {
        // `@tauri-apps/api` needs `Tauri-Response`; the `Access-Control-*` names are listed too so
        // integration tests (and JS diagnostics) can observe the negotiated CORS state — WebKit
        // hides non-safelisted response headers from `fetch()` without this.
        headers[@"Access-Control-Expose-Headers"] =
            @"Tauri-Response,Tauri-Callback,Tauri-Error,Content-Type,Content-Length,Content-Range,"
            @"Accept-Ranges,Access-Control-Allow-Origin,Access-Control-Allow-Methods,"
            @"Access-Control-Allow-Headers,Access-Control-Max-Age";
    }
}

/// Answers a `CORS` preflight (`OPTIONS`) without ever crossing the C ABI: application handlers in
/// `zts_tauri` only implement real verbs, and `@tauri-apps/api` v2 issues `application/json` /
/// binary-body requests that WebKit preflights on custom schemes.
///
static void ZtsAnswerPreflight(ZtsBackend *b, id<WKURLSchemeTask> task,
                               NSDictionary<NSString *, NSString *> *headers) {
    b.preflights += 1;
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary new];
    ZtsApplyCorsHeaders(out);
    out[@"Access-Control-Allow-Methods"] = @"GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS";
    out[@"Access-Control-Max-Age"] = @"86400";
    NSString *requested = ZtsHeader(headers, @"Access-Control-Request-Headers");
    out[@"Access-Control-Allow-Headers"] = requested.length > 0 ? requested : @"*";
    out[@"Content-Length"] = @"0";

    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:task.request.URL
                                                          statusCode:204
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:out];
    if (resp == nil) return;
    @try {
        [task didReceiveResponse:resp];
        [task didFinish];
    } @catch (NSException *exception) {
        (void)exception;
    }
}

@implementation ZtsSchemeTask
@end

@implementation ZtsWindow
@end

@implementation ZtsBackend
@end

@implementation ZtsWebView

- (void)mouseDown:(NSEvent *)event {
    self.ztsLastMouseDown = event;
    [super mouseDown:event];
}

- (void)mouseUp:(NSEvent *)event {
    [super mouseUp:event];
}

@end

#pragma mark - Message handler

@implementation ZtsMessageHandler

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)controller;
    ZtsBackend *b = ZtsB(self.backend);
    if (b == nil || b.msgCb == NULL) return;

    NSString *text = nil;
    if ([message.body isKindOfClass:[NSString class]]) {
        text = (NSString *)message.body;
    } else if (message.body != nil) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:message.body options:0 error:NULL];
        if (json != nil) text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    }
    if (text == nil) return;

    b.msgCb(b.msgUserdata, self.ident, [text UTF8String]);
}

@end

#pragma mark - Window delegate

@implementation ZtsWindowDelegate

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    return YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    ZtsBackend *b = ZtsB(self.backend);
    if (b == nil) return;
    ZtsWindow *rec = b.windows[@(self.ident)];
    if (rec == nil || rec.closed) return;
    rec.closed = YES;
    b.windows[@(self.ident)] = nil;
    if (b.closeCb != NULL) b.closeCb(b.closeUserdata, self.ident);
}

@end

#pragma mark - URL scheme handler

@implementation ZtsSchemeHandler

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    ZtsBackend *b = ZtsB(self.backend);
    if (b == nil) return;

    NSURLRequest *req = task.request;
    NSString *uri = req.URL.absoluteString ?: @"";

    // Resolve the owning Z-Ts window by exact `WKWebView` identity.
    unsigned long long ident = 0;
    for (NSNumber *key in b.windows) {
        ZtsWindow *cand = b.windows[key];
        if (cand.webview == webView) {
            ident = cand.ident;
            break;
        }
    }
    if (ident == 0) {
        @try {
            [task didFailWithError:[NSError errorWithDomain:@"jp.zts.webview"
                                                       code:-3
                                                   userInfo:@{NSLocalizedDescriptionKey: @"No Z-Ts window owns this WKWebView"}]];
        } @catch (NSException *exception) {
            (void)exception;
        }
        return;
    }

    NSString *method = req.HTTPMethod ?: @"GET";
    NSDictionary<NSString *, NSString *> *headers = req.allHTTPHeaderFields ?: @{};

    // CORS preflight is answered entirely inside the shim (see `ZtsAnswerPreflight`).
    if ([method caseInsensitiveCompare:@"OPTIONS"] == NSOrderedSame) {
        ZtsAnswerPreflight(b, task, headers);
        return;
    }

    unsigned long long token = b.nextToken++;

    ZtsSchemeTask *holder = [ZtsSchemeTask new];
    holder.task = task;
    holder.token = token;
    holder.ident = ident;
    // Retaining the task here (not in Zig) is what makes late completions safe.
    b.tasks[@(token)] = holder;

    // `fetch(..., { body })` on a custom scheme arrives as `HTTPBodyStream`.
    NSData *body = req.HTTPBody;
    if (body == nil && req.HTTPBodyStream != nil) {
        body = ZtsReadBodyStream(req.HTTPBodyStream, 64u * 1024u * 1024u);
    }
    if (body == nil) body = [NSData data];

    // Build flat `char **` arrays valid for the duration of the callback.
    NSUInteger count = headers.count;
    char **names = (char **)calloc(count > 0 ? count : 1, sizeof(char *));
    char **values = (char **)calloc(count > 0 ? count : 1, sizeof(char *));
    NSUInteger idx = 0;
    for (NSString *key in headers) {
        names[idx] = strdup([key UTF8String]);
        values[idx] = strdup([[headers objectForKey:key] UTF8String]);
        idx += 1;
    }

    if (self.cb != NULL) {
        self.cb(
            self.userdata,
            ident,
            token,
            ZtsCStr(self.scheme),
            [method UTF8String],
            [uri UTF8String],
            (const char *const *)names,
            (const char *const *)values,
            (unsigned long)count,
            body.length > 0 ? body.bytes : NULL,
            (unsigned long)body.length);
    }

    for (NSUInteger i = 0; i < count; i += 1) {
        if (names[i] != NULL) free(names[i]);
        if (values[i] != NULL) free(values[i]);
    }
    free(names);
    free(values);
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    (void)webView;
    ZtsBackend *b = ZtsB(self.backend);
    if (b == nil) return;

    NSNumber *matched = nil;
    for (NSNumber *key in b.tasks) {
        ZtsSchemeTask *holder = b.tasks[key];
        if (holder.task == task) {
            matched = key;
            break;
        }
    }
    if (matched != nil) {
        // Removing the token makes every later `zts_macos_scheme_respond` a no-op.
        b.tasks[matched] = nil;
    }
}

@end

static ZtsSchemeHandler *ZtsHandlerFor(ZtsBackend *b, NSString *scheme) {
    id<WKURLSchemeHandler> h = b.schemeHandlers[scheme];
    if (h == nil || ![h isKindOfClass:[ZtsSchemeHandler class]]) return nil;
    return (ZtsSchemeHandler *)h;
}

#pragma mark - Lifecycle

void *zts_macos_backend_new(int regular) {
    @autoreleasepool {
        if (![NSThread isMainThread]) return NULL;

        NSApplication *app = [NSApplication sharedApplication];
        if (app == nil) return NULL;
        [app setActivationPolicy:(regular ? NSApplicationActivationPolicyRegular
                                          : NSApplicationActivationPolicyAccessory)];
        [app finishLaunching];

        ZtsBackend *b = [ZtsBackend new];
        b.config = [WKWebViewConfiguration new];
        b.schemeHandlers = [NSMutableDictionary new];
        b.tasks = [NSMutableDictionary new];
        b.windows = [NSMutableDictionary new];
        b.nextToken = 1;
        b.nextWindow = 1;
        b.quit = NO;
        b.regular = regular != 0;

        // `dispatch_get_main_queue` is unused on purpose: no blocks, no libBlocksRuntime dependency.
        return (__bridge_retained void *)b;
    }
}

void zts_macos_backend_free(void *h) {
    @autoreleasepool {
        if (h == NULL) return;
        ZtsBackend *b = (__bridge_transfer ZtsBackend *)h;

        NSArray<NSNumber *> *keys = b.windows.allKeys;
        for (NSNumber *key in keys) {
            ZtsWindow *rec = b.windows[key];
            rec.delegate = nil;
            rec.window.delegate = nil;
            [rec.webview stopLoading];
            [rec.window orderOut:nil];
            [rec.window close];
        }
        [b.windows removeAllObjects];
        [b.tasks removeAllObjects];
        [b.schemeHandlers removeAllObjects];
        b.config = nil;

        // Explicitly drop the last reference inside the pool so ARC releases before returning.
        b = nil;
    }
}

int zts_macos_step(void *h, int block) {
    @autoreleasepool {
        ZtsBackend *b = ZtsB(h);
        if (b == nil) return 0;
        if (b.quit) return 0;

        NSApplication *app = [NSApplication sharedApplication];
        // `distantFuture` would hang CI forever if a wakeup were ever missed, so a blocking step
        // caps at 1s: `wakeup()` still returns instantly, and an idle app wakes 1x/s (no measurable
        // CPU cost). `distantPast` keeps `step(.poll)` fully non-blocking.
        NSDate *until = block ? [NSDate dateWithTimeIntervalSinceNow:1.0] : [NSDate distantPast];
        NSEvent *event = [app nextEventMatchingMask:NSEventMaskAny
                                          untilDate:until
                                             inMode:NSDefaultRunLoopMode
                                            dequeue:YES];
        if (event != nil) {
            [app sendEvent:event];
        }
        [app updateWindows];

        if (b.quit) return 0;
        // Closing the LAST window ends the loop (`step` returns false). `had_windows` prevents an
        // immediate false return during backend construction, before `createWindow` is called.
        if (b.windows.count > 0) {
            b.had_windows = YES;
        } else if (b.had_windows) {
            return 0;
        }
        return 1;
    }
}

void zts_macos_wakeup(void *h) {
    ZtsBackend *b = ZtsB(h);
    if (b == nil) return;
    @autoreleasepool {
        NSEvent *ev = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                         location:NSZeroPoint
                                    modifierFlags:0
                                        timestamp:0
                                     windowNumber:0
                                          context:nil
                                          subtype:0
                                            data1:0
                                            data2:0];
        [NSApp postEvent:ev atStart:NO];
    }
}

void zts_macos_request_quit(void *h) {
    ZtsBackend *b = ZtsB(h);
    if (b == nil) return;
    b.quit = YES;
    zts_macos_wakeup(h);
}

unsigned long long zts_macos_preflight_count(void *h) {
    ZtsBackend *b = ZtsB(h);
    return b != nil ? b.preflights : 0;
}

int zts_macos_quit_requested(void *h) {
    ZtsBackend *b = ZtsB(h);
    return (b != nil && b.quit) ? 1 : 0;
}

void zts_macos_set_callbacks(
    void *h,
    void *msg_userdata,
    zts_macos_message_cb msg_cb,
    void *close_userdata,
    zts_macos_close_cb close_cb) {
    ZtsBackend *b = ZtsB(h);
    if (b == nil) return;
    b.msgUserdata = msg_userdata;
    b.msgCb = msg_cb;
    b.closeUserdata = close_userdata;
    b.closeCb = close_cb;
}

void zts_macos_screen_visible_frame(void *h, double *out_x, double *out_y, double *out_w, double *out_h) {
    (void)h;
    @autoreleasepool {
        NSScreen *screen = [NSScreen mainScreen];
        NSRect f = screen != nil ? screen.visibleFrame : NSMakeRect(0, 0, 1280, 800);
        if (out_x != NULL) *out_x = f.origin.x;
        if (out_y != NULL) *out_y = f.origin.y;
        if (out_w != NULL) *out_w = f.size.width;
        if (out_h != NULL) *out_h = f.size.height;
    }
}

#pragma mark - Scheme registration

void zts_macos_register_scheme(void *h, const char *scheme, void *userdata, zts_macos_scheme_cb cb) {
    ZtsBackend *b = ZtsB(h);
    if (b == nil || scheme == NULL || cb == NULL) return;
    @autoreleasepool {
        NSString *name = ZtsStr(scheme);
        if (name == nil || name.length == 0) return;
        if (ZtsHandlerFor(b, name) != nil) return; // already registered

        ZtsSchemeHandler *handler = [ZtsSchemeHandler new];
        handler.backend = h;
        handler.userdata = userdata;
        handler.cb = cb;
        handler.scheme = name;
        b.schemeHandlers[name] = handler;
        [b.config setURLSchemeHandler:handler forURLScheme:name];
    }
}

void zts_macos_scheme_respond(
    void *h,
    unsigned long long token,
    int status,
    const char *content_type,
    const char *const *names,
    const char *const *values,
    unsigned long count,
    const void *body,
    unsigned long body_len) {
    ZtsBackend *b = ZtsB(h);
    if (b == nil) return;
    @autoreleasepool {
        ZtsSchemeTask *holder = b.tasks[@(token)];
        if (holder == nil) return; // canceled by `stopURLSchemeTask:` (or window closed)

        id<WKURLSchemeTask> task = holder.task;
        [b.tasks removeObjectForKey:@(token)];

        NSURL *url = task.request.URL;
        if (url == nil) return;

        NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary new];
        for (unsigned long i = 0; names != NULL && values != NULL && i < count; i += 1) {
            if (names[i] == NULL) continue;
            NSString *name = ZtsStr(names[i]);
            NSString *value = values[i] != NULL ? ZtsStr(values[i]) : @"";
            if (name == nil || name.length == 0) continue;
            headers[name] = value ?: @"";
        }
        if (content_type != NULL) {
            NSString *ct = ZtsStr(content_type);
            if (ct != nil && ct.length > 0) headers[@"Content-Type"] = ct;
        }
        if (headers[@"Content-Type"] == nil) headers[@"Content-Type"] = @"application/octet-stream";
        ZtsApplyCorsHeaders(headers);

        NSData *data = [NSData data];
        if (body != NULL && body_len > 0) {
            data = [NSData dataWithBytes:body length:(NSUInteger)body_len];
        }
        headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)data.length];

        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:url
                                                             statusCode:(NSInteger)status
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:headers];
        if (resp == nil) {
            [task didFailWithError:[NSError errorWithDomain:@"jp.zts.webview"
                                                       code:-2
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Bad response"}]];
            return;
        }
        @try {
            [task didReceiveResponse:resp];
            if (data.length > 0) [task didReceiveData:data];
            [task didFinish];
        } @catch (NSException *exception) {
            // WebKit invalidated the task between the liveness check and the callback.
            (void)exception;
        }
    }
}

void zts_macos_scheme_fail(void *h, unsigned long long token) {
    ZtsBackend *b = ZtsB(h);
    if (b == nil) return;
    @autoreleasepool {
        ZtsSchemeTask *holder = b.tasks[@(token)];
        if (holder == nil) return;
        id<WKURLSchemeTask> task = holder.task;
        [b.tasks removeObjectForKey:@(token)];

        NSError *err = [NSError errorWithDomain:@"jp.zts.webview"
                                           code:-1
                                       userInfo:@{NSLocalizedDescriptionKey: @"Request failed"}];
        @try {
            [task didFailWithError:err];
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
}

#pragma mark - Window creation

unsigned long long zts_macos_window_new(
    void *h,
    const char *title,
    double width,
    double height,
    int resizable,
    int decorations,
    int transparent,
    int always_on_top,
    int visible,
    int fullscreen,
    int devtools,
    int has_pos,
    double pos_x,
    double pos_y,
    void *parent_nsview,
    const char *url,
    const char *html) {
    ZtsBackend *b = ZtsB(h);
    if (b == nil) return 0;

    @autoreleasepool {
        double w = width > 1.0 ? width : 1.0;
        double hgt = height > 1.0 ? height : 1.0;

        NSRect frame = NSMakeRect(pos_x, pos_y, w, hgt);
        NSWindowStyleMask style = 0;
        if (decorations) {
            style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
            if (resizable) style |= NSWindowStyleMaskResizable;
        } else {
            style = NSWindowStyleMaskBorderless;
            if (resizable) style |= NSWindowStyleMaskResizable;
        }
        if (transparent) style |= NSWindowStyleMaskFullSizeContentView;

        NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:style
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        if (win == nil) return 0;

        NSString *nsTitle = ZtsStr(title);
        win.title = nsTitle != nil ? nsTitle : @"Z-Ts";
        win.releasedWhenClosed = NO;
        win.level = always_on_top ? NSFloatingWindowLevel : NSNormalWindowLevel;
        if (@available(macOS 11.0, *)) {
            win.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
        }
        if (transparent) {
            win.opaque = NO;
            win.backgroundColor = [NSColor clearColor];
            win.titlebarAppearsTransparent = YES;
            win.titleVisibility = NSWindowTitleHidden;
        }

        WKWebViewConfiguration *config = [b.config copy];
        WKUserContentController *ucc = [WKUserContentController new];

        ZtsMessageHandler *msgHandler = [ZtsMessageHandler new];
        msgHandler.backend = h;
        msgHandler.ident = 0; // patched below once the window id is known
        [ucc addScriptMessageHandler:msgHandler name:@"__zts"];

        NSString *bridgeJS =
            @"window.__ztsPostMessage = (m) => window.webkit.messageHandlers.__zts.postMessage(m);";
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:bridgeJS
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:NO]];
        config.userContentController = ucc;

        WKWebView *webview = [[ZtsWebView alloc] initWithFrame:NSMakeRect(0, 0, w, hgt) configuration:config];
        if (webview == nil) return 0;
        webview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        if (transparent) {
            @try {
                [webview setValue:@NO forKey:@"drawsBackground"];
            } @catch (NSException *exception) {
                (void)exception;
            }
        }
        if (devtools) {
            if (@available(macOS 13.3, *)) {
                [webview setInspectable:YES];
            }
        }

        if (!has_pos) {
            [win center];
        }

        unsigned long long ident = b.nextWindow++;

        ZtsWindowDelegate *delegate = [ZtsWindowDelegate new];
        delegate.backend = h;
        delegate.ident = ident;
        win.delegate = delegate;

        ZtsWindow *rec = [ZtsWindow new];
        rec.window = win;
        rec.webview = webview;
        rec.ucc = ucc;
        rec.delegate = delegate;
        rec.ident = ident;
        rec.closed = NO;
        b.windows[@(ident)] = rec;
        msgHandler.ident = ident;

        if (parent_nsview != NULL) {
            NSView *parent = (__bridge NSView *)parent_nsview;
            // Overlay mode (`M3-03`): fill the host view instead of the requested size. The
            // autoresizing mask keeps it glued to the host on every host resize.
            webview.frame = parent.bounds;
            [parent addSubview:webview];
            rec.parentView = parent;
        } else {
            win.contentView = webview;
            if (fullscreen) {
                [win toggleFullScreen:nil];
            }
            if (visible) {
                [win orderFrontRegardless];
                if (b.regular) [NSApp activateIgnoringOtherApps:YES];
            }
        }

        if (html != NULL) {
            NSString *htmlStr = ZtsStr(html);
            NSURL *base = url != NULL ? [NSURL URLWithString:ZtsStr(url)] : [NSURL URLWithString:@"about:blank"];
            [webview loadHTMLString:htmlStr ?: @"" baseURL:base];
        } else if (url != NULL) {
            NSString *urlStr = ZtsStr(url);
            NSURL *nsURL = urlStr != nil ? [NSURL URLWithString:urlStr] : nil;
            if (nsURL != nil) {
                [webview loadRequest:[NSURLRequest requestWithURL:nsURL]];
            }
        }

        return ident;
    }
}

static ZtsWindow *ZtsWindowFor(ZtsBackend *b, unsigned long long ident) {
    if (b == nil || ident == 0) return nil;
    ZtsWindow *rec = b.windows[@(ident)];
    if (rec == nil || rec.closed) return nil;
    return rec;
}

int zts_macos_window_close(void *h, unsigned long long ident) {
    ZtsBackend *b = ZtsB(h);
    if (b == nil) return 0;
    @autoreleasepool {
        ZtsWindow *rec = b.windows[@(ident)];
        if (rec == nil) return 0;
        // Mark closed BEFORE `[win close]` so the synchronous `windowWillClose:` cannot double-free.
        rec.closed = YES;
        rec.window.delegate = nil;
        [b.windows removeObjectForKey:@(ident)];
        [rec.webview stopLoading];
        [rec.window orderOut:nil];
        [rec.window close];
        rec.webview = nil;
        rec.window = nil;
        rec.ucc = nil;
        return 1;
    }
}

void zts_macos_window_frame(void *h, unsigned long long ident, double *out_x, double *out_y,
                            double *out_w, double *out_h) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) {
        if (out_x != NULL) *out_x = 0;
        if (out_y != NULL) *out_y = 0;
        if (out_w != NULL) *out_w = 0;
        if (out_h != NULL) *out_h = 0;
        return;
    }
    NSRect f = rec.window.frame;
    if (out_x != NULL) *out_x = f.origin.x;
    if (out_y != NULL) *out_y = f.origin.y;
    if (out_w != NULL) *out_w = f.size.width;
    if (out_h != NULL) *out_h = f.size.height;
}

void *zts_macos_window_native(void *h, unsigned long long ident) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return NULL;
    // Embedded windows live in the HOST's `NSView` tree and own no `NSWindow` — hand back the
    // `WKWebView` itself so host code can prove placement with `[view superview]` (`M3-03`).
    if (rec.parentView != nil) return (__bridge void *)rec.webview;
    return (__bridge void *)rec.window;
}

/// Overlay embedding (`M3-03`): resize the child WebView to the host view's bounds.
/// Returns 1 on success, 0 when the window is not embedded (or no longer alive).
int zts_macos_window_fit_parent(void *h, unsigned long long ident) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil || rec.parentView == nil) return 0;
    @autoreleasepool {
        rec.webview.frame = rec.parentView.bounds;
        return 1;
    }
}

void zts_macos_window_set_title(void *h, unsigned long long ident, const char *title) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    @autoreleasepool {
        NSString *s = ZtsStr(title);
        rec.window.title = s != nil ? s : @"";
    }
}

void zts_macos_window_set_size(void *h, unsigned long long ident, double width, double height) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    NSRect frame = rec.window.frame;
    // Keep the top-left corner fixed while resizing in Cocoa's bottom-left space.
    double top = frame.origin.y + frame.size.height;
    double next_h = height > 1.0 ? height : 1.0;
    NSRect next = NSMakeRect(frame.origin.x, top - next_h, width > 1.0 ? width : 1.0, next_h);
    [rec.window setFrame:next display:YES animate:NO];
}

void zts_macos_window_set_min_size(void *h, unsigned long long ident, int enabled, double width, double height) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    rec.has_min = enabled != 0;
    rec.min_w = width;
    rec.min_h = height;
    if (rec.has_min) rec.window.contentMinSize = NSMakeSize(width, height);
}

void zts_macos_window_set_max_size(void *h, unsigned long long ident, int enabled, double width, double height) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    rec.has_max = enabled != 0;
    rec.max_w = width;
    rec.max_h = height;
    if (rec.has_max) rec.window.contentMaxSize = NSMakeSize(width, height);
}

void zts_macos_window_set_position(void *h, unsigned long long ident, double x, double y) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    // `x` / `y` are native Cocoa (bottom-left) coordinates; `macos.zig` converted them from CSS.
    [rec.window setFrameOrigin:NSMakePoint(x, y)];
}

void zts_macos_window_set_resizable(void *h, unsigned long long ident, int value) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    if (value != 0) {
        rec.window.styleMask |= NSWindowStyleMaskResizable;
    } else {
        rec.window.styleMask &= ~NSWindowStyleMaskResizable;
    }
}

void zts_macos_window_set_minimized(void *h, unsigned long long ident, int value) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    if (value != 0) {
        [rec.window miniaturize:nil];
    } else {
        [rec.window deminiaturize:nil];
    }
}

void zts_macos_window_set_maximized(void *h, unsigned long long ident, int value) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    if (value != 0) {
        if (!rec.window.isZoomed) [rec.window zoom:nil];
    } else {
        if (rec.window.isZoomed) [rec.window zoom:nil];
    }
}

void zts_macos_window_set_fullscreen(void *h, unsigned long long ident, int value) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    BOOL want = value != 0;
    BOOL is_full = (rec.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    if (want != is_full) [rec.window toggleFullScreen:nil];
}

void zts_macos_window_set_visible(void *h, unsigned long long ident, int value) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    if (value != 0) {
        [rec.window orderFrontRegardless];
    } else {
        [rec.window orderOut:nil];
    }
}

void zts_macos_window_set_decorations(void *h, unsigned long long ident, int value) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    if (value != 0) {
        rec.window.styleMask |= NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    } else {
        rec.window.styleMask &= ~(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable);
        rec.window.titlebarAppearsTransparent = YES;
        rec.window.titleVisibility = NSWindowTitleHidden;
    }
}

void zts_macos_window_set_always_on_top(void *h, unsigned long long ident, int value) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    rec.window.level = value != 0 ? NSFloatingWindowLevel : NSNormalWindowLevel;
}

void zts_macos_window_set_focus(void *h, unsigned long long ident) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    [rec.window makeKeyAndOrderFront:nil];
    if (ZtsB(h).regular) [NSApp activateIgnoringOtherApps:YES];
}

void zts_macos_window_start_drag(void *h, unsigned long long ident) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    @autoreleasepool {
        NSEvent *event = nil;
        if ([rec.webview isKindOfClass:[ZtsWebView class]]) {
            event = ((ZtsWebView *)rec.webview).ztsLastMouseDown;
        }
        if (event == nil) event = NSApp.currentEvent;
        if (event != nil) {
            [rec.window performWindowDragWithEvent:event];
        }
    }
}

void zts_macos_window_add_init_script(void *h, unsigned long long ident, const char *script) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil || script == NULL) return;
    @autoreleasepool {
        NSString *src = ZtsStr(script);
        if (src == nil || src.length == 0) return;
        [rec.ucc addUserScript:[[WKUserScript alloc] initWithSource:src
                                                      injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                   forMainFrameOnly:NO]];
    }
}

void zts_macos_window_eval_js(void *h, unsigned long long ident, const char *script) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil || script == NULL) return;
    @autoreleasepool {
        NSString *src = ZtsStr(script);
        if (src == nil || src.length == 0) return;
        [rec.webview evaluateJavaScript:src completionHandler:nil];
    }
}

void zts_macos_window_navigate(void *h, unsigned long long ident, const char *url) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil || url == NULL) return;
    @autoreleasepool {
        NSString *s = ZtsStr(url);
        NSURL *nsURL = s != nil ? [NSURL URLWithString:s] : nil;
        if (nsURL != nil) [rec.webview loadRequest:[NSURLRequest requestWithURL:nsURL]];
    }
}

void zts_macos_window_load_html(void *h, unsigned long long ident, const char *html, const char *base_url) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    @autoreleasepool {
        NSString *doc = html != NULL ? ZtsStr(html) : @"";
        NSURL *base = base_url != NULL ? [NSURL URLWithString:ZtsStr(base_url)] : [NSURL URLWithString:@"about:blank"];
        [rec.webview loadHTMLString:doc ?: @"" baseURL:base];
    }
}

void zts_macos_window_open_devtools(void *h, unsigned long long ident) {
    ZtsWindow *rec = ZtsWindowFor(ZtsB(h), ident);
    if (rec == nil) return;
    if (@available(macOS 13.3, *)) {
        [rec.webview setInspectable:YES];
    }
}
