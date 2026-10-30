// Z-Ts `M4-06`: AppKit system tray (`NSStatusItem`) behind a Flat C ABI.
//
// Mirrors what upstream `muda` does through the `tray-icon` crate:
//
//   * one `NSStatusItem` per tray (`[NSStatusBar statusBar] statusItemWithLength:…`)
//   * `button.target` / `button.action` for clicks (`sendActionOn:` left & right mouse up)
//   * right click (and, when enabled, left click) pops the attached `NSMenu` up under the item
//   * `button.toolTip` for the tooltip, `button.title` for the title text
//   * `button.image` for icons: a file path, raw PNG/ICO bytes, or an SF Symbol name for the
//     stock `NativeIcon`s
//
// The menu itself is built by `menu/native_macos_shim.m` (from the same flattened snapshot the
// menu bar uses), so a tray item click reaches the item's `Channel<string>` through the *menu*
// backend's activator — the tray never re-implements that plumbing.
//
// Every function returning memory hands over `malloc`'d UTF-8 owned by the caller
// (`zts_native_free` releases it).

#import <Cocoa/Cocoa.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/// `type`: 0 = Click, 1 = DoubleClick. `button`: 0 = left, 1 = right, 2 = middle.
typedef void (*ZtsTrayEventFn)(void *ctx, int type, int button);

/// Defined in `menu/native_macos_shim.m`; the tray needs `NSApp` before it can own a status item.
extern int zts_menu_init(void);

@class ZtsTrayHandle;
@class ZtsTrayTarget;

@interface ZtsTrayHandle : NSObject
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) ZtsTrayTarget *target;
/// SF Symbol name currently applied (kept for introspection instead of reading it back from
/// `NSImage`, whose accessibility metadata is not guaranteed to be populated).
@property(nonatomic, copy) NSString *symbolName;
@property(nonatomic, assign) int menuOnLeftClick;
@end

@interface ZtsTrayTarget : NSObject
@property(nonatomic, assign) ZtsTrayEventFn callback;
@property(nonatomic, assign) void *context;
@property(nonatomic, weak) ZtsTrayHandle *handle;
- (void)ztsTrayClicked:(id)sender;
@end

@implementation ZtsTrayTarget
- (void)ztsTrayClicked:(id)sender {
  if (self.callback == NULL) return;

  NSEvent *event = [NSApp currentEvent];
  int button = 0;
  int type = 0;
  if (event != nil) {
    if (event.type == NSEventTypeRightMouseUp || event.type == NSEventTypeRightMouseDown) {
      button = 1;
    } else if (event.type == NSEventTypeOtherMouseUp) {
      button = 2;
    }
    if (event.clickCount >= 2) type = 1;
  }

  self.callback(self.context, type, button);

  // The menu belongs to the item, so show it from here while the event is still current.
  ZtsTrayHandle *handle = self.handle;
  if (handle == nil || handle.menu == nil) return;
  if (button == 1 || (button == 0 && handle.menuOnLeftClick)) {
    [handle.item popUpStatusItemMenu:handle.menu];
  }
  (void)sender;
}
@end

@implementation ZtsTrayHandle
@end

// ---------------------------------------------------------------- helpers

extern void zts_native_free(void *ptr);

static void *zts_retain_bridge(id object) {
  return (__bridge_retained void *)object;
}

static NSString *zts_string(const char *utf8) {
  if (utf8 == NULL) return @"";
  NSString *s = [NSString stringWithUTF8String:utf8];
  return s != nil ? s : @"";
}

/// AppKit has no "stock menu icon" table, so the platform stock icons map onto the closest SF
/// Symbol (macOS 11+; older systems simply show no image, never a wrong one).
static NSString *zts_symbol_for_native(int native_icon) {
  switch (native_icon) {
    case 0: return @"plus";                  // Add
    case 1: return @"minus";                 // Remove
    case 2: return @"info.circle";           // About
    case 3: return @"gearshape";             // Services
    case 5: return @"doc.on.doc";            // Copy
    case 6: return @"scissors";              // Cut
    case 7: return @"doc.on.clipboard";      // Paste
    case 8: return @"textformat.123";        // SelectAll
    case 9: return @"arrow.uturn.backward";  // Undo
    case 10: return @"arrow.uturn.forward";  // Redo
    case 11: return @"minus.square";         // Minimize
    case 12: return @"plus.square";          // Maximize
    case 13: return @"arrow.up.left.and.arrow.down.right";  // Fullscreen
    case 14: return @"eye.slash";            // Hide
    case 17: return @"xmark.circle";         // CloseWindow
    case 18: return @"power";                // Quit
    default: return nil;
  }
}

static NSImage *zts_symbol_image(NSString *name, int as_template) {
  if (name == nil) return nil;
  if (@available(macOS 11.0, *)) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (image != nil && as_template) image.template = YES;
    return image;
  }
  return nil;
}

static void zts_tray_apply_image(ZtsTrayHandle *handle, NSImage *image, int as_template) {
  if (image != nil) image.template = as_template ? YES : NO;
  handle.symbolName = nil;
  handle.item.button.image = image;
  // A status item with an image keeps its title text to the right of it; both may coexist.
}

// ---------------------------------------------------------------- lifecycle

