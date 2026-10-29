// Z-Ts `M4-05`: AppKit menu backend (`NSMenu` / `NSMenuItem`) behind a Flat C ABI, so the Zig
// side never needs `@cImport` and never touches an Objective-C object directly.
//
// The Zig backend hands over the *flattened* pre-order snapshot the core already produces
// (`src/tauri/menu/mod.zig` → `Snapshot`), with a `depth` per entry. This file turns it into an
// `NSMenu` tree: `depth` 0 goes into the root menu, a submenu entry opens a new `NSMenu` for
// `depth + 1`, everything else becomes a leaf. No diffing, no widget bookkeeping in the core —
// the same contract the GTK backend follows.
//
// ## Activation
//
// Items that are *not* predefined get `action = ztsActivate:` with a shared target object; the
// item's `tag` carries the 1-based command id from `snapshot_wire.zig`, which the target forwards
// to the Zig `Activator` as a 16-bit value. Predefined items instead use the AppKit selector that
// does the work natively (`terminate:`, `hide:`, `copy:`, …) with a `nil` target so the responder
// chain handles it — exactly what upstream `muda` does.
//
// Every function that returns memory hands over `malloc`'d UTF-8 owned by the caller
// (`zts_native_free` from `native_macos_shim.m` releases it).

#import <Cocoa/Cocoa.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------- wire types

/// Mirrors `snapshot_wire.WireEntry` (field order, padding and size are asserted by a Zig test).
typedef struct {
  uint8_t kind;      // 0 = submenu, 1 = item, 2 = separator
  uint8_t role;      // `snapshot_wire.Role`
  uint8_t flags;     // bit0 = enabled, bit1 = checked
  uint8_t reserved0;
  uint16_t depth;
  uint16_t command;  // 1-based; 0 for separators
  const char *id;
  const char *text;
  const char *key_equivalent;
  uint8_t modifier_mask;  // bit0 shift, bit1 control, bit2 option, bit3 command
  uint8_t reserved1[3];
} ZtsMenuEntry;

typedef void (*ZtsMenuActivateFn)(void *ctx, uint16_t command);

// ---------------------------------------------------------------- roles

enum {
  ZTS_ROLE_NONE = 0,
  ZTS_ROLE_ABOUT,
  ZTS_ROLE_SERVICES,
  ZTS_ROLE_HIDE,
  ZTS_ROLE_HIDE_OTHERS,
  ZTS_ROLE_SHOW_ALL,
  ZTS_ROLE_CLOSE_WINDOW,
  ZTS_ROLE_QUIT,
  ZTS_ROLE_BRING_ALL_TO_FRONT,
  ZTS_ROLE_MINIMIZE,
  ZTS_ROLE_MAXIMIZE,
  ZTS_ROLE_FULLSCREEN,
  ZTS_ROLE_UNDO,
  ZTS_ROLE_REDO,
  ZTS_ROLE_CUT,
  ZTS_ROLE_COPY,
  ZTS_ROLE_PASTE,
  ZTS_ROLE_SELECT_ALL,
};

extern void zts_native_free(void *ptr);

// ---------------------------------------------------------------- target

/// The single `action:` receiver shared by every channel-backed item. AppKit needs an object
/// target, and an object needs a class — this is that class, defined here so the Zig side only
/// sees a `void *` handle.
@interface ZtsMenuTarget : NSObject
@property(nonatomic, assign) ZtsMenuActivateFn callback;
@property(nonatomic, assign) void *context;
- (void)ztsActivate:(id)sender;
@end

@implementation ZtsMenuTarget
- (void)ztsActivate:(id)sender {
  if (self.callback == NULL) return;
  NSInteger tag = [sender tag];
  if (tag <= 0 || tag > 0xFFFF) return;
  self.callback(self.context, (uint16_t)tag);
}
@end

/// Everything one `plugin:menu`-visible menu owns: the `NSMenu` root and its action target.
@interface ZtsMenuHandle : NSObject
@property(nonatomic, strong) NSMenu *root;
@property(nonatomic, strong) ZtsMenuTarget *target;
@end

@implementation ZtsMenuHandle
@end

// ---------------------------------------------------------------- helpers

static void *zts_retain_bridge(id object) {
  return (__bridge_retained void *)object;
}

static NSMenu *zts_autodisable(NSMenu *menu) {
  // `plugin:menu` owns item enablement; AppKit must not second-guess it by walking the responder
  // chain (`autoenablesItems` would grey out everything without a live window).
  menu.autoenablesItems = NO;
  return menu;
}

