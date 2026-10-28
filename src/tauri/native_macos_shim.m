// Z-Ts `M4-01`: native dialog & clipboard backend for macOS (`NSOpenPanel` / `NSSavePanel` /
// `NSAlert` / `NSPasteboard`), exposed as a Flat C ABI so the Zig side never needs `@cImport`.
//
// Column-by-column this mirrors what upstream `tauri-plugin-dialog` does through `rfd`:
// `NSOpenPanel`, `canChooseDirectories`, `allowsMultipleSelection`, `allowedContentTypes`,
// and `NSAlert` with up to three custom-titled buttons.
//
// Every function returns a `malloc`'d UTF-8 C string owned by the caller (free with
// `zts_native_free`), or NULL where noted.

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------- helpers

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

void zts_native_free(void *ptr) {
  if (ptr != NULL) free(ptr);
}

/// Splits a `\n`-separated extension list into `UTType`s. Unknown extensions are skipped (macOS
/// refuses to run a panel whose allowed types are all invalid).
static NSArray *zts_types_from_extensions(const char *ext_csv) {
  if (ext_csv == NULL || *ext_csv == '\0') return nil;
  NSMutableArray *types = [NSMutableArray array];
  NSString *raw = [NSString stringWithUTF8String:ext_csv];
  for (NSString *ext in [raw componentsSeparatedByString:@","]) {
    NSString *trimmed = [ext stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];
    if ([trimmed length] == 0 || [trimmed isEqualToString:@"*"]) continue;
    UTType *type = [UTType typeWithFilenameExtension:trimmed];
    if (type == nil || ![type isDeclared]) continue;
    [types addObject:type];
  }
  return [types count] > 0 ? types : nil;
}

/// Brings the app far enough forward that a modal panel is actually usable from a headless
/// process launched without a bundle (CI runners start the test binary directly).
static void zts_prepare_app(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  }
}

// ---------------------------------------------------------------- dialogs