void *zts_tray_new(ZtsTrayEventFn callback, void *ctx, int menu_on_left_click) {
  if (!zts_menu_init()) return NULL;
  @autoreleasepool {
    NSStatusBar *bar = [NSStatusBar systemStatusBar];
    NSStatusItem *item = [bar statusItemWithLength:NSVariableStatusItemLength];
    if (item == nil) return NULL;

    ZtsTrayHandle *handle = [[ZtsTrayHandle alloc] init];
    handle.item = item;
    handle.menuOnLeftClick = menu_on_left_click != 0;

    ZtsTrayTarget *target = [[ZtsTrayTarget alloc] init];
    target.callback = callback;
    target.context = ctx;
    target.handle = handle;
    handle.target = target;

    item.button.target = target;
    item.button.action = @selector(ztsTrayClicked:);
    [item.button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];

    return zts_retain_bridge(handle);
  }
}

void zts_tray_free(void *raw) {
  if (raw == NULL) return;
  ZtsTrayHandle *handle = (__bridge_transfer ZtsTrayHandle *)raw;
  handle.item.button.target = nil;
  handle.item.button.action = nil;
  [[NSStatusBar systemStatusBar] removeStatusItem:handle.item];
  handle.item = nil;
  handle.menu = nil;
  handle.target = nil;
}

// ---------------------------------------------------------------- properties

void zts_tray_set_menu_on_left_click(void *raw, int enabled) {
  if (raw == NULL) return;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  handle.menuOnLeftClick = enabled != 0;
}

void zts_tray_set_menu(void *raw, void *ns_menu) {
  if (raw == NULL) return;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  handle.menu = (__bridge NSMenu *)ns_menu;
}

void zts_tray_set_tooltip(void *raw, const char *tooltip) {
  if (raw == NULL) return;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  handle.item.button.toolTip = (tooltip == NULL || *tooltip == '\0') ? nil : zts_string(tooltip);
}

/// AppKit draws `button.title` next to the icon — the closest thing to Tauri's `title`.
void zts_tray_set_title(void *raw, const char *title) {
  if (raw == NULL) return;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  handle.item.button.title = zts_string(title);
}

void zts_tray_set_visible(void *raw, int visible) {
  if (raw == NULL) return;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  handle.item.visible = visible != 0;
}

void zts_tray_set_image_path(void *raw, const char *path, int as_template) {
  if (raw == NULL) return;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  if (path == NULL || *path == '\0') {
    zts_tray_apply_image(handle, nil, 0);
    return;
  }
  NSString *file = zts_string(path);
  NSImage *image = [[NSImage alloc] initWithContentsOfFile:file];
  zts_tray_apply_image(handle, image, as_template);
}

/// Raw image bytes as `@tauri-apps/api/image` hands them over (PNG or ICO).
void zts_tray_set_image_bytes(void *raw, const void *data, size_t len, int as_template) {
  if (raw == NULL) return;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  if (data == NULL || len == 0) {
    zts_tray_apply_image(handle, nil, 0);
    return;
  }
  NSData *bytes = [NSData dataWithBytes:data length:len];
  NSImage *image = [[NSImage alloc] initWithData:bytes];
  zts_tray_apply_image(handle, image, as_template);
}

/// `menu.NativeIcon` ordinal → SF Symbol.
void zts_tray_set_native_image(void *raw, int native_icon, int as_template) {
  if (raw == NULL) return;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  NSString *symbol = zts_symbol_for_native(native_icon);
  zts_tray_apply_image(handle, zts_symbol_image(symbol, as_template), as_template);
  handle.symbolName = symbol;
}

// ---------------------------------------------------------------- introspection

static char *zts_strdup(NSString *s) {
  if (s == nil) return NULL;
  const char *utf8 = [s UTF8String];
  if (utf8 == NULL) return NULL;
  size_t len = strlen(utf8);
  char *out = (char *)malloc(len + 1);
  if (out == NULL) return NULL;
  memcpy(out, utf8, len + 1);
  return out;
}

int zts_tray_is_visible(void *raw) {
  if (raw == NULL) return -1;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  return handle.item.visible ? 1 : 0;
}

char *zts_tray_tooltip(void *raw) {
  if (raw == NULL) return NULL;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  return zts_strdup(handle.item.button.toolTip);
}

char *zts_tray_title(void *raw) {
  if (raw == NULL) return NULL;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  return zts_strdup(handle.item.button.title);
}

char *zts_tray_symbol(void *raw) {
  if (raw == NULL) return NULL;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  return zts_strdup(handle.symbolName);
}

int zts_tray_has_image(void *raw) {
  if (raw == NULL) return -1;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  NSImage *image = handle.item.button.image;
  return image != nil ? 1 : 0;
}

int zts_tray_is_template(void *raw) {
  if (raw == NULL) return -1;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  NSImage *image = handle.item.button.image;
  if (image == nil) return -1;
  return image.isTemplate ? 1 : 0;
}

int zts_tray_image_size(void *raw, double *width, double *height) {
  if (raw == NULL) return 0;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  NSImage *image = handle.item.button.image;
  if (image == nil) return 0;
  NSSize size = image.size;
  if (width != NULL) *width = size.width;
  if (height != NULL) *height = size.height;
  return 1;
}

int zts_tray_menu_item_count(void *raw) {
  if (raw == NULL) return -1;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  if (handle.menu == nil) return -1;
  return (int)[handle.menu numberOfItems];
}

int zts_tray_has_action(void *raw) {
  if (raw == NULL) return -1;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  return (handle.item.button.action != NULL && handle.item.button.target != nil) ? 1 : 0;
}

/// Drives the real `target`/`action` pair (tests, and hosts that want a synthetic click).
/// Returns 1 when AppKit dispatched the action.
int zts_tray_click(void *raw) {
  if (raw == NULL) return 0;
  ZtsTrayHandle *handle = (__bridge ZtsTrayHandle *)raw;
  NSButton *button = handle.item.button;
  if (button == nil || button.action == NULL) return 0;
  return [NSApp sendAction:button.action to:button.target from:button] ? 1 : 0;
}