static SEL zts_role_selector(uint8_t role) {
  switch (role) {
    case ZTS_ROLE_ABOUT: return @selector(orderFrontStandardAboutPanel:);
    case ZTS_ROLE_HIDE: return @selector(hide:);
    case ZTS_ROLE_HIDE_OTHERS: return @selector(hideOtherApplications:);
    case ZTS_ROLE_SHOW_ALL: return @selector(unhideAllApplications:);
    case ZTS_ROLE_CLOSE_WINDOW: return @selector(performClose:);
    case ZTS_ROLE_QUIT: return @selector(terminate:);
    case ZTS_ROLE_BRING_ALL_TO_FRONT: return @selector(arrangeInFront:);
    case ZTS_ROLE_MINIMIZE: return @selector(performMiniaturize:);
    case ZTS_ROLE_MAXIMIZE: return @selector(performZoom:);
    case ZTS_ROLE_FULLSCREEN: return @selector(toggleFullScreen:);
    case ZTS_ROLE_UNDO: return @selector(undo:);
    case ZTS_ROLE_REDO: return @selector(redo:);
    case ZTS_ROLE_CUT: return @selector(cut:);
    case ZTS_ROLE_COPY: return @selector(copy:);
    case ZTS_ROLE_PASTE: return @selector(paste:);
    case ZTS_ROLE_SELECT_ALL: return @selector(selectAll:);
    // `services` has no selector: AppKit fills the submenu in from `[NSApp setServicesMenu:]`.
    default: return NULL;
  }
}

static NSString *zts_string(const char *utf8) {
  if (utf8 == NULL) return @"";
  NSString *s = [NSString stringWithUTF8String:utf8];
  return s != nil ? s : @"";
}

// ---------------------------------------------------------------- lifecycle

/// Brings `NSApplication` up far enough to own a menu bar (CI runs the test binary directly, with
/// no bundle). Returns 1 when `NSApp` exists.
int zts_menu_init(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    return NSApp != nil ? 1 : 0;
  }
}

/// Creates a handle with an empty root menu. Returns NULL when AppKit is unavailable.
void *zts_menu_new(ZtsMenuActivateFn callback, void *ctx) {
  if (!zts_menu_init()) return NULL;
  @autoreleasepool {
    ZtsMenuHandle *handle = [[ZtsMenuHandle alloc] init];
    handle.root = zts_autodisable([[NSMenu alloc] initWithTitle:@"Z-Ts"]);
    handle.target = [[ZtsMenuTarget alloc] init];
    handle.target.callback = callback;
    handle.target.context = ctx;
    return zts_retain_bridge(handle);
  }
}

/// Updates the activation callback (the core re-registers it before every apply).
void zts_menu_set_activator(void *raw, ZtsMenuActivateFn callback, void *ctx) {
  if (raw == NULL) return;
  ZtsMenuHandle *handle = (__bridge ZtsMenuHandle *)raw;
  handle.target.callback = callback;
  handle.target.context = ctx;
}

void zts_menu_free(void *raw) {
  if (raw == NULL) return;
  ZtsMenuHandle *handle = (__bridge_transfer ZtsMenuHandle *)raw;
  handle.root = nil;
  handle.target = nil;
}

/// The raw `NSMenu *` (tests / hosts that need to attach it themselves).
void *zts_menu_root(void *raw) {
  if (raw == NULL) return NULL;
  ZtsMenuHandle *handle = (__bridge ZtsMenuHandle *)raw;
  return (__bridge void *)handle.root;
}

// ---------------------------------------------------------------- build