/// `mode`: 0 = open file(s), 1 = open folder(s), 2 = save.
/// Returns a JSON array of selected paths, `null` when cancelled, or `{"error":"..."}`.
char *zts_native_dialog_run(int mode,
                            const char *title,
                            const char *default_path,
                            const char *extensions,
                            int multiple,
                            int can_create_directories) {
  __block char *result = NULL;
  zts_prepare_app();

  // AppKit panels must be driven from the main thread.
  void (^work)(void) = ^{
    @autoreleasepool {
      NSString *title_str = title != NULL ? [NSString stringWithUTF8String:title] : nil;
      NSArray *types = zts_types_from_extensions(extensions);

      if (mode == 2) {
        NSSavePanel *panel = [NSSavePanel savePanel];
        if (title_str != nil) [panel setTitle:title_str];
        if (types != nil) [panel setAllowedContentTypes:types];
        if (can_create_directories) [panel setCanCreateDirectories:YES];
        if (default_path != NULL && *default_path != '\0') {
          NSString *p = [NSString stringWithUTF8String:default_path];
          NSString *dir = [p stringByDeletingLastPathComponent];
          NSString *name = [p lastPathComponent];
          if ([dir length] > 0) [panel setDirectoryURL:[NSURL fileURLWithPath:dir]];
          if ([name length] > 0) [panel setNameFieldStringValue:name];
        }
        NSModalResponse response = [panel runModal];
        if (response != NSModalResponseOK) {
          result = zts_strdup(@"null");
          return;
        }
        NSURL *url = [panel URL];
        if (url == nil) {
          result = zts_strdup(@"null");
          return;
        }
        NSMutableArray *paths = [NSMutableArray arrayWithObject:[url path]];
        NSData *json = [NSJSONSerialization dataWithJSONObject:paths options:0 error:NULL];
        result = zts_strdup([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
        return;
      }

      NSOpenPanel *panel = [NSOpenPanel openPanel];
      if (title_str != nil) [panel setTitle:title_str];
      [panel setCanChooseFiles:(mode == 0)];
      [panel setCanChooseDirectories:(mode == 1)];
      [panel setAllowsMultipleSelection:multiple ? YES : NO];
      if (mode == 0 && types != nil) [panel setAllowedContentTypes:types];
      if (default_path != NULL && *default_path != '\0') {
        [panel setDirectoryURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:default_path]]];
      }

      NSModalResponse response = [panel runModal];
      if (response != NSModalResponseOK || [[panel URLs] count] == 0) {
        result = zts_strdup(@"null");
        return;
      }
      NSMutableArray *paths = [NSMutableArray array];
      for (NSURL *url in [panel URLs]) {
        if ([url path] != nil) [paths addObject:[url path]];
      }
      NSData *json = [NSJSONSerialization dataWithJSONObject:paths options:0 error:NULL];
      result = zts_strdup([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
    }
  };

  if ([NSThread isMainThread]) {
    work();
  } else {
    dispatch_sync(dispatch_get_main_queue(), work);
  }
  return result;
}

/// `kind`: 0 = info, 1 = warning, 2 = error.
/// `labels` is a UTF-8 `\n`-separated list of button titles (1..3 entries).
/// Returns the index of the pressed button (0-based) or -1 when dismissed.
int zts_native_dialog_message(const char *title,
                              const char *message,
                              int kind,
                              const char *labels) {
  __block int chosen = -1;
  zts_prepare_app();

  void (^work)(void) = ^{
    @autoreleasepool {
      NSAlert *alert = [[NSAlert alloc] init];
      [alert setMessageText:(title != NULL && *title != '\0')
                                ? [NSString stringWithUTF8String:title]
                                : @"Z-Ts"];
      [alert setInformativeText:(message != NULL ? [NSString stringWithUTF8String:message] : @"")];
      switch (kind) {
        case 1:
          [alert setAlertStyle:NSAlertStyleWarning];
          break;
        case 2:
          [alert setAlertStyle:NSAlertStyleCritical];
          break;
        default:
          [alert setAlertStyle:NSAlertStyleInformational];
          break;
      }

      NSMutableArray<NSString *> *titles = [NSMutableArray array];
      NSString *all = (labels != NULL) ? [NSString stringWithUTF8String:labels] : @"Ok";
      for (NSString *label in [all componentsSeparatedByString:@"\n"]) {
        [titles addObject:label];
      }
      for (NSString *label in titles) {
        [alert addButtonWithTitle:label];
      }
      // `NSAlert` labels the 1st button as the default (return) key already.
      NSModalResponse response = [alert runModal];
      NSInteger first = NSAlertFirstButtonReturn;
      chosen = (int)(response - first);
      if (chosen < 0 || chosen >= (int)[titles count]) chosen = -1;
    }
  };

  if ([NSThread isMainThread]) {
    work();
  } else {
    dispatch_sync(dispatch_get_main_queue(), work);
  }
  return chosen;
}

// ---------------------------------------------------------------- clipboard

int zts_native_clipboard_write_text(const char *text) {
  @autoreleasepool {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    NSString *s = text != NULL ? [NSString stringWithUTF8String:text] : @"";
    return [pb setString:s forType:NSPasteboardTypeString] ? 0 : -1;
  }
}

char *zts_native_clipboard_read_text(void) {
  @autoreleasepool {
    NSString *s = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    return zts_strdup(s != nil ? s : @"");
  }
}

int zts_native_clipboard_write_html(const char *html, const char *alt_text) {
  @autoreleasepool {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    if (html != NULL) {
      NSString *markup = [NSString stringWithUTF8String:html];
      [pb setString:markup forType:NSPasteboardTypeHTML];
    }
    if (alt_text != NULL) {
      [pb setString:[NSString stringWithUTF8String:alt_text] forType:NSPasteboardTypeString];
    }
    return 0;
  }
}

char *zts_native_clipboard_read_html(void) {
  @autoreleasepool {
    NSString *s = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeHTML];
    return zts_strdup(s != nil ? s : @"");
  }
}

void zts_native_clipboard_clear(void) {
  @autoreleasepool {
    [[NSPasteboard generalPasteboard] clearContents];
  }
}

/// Same payload as `write_text`, but flagged as concealed so clipboard history managers skip it.
int zts_native_clipboard_write_secret(const char *text) {
  @autoreleasepool {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    NSString *s = text != NULL ? [NSString stringWithUTF8String:text] : @"";
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:s forType:NSPasteboardTypeString];
    // Convention honoured by clipboard-history managers (Alfred, Raycast, Maccy, ...).
    [item setString:@"" forType:@"org.nspasteboard.ConcealedType"];
    return [pb writeObjects:@[ item ]] ? 0 : -1;
  }
}