/// Rebuilds the root menu from a flat pre-order list. Returns 0 on success.
int zts_menu_apply(void *raw, const ZtsMenuEntry *entries, size_t count) {
  if (raw == NULL) return -1;
  if (entries == NULL && count > 0) return -1;
  ZtsMenuHandle *handle = (__bridge ZtsMenuHandle *)raw;

  @autoreleasepool {
    [handle.root removeAllItems];

    // `stack[d]` is the menu that depth-`d` entries are appended to.
    NSMenu *stack[16] = {nil};
    stack[0] = handle.root;

    for (size_t i = 0; i < count; i++) {
      const ZtsMenuEntry *entry = &entries[i];
      if (entry->depth >= 16) return -1;
      NSMenu *parent = stack[entry->depth];
      if (parent == nil) return -2;  // depth skipped a level (the core rejects this first)

      if (entry->kind == 2) {
        [parent addItem:[NSMenuItem separatorItem]];
        continue;
      }

      NSString *title = zts_string(entry->text);
      if (entry->kind == 0) {  // submenu
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        NSMenu *submenu = zts_autodisable([[NSMenu alloc] initWithTitle:title]);
        item.submenu = submenu;
        item.tag = (NSInteger)entry->command;
        if ((entry->flags & 1) == 0) item.enabled = NO;
        [parent addItem:item];
        if (entry->depth + 1 < 16) stack[entry->depth + 1] = submenu;
        continue;
      }

      SEL selector = zts_role_selector(entry->role);
      NSString *key = zts_string(entry->key_equivalent);
      NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:selector keyEquivalent:key];
      item.tag = (NSInteger)entry->command;

      if (selector == NULL) {
        // No native role: route the click back through the bridge object.
        item.target = handle.target;
        item.action = @selector(ztsActivate:);
      } else {
        item.target = nil;  // the responder chain (`terminate:`, `copy:`, …) does the work
      }

      if (key.length > 0) {
        NSEventModifierFlags mask = 0;
        if (entry->modifier_mask & 0x1) mask |= NSEventModifierFlagShift;
        if (entry->modifier_mask & 0x2) mask |= NSEventModifierFlagControl;
        if (entry->modifier_mask & 0x4) mask |= NSEventModifierFlagOption;
        if (entry->modifier_mask & 0x8) mask |= NSEventModifierFlagCommand;
        item.keyEquivalentModifierMask = mask;
      }

      item.enabled = (entry->flags & 1) != 0 ? YES : NO;
      if (entry->role == ZTS_ROLE_NONE) {
        item.state = (entry->flags & 2) != 0 ? NSControlStateValueOn : NSControlStateValueOff;
      }

      if (entry->role == ZTS_ROLE_SERVICES) {
        // AppKit populates the services submenu; it has to be registered on NSApp.
        NSMenu *services = zts_autodisable([[NSMenu alloc] initWithTitle:title]);
        NSApp.servicesMenu = services;
        item.submenu = services;
      }

      [parent addItem:item];
    }
    return 0;
  }
}

// ---------------------------------------------------------------- attachment

/// Installs the menu as the application menu bar (`Menu.setAsAppMenu`).
void zts_menu_set_app(void *raw) {
  if (raw == NULL) return;
  if (!zts_menu_init()) return;
  ZtsMenuHandle *handle = (__bridge ZtsMenuHandle *)raw;
  NSApp.mainMenu = handle.root;
}

/// Installs the menu as `window`'s menu bar (`Menu.setAsWindowMenu`). AppKit shows it while that
/// window is key — there is no per-window menu bar the way Win32/GTK have one.
void zts_menu_set_window(void *raw, void *ns_window) {
  if (raw == NULL) return;
  NSWindow *window = (__bridge NSWindow *)ns_window;
  if (window == nil) return;
  ZtsMenuHandle *handle = (__bridge ZtsMenuHandle *)raw;
  window.menu = handle.root;
}

/// Pops the menu up at `(x, y)` in `view` (logical, top-left origin) or at the mouse when
/// `has_position` is 0. Returns 1 when AppKit actually showed it.
int zts_menu_popup(void *raw, void *ns_view, double x, double y, int has_position) {
  if (raw == NULL) return 0;
  ZtsMenuHandle *handle = (__bridge ZtsMenuHandle *)raw;
  NSView *view = (__bridge NSView *)ns_view;
  if (view == nil) {
    // No view: fall back to the mouse location in the key window.
    NSWindow *window = NSApp.keyWindow;
    view = window.contentView;
    has_position = 0;
    if (view == nil) return 0;
  }

  NSPoint location;
  if (has_position) {
    // `Position` arrives in the same top-left logical space `tauri`'s `LogicalPosition` uses;
    // AppKit's view coordinates grow upwards.
    location = NSMakePoint(x, view.bounds.size.height - y);
  } else {
    NSPoint screen = [NSEvent mouseLocation];
    NSRect frame = [view.window convertRectFromScreen:NSMakeRect(screen.x, screen.y, 0, 0)];
    location = [view convertPoint:frame.origin fromView:nil];
  }

  return [handle.root popUpMenuPositioningItem:nil atLocation:location inView:view] ? 1 : 0;
}

// ---------------------------------------------------------------- windows

/// Creates a hidden `NSWindow` (hosts that embed Z-Ts hand over *their* window; tests use this to
/// exercise per-window menus without spinning up a webview). Returns NULL when AppKit is missing.
void *zts_menu_window_new(double width, double height) {
  if (!zts_menu_init()) return NULL;
  @autoreleasepool {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, width, height)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.releasedWhenClosed = NO;
    window.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    return zts_retain_bridge(window);
  }
}

void zts_menu_window_free(void *raw) {
  if (raw == NULL) return;
  NSWindow *window = (__bridge_transfer NSWindow *)raw;
  [window close];
}

// ---------------------------------------------------------------- introspection

/// `[NSMenu numberOfItems]`.
size_t zts_menu_item_count(void *raw_menu) {
  NSMenu *menu = (__bridge NSMenu *)raw_menu;
  if (menu == nil) return 0;
  return (size_t)[menu numberOfItems];
}

static NSMenuItem *zts_item_at(void *raw_menu, size_t index) {
  NSMenu *menu = (__bridge NSMenu *)raw_menu;
  if (menu == nil) return nil;
  if ((NSUInteger)index >= [menu numberOfItems]) return nil;
  return [menu itemAtIndex:(NSInteger)index];
}

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

char *zts_menu_item_title(void *raw_menu, size_t index) {
  return zts_strdup([zts_item_at(raw_menu, index) title]);
}

char *zts_menu_item_key_equivalent(void *raw_menu, size_t index) {
  return zts_strdup([zts_item_at(raw_menu, index) keyEquivalent]);
}

int zts_menu_item_enabled(void *raw_menu, size_t index) {
  NSMenuItem *item = zts_item_at(raw_menu, index);
  return item != nil ? ([item isEnabled] ? 1 : 0) : -1;
}

int zts_menu_item_state(void *raw_menu, size_t index) {
  NSMenuItem *item = zts_item_at(raw_menu, index);
  return item != nil ? (int)[item state] : -1;
}

int zts_menu_item_key_mask(void *raw_menu, size_t index) {
  NSMenuItem *item = zts_item_at(raw_menu, index);
  if (item == nil) return -1;
  NSEventModifierFlags mask = [item keyEquivalentModifierMask];
  int out = 0;
  if (mask & NSEventModifierFlagShift) out |= 0x1;
  if (mask & NSEventModifierFlagControl) out |= 0x2;
  if (mask & NSEventModifierFlagOption) out |= 0x4;
  if (mask & NSEventModifierFlagCommand) out |= 0x8;
  return out;
}

/// `1` when the item has a native selector (predefined role), `0` for a channel-backed item.
int zts_menu_item_has_role(void *raw_menu, size_t index) {
  NSMenuItem *item = zts_item_at(raw_menu, index);
  if (item == nil) return -1;
  return [item action] == @selector(ztsActivate:) ? 0 : 1;
}

int zts_menu_item_tag(void *raw_menu, size_t index) {
  NSMenuItem *item = zts_item_at(raw_menu, index);
  return item != nil ? (int)[item tag] : -1;
}

/// The `NSMenu *` of the submenu at `index` (NULL when the item has none).
void *zts_menu_submenu_at(void *raw_menu, size_t index) {
  NSMenuItem *item = zts_item_at(raw_menu, index);
  if (item == nil) return NULL;
  return (__bridge void *)[item submenu];
}

/// Performs the item whose `tag == command` (tests, and hosts that route their own shortcuts).
/// Returns 1 when an item was found and dispatched.
int zts_menu_fire(void *raw, uint16_t command) {
  if (raw == NULL) return 0;
  ZtsMenuHandle *handle = (__bridge ZtsMenuHandle *)raw;

  NSMutableArray<NSMenu *> *queue = [NSMutableArray arrayWithObject:handle.root];
  while ([queue count] > 0) {
    NSMenu *menu = [queue objectAtIndex:0];
    [queue removeObjectAtIndex:0];
    for (NSMenuItem *item in [menu itemArray]) {
      if ([item tag] == (NSInteger)command) {
        NSMenuItem *found = item;
        return [NSApp sendAction:found.action to:found.target from:found] ? 1 : 0;
      }
      if ([item submenu] != nil) [queue addObject:[item submenu]];
    }
  }
  return 0;
}
