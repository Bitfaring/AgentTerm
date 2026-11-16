// The browser of the Mac app (#76), on the C API of the Chromium Embedded
// Framework. The framework is loaded when the first browser is wanted, from
// the app's Frameworks folder, and its functions are looked up by name: the
// app is never linked with it, which CEF asks for on macOS.
//
// Reference counting follows CEF's C API: a struct a callback receives
// carries a reference for it, which the callback releases unless it keeps
// the struct; a struct of ours given to CEF is given with a reference CEF
// releases. Everything here runs on the main thread, which is CEF's UI
// thread with an external message pump.

#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <libgen.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <stdatomic.h>

#include "AgentTermCEF.h"

#if __has_include("include/capi/cef_app_capi.h")
#define ATC_HAS_CEF 1
#include "include/cef_api_hash.h"
#include "include/cef_version.h"

int atc_chrome_major(void) { return CHROME_VERSION_MAJOR; }
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_devtools_message_observer_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_find_handler_capi.h"
#include "include/capi/cef_focus_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_permission_handler_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/cef_sandbox_mac.h"
#else
#define ATC_HAS_CEF 0
#endif

int atc_built_with_cef(void) { return ATC_HAS_CEF; }

static void atc_say(char *error, size_t size, NSString *text) {
    if (error && size > 0) strlcpy(error, text.UTF8String ?: "", size);
}

#if ATC_HAS_CEF

// MARK: The framework's functions

#define ATC_FUNCTIONS(X)                     \
    X(cef_api_hash)                          \
    X(cef_initialize)                        \
    X(cef_shutdown)                          \
    X(cef_do_message_loop_work)              \
    X(cef_execute_process)                   \
    X(cef_browser_host_create_browser_sync)  \
    X(cef_request_context_create_context)    \
    X(cef_string_userfree_utf16_free)        \
    X(cef_string_list_size)                  \
    X(cef_string_list_value)                 \
    X(cef_string_utf16_clear)

#define ATC_POINTER(name) static __typeof__(&name) p_##name;
ATC_FUNCTIONS(ATC_POINTER)

static void *g_library;

/// Loads the framework at `path` and looks its functions up. Returns nil
/// when that worked, or what went wrong.
static NSString *atc_load_library(const char *path) {
    if (g_library) return nil;
    void *library = dlopen(path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
    if (!library) return [NSString stringWithFormat:@"Chromium could not be loaded: %s", dlerror() ?: "unknown"];
#define ATC_LOOKUP(name)                                                                       \
    p_##name = (__typeof__(&name))dlsym(library, #name);                                        \
    if (!p_##name) {                                                                            \
        dlclose(library);                                                                      \
        return [NSString stringWithFormat:@"Chromium is not the version this app was built for: it has no %s.", #name]; \
    }
    ATC_FUNCTIONS(ATC_LOOKUP)
    g_library = library;
    // Says which version of the API this side was built for: CEF answers
    // in it from then on.
    p_cef_api_hash(CEF_API_VERSION, 0);
    return nil;
}

// MARK: Strings

/// A string of CEF's, set to `text`, and freed with `atc_clear`.
static void atc_set(cef_string_t *string, const char *text) {
    memset(string, 0, sizeof(*string));
    if (!text) return;
    NSString *value = [NSString stringWithUTF8String:text] ?: @"";
    NSUInteger length = value.length;
    char16_t *buffer = calloc(length + 1, sizeof(char16_t));
    [value getCharacters:(unichar *)buffer range:NSMakeRange(0, length)];
    string->str = buffer;
    string->length = length;
    string->dtor = (void (*)(char16_t *))free;
}

static void atc_clear(cef_string_t *string) {
    if (string->dtor && string->str) string->dtor(string->str);
    memset(string, 0, sizeof(*string));
}

static NSString *atc_text(const cef_string_t *string) {
    if (!string || !string->str) return @"";
    return [NSString stringWithCharacters:(const unichar *)string->str length:string->length];
}

static NSString *atc_take(cef_string_userfree_t string) {
    if (!string) return @"";
    NSString *text = atc_text(string);
    p_cef_string_userfree_utf16_free(string);
    return text;
}

#define ATC_RELEASE(object) \
    do { if (object) (object)->base.release((cef_base_ref_counted_t *)(object)); } while (0)

// MARK: Our structs, counted

/// Every struct of ours starts with CEF's own and is followed by its count.
/// None is freed: there are a few of each, made once.
typedef struct {
    atomic_int count;
} atc_count;

#define ATC_COUNTED(type, name)                                                                     \
    typedef struct {                                                                                \
        type value;                                                                                 \
        atc_count count;                                                                            \
    } name;                                                                                         \
    static void CEF_CALLBACK name##_add_ref(cef_base_ref_counted_t *self) {                         \
        atomic_fetch_add(&((name *)self)->count.count, 1);                                          \
    }                                                                                               \
    static int CEF_CALLBACK name##_release(cef_base_ref_counted_t *self) {                          \
        return atomic_fetch_sub(&((name *)self)->count.count, 1) == 1;                              \
    }                                                                                               \
    static int CEF_CALLBACK name##_has_one_ref(cef_base_ref_counted_t *self) {                      \
        return atomic_load(&((name *)self)->count.count) == 1;                                      \
    }                                                                                               \
    static int CEF_CALLBACK name##_has_at_least_one_ref(cef_base_ref_counted_t *self) {             \
        return atomic_load(&((name *)self)->count.count) >= 1;                                      \
    }                                                                                               \
    static name *name##_new(void) {                                                                 \
        name *object = calloc(1, sizeof(name));                                                     \
        object->value.base.size = sizeof(type);                                                     \
        object->value.base.add_ref = name##_add_ref;                                                \
        object->value.base.release = name##_release;                                                \
        object->value.base.has_one_ref = name##_has_one_ref;                                        \
        object->value.base.has_at_least_one_ref = name##_has_at_least_one_ref;                      \
        atomic_store(&object->count.count, 1);                                                      \
        return object;                                                                              \
    }

ATC_COUNTED(cef_app_t, atc_app)
ATC_COUNTED(cef_browser_process_handler_t, atc_process_handler)
ATC_COUNTED(cef_client_t, atc_client)
ATC_COUNTED(cef_life_span_handler_t, atc_life_span)
ATC_COUNTED(cef_display_handler_t, atc_display)
ATC_COUNTED(cef_load_handler_t, atc_load_handler)
ATC_COUNTED(cef_request_handler_t, atc_request)
ATC_COUNTED(cef_download_handler_t, atc_downloads)
ATC_COUNTED(cef_permission_handler_t, atc_permissions)
ATC_COUNTED(cef_find_handler_t, atc_finder)
ATC_COUNTED(cef_focus_handler_t, atc_focus_handler)
ATC_COUNTED(cef_dev_tools_message_observer_t, atc_observer)

/// Hands a struct of ours to CEF, which releases what it is given.
#define ATC_GIVE(object) ((object)->value.base.add_ref(&(object)->value.base), &(object)->value)

// MARK: State

static atc_event_fn g_events;
static void *g_context;
static int g_started;
static NSString *g_downloads;
static atc_app *g_app;
static atc_process_handler *g_process;
static atc_client *g_client;
static atc_life_span *g_life_span;
static atc_display *g_display;
static atc_load_handler *g_loader;
static atc_request *g_request;
static atc_downloads *g_download_handler;
static atc_permissions *g_permission_handler;
static atc_finder *g_finder;
static atc_focus_handler *g_focus;
static atc_observer *g_observer;

/// A browser that is open, by CEF's id for it.
@interface ATCBrowser : NSObject
@property(nonatomic) cef_browser_t *browser;
@property(nonatomic) cef_registration_t *devtools;
@end
@implementation ATCBrowser
@end

static NSMutableDictionary<NSNumber *, ATCBrowser *> *g_browsers;
/// Request contexts, one for each profile's folder.
static NSMutableDictionary<NSString *, NSValue *> *g_contexts;
/// What a prompt for a permission waits on, by the number Swift answers with.
static NSMutableDictionary<NSNumber *, NSValue *> *g_prompts;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_prompt_kinds;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_prompt_asked;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_prompt_ids;
static int g_next_prompt = 1;
/// What a download can be cancelled with, by its id.
static NSMutableDictionary<NSNumber *, NSValue *> *g_downloads_running;

static void atc_emit(atc_event event) {
    if (g_events) g_events(g_context, &event);
}

static int atc_id(cef_browser_t *browser) { return browser ? browser->get_identifier(browser) : 0; }

static void atc_emit_text(atc_event_kind kind, cef_browser_t *browser, NSString *text, NSString *text2, int a, int b, int c) {
    atc_event event = {kind, atc_id(browser), a, b, c, text.UTF8String, text2.UTF8String, 0};
    atc_emit(event);
}

// MARK: The message pump

static CFRunLoopTimerRef g_timer;
static int g_working;
/// At most this long between two turns of CEF's work, as cefclient does.
static const double kMaxDelay = 1.0 / 30.0;

static void atc_schedule(double seconds);

static void atc_work(void) {
    if (!g_started || g_working) {
        if (g_started) atc_schedule(0);
        return;
    }
    g_working = 1;
    p_cef_do_message_loop_work();
    g_working = 0;
    if (!g_timer || !CFRunLoopTimerIsValid(g_timer)) atc_schedule(kMaxDelay);
}

static void atc_timer_fired(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    (void)info;
    if (g_timer) {
        CFRunLoopTimerInvalidate(g_timer);
        CFRelease(g_timer);
        g_timer = NULL;
    }
    atc_work();
}

/// Has CEF do its work after `seconds`, on the main run loop in every mode,
/// so that it goes on while a menu is open or the window is resized.
static void atc_schedule(double seconds) {
    if (seconds > kMaxDelay) seconds = kMaxDelay;
    if (seconds < 0) seconds = 0;
    CFAbsoluteTime when = CFAbsoluteTimeGetCurrent() + seconds;
    if (g_timer) {
        if (CFRunLoopTimerGetNextFireDate(g_timer) <= when) return;
        CFRunLoopTimerInvalidate(g_timer);
        CFRelease(g_timer);
    }
    g_timer = CFRunLoopTimerCreate(NULL, when, 0, 0, 0, atc_timer_fired, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), g_timer, kCFRunLoopCommonModes);
}

static void CEF_CALLBACK on_schedule_message_pump_work(cef_browser_process_handler_t *self, int64_t delay_ms) {
    (void)self;
    double seconds = (double)delay_ms / 1000.0;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (g_started) atc_schedule(seconds);
    });
}

static void CEF_CALLBACK on_context_initialized(cef_browser_process_handler_t *self) {
    (void)self;
    atc_event event = {ATC_EVENT_READY, 0, 0, 0, 0, NULL, NULL, 0};
    atc_emit(event);
}

static cef_browser_process_handler_t *CEF_CALLBACK get_browser_process_handler(cef_app_t *self) {
    (void)self;
    return ATC_GIVE(g_process);
}

static int g_mock_keychain;

static void atc_append_switch(cef_command_line_t *command_line, const char *name) {
    cef_string_t value;
    atc_set(&value, name);
    command_line->append_switch(command_line, &value);
    atc_clear(&value);
}

static void CEF_CALLBACK on_before_command_line_processing(cef_app_t *self, const cef_string_t *process_type, cef_command_line_t *command_line) {
    (void)self;
    // The browser's own process: the one with no type.
    if (!process_type || process_type->length == 0) {
        if (g_mock_keychain) atc_append_switch(command_line, "use-mock-keychain");
    }
    ATC_RELEASE(command_line);
}

// MARK: The client and its handlers

#define ATC_GETTER(name, type, object)                                \
    static type *CEF_CALLBACK name(cef_client_t *self) {             \
        (void)self;                                                  \
        return ATC_GIVE(object);                                     \
    }
ATC_GETTER(get_life_span_handler, cef_life_span_handler_t, g_life_span)
ATC_GETTER(get_display_handler, cef_display_handler_t, g_display)
ATC_GETTER(get_load_handler, cef_load_handler_t, g_loader)
ATC_GETTER(get_request_handler, cef_request_handler_t, g_request)
ATC_GETTER(get_download_handler, cef_download_handler_t, g_download_handler)
ATC_GETTER(get_permission_handler, cef_permission_handler_t, g_permission_handler)
ATC_GETTER(get_find_handler, cef_find_handler_t, g_finder)
ATC_GETTER(get_focus_handler, cef_focus_handler_t, g_focus)

static int CEF_CALLBACK on_before_popup(cef_life_span_handler_t *self, cef_browser_t *browser, cef_frame_t *frame, int popup_id,
                                        const cef_string_t *target_url, const cef_string_t *target_frame_name,
                                        cef_window_open_disposition_t disposition, int user_gesture, const cef_popup_features_t *features,
                                        cef_window_info_t *window_info, cef_client_t **client, cef_browser_settings_t *settings,
                                        cef_dictionary_value_t **extra_info, int *no_javascript_access) {
    (void)self, (void)popup_id, (void)target_frame_name, (void)disposition, (void)user_gesture, (void)features;
    (void)window_info, (void)client, (void)settings, (void)extra_info, (void)no_javascript_access;
    // A page that opens a window gets a tab of the app instead.
    atc_emit_text(ATC_EVENT_POPUP, browser, atc_text(target_url), nil, 0, 0, 0);
    ATC_RELEASE(frame);
    ATC_RELEASE(browser);
    return 1;
}

static void CEF_CALLBACK on_after_created(cef_life_span_handler_t *self, cef_browser_t *browser) {
    (void)self;
    atc_emit_text(ATC_EVENT_CREATED, browser, nil, nil, 0, 0, 0);
    ATC_RELEASE(browser);
}

static int CEF_CALLBACK do_close(cef_life_span_handler_t *self, cef_browser_t *browser) {
    (void)self;
    // Handled here: 0 would have CEF send `performClose:` to the window the
    // page is in, which is the app's own window (seen with CEF 156). CEF
    // then destroys the browser once its view is gone, and not before: its
    // page's process kept running, its memory held, for as long as the view
    // stayed in the app's (#109). It is taken out here.
    cef_browser_host_t *host = browser->get_host(browser);
    if (host) {
        NSView *view = (__bridge NSView *)host->get_window_handle(host);
        [view removeFromSuperview];
        ATC_RELEASE(host);
    }
    ATC_RELEASE(browser);
    return 1;
}

static void CEF_CALLBACK on_before_close(cef_life_span_handler_t *self, cef_browser_t *browser) {
    (void)self;
    int identifier = atc_id(browser);
    ATCBrowser *open = g_browsers[@(identifier)];
    if (open) {
        ATC_RELEASE(open.devtools);
        ATC_RELEASE(open.browser);
        [g_browsers removeObjectForKey:@(identifier)];
    }
    atc_event event = {ATC_EVENT_CLOSED, identifier, 0, 0, 0, NULL, NULL, 0};
    atc_emit(event);
    ATC_RELEASE(browser);
}

static void CEF_CALLBACK on_address_change(cef_display_handler_t *self, cef_browser_t *browser, cef_frame_t *frame, const cef_string_t *url) {
    (void)self;
    if (frame && frame->is_main(frame)) atc_emit_text(ATC_EVENT_ADDRESS, browser, atc_text(url), nil, 0, 0, 0);
    ATC_RELEASE(frame);
    ATC_RELEASE(browser);
}

static void CEF_CALLBACK on_title_change(cef_display_handler_t *self, cef_browser_t *browser, const cef_string_t *title) {
    (void)self;
    atc_emit_text(ATC_EVENT_TITLE, browser, atc_text(title), nil, 0, 0, 0);
    ATC_RELEASE(browser);
}

static void CEF_CALLBACK on_favicon_urlchange(cef_display_handler_t *self, cef_browser_t *browser, cef_string_list_t icon_urls) {
    (void)self;
    if (icon_urls && p_cef_string_list_size(icon_urls) > 0) {
        cef_string_t value = {0};
        if (p_cef_string_list_value(icon_urls, 0, &value)) {
            atc_emit_text(ATC_EVENT_FAVICON, browser, atc_text(&value), nil, 0, 0, 0);
            p_cef_string_utf16_clear(&value);
        }
    }
    ATC_RELEASE(browser);
}

static void CEF_CALLBACK on_loading_progress_change(cef_display_handler_t *self, cef_browser_t *browser, double progress) {
    (void)self;
    atc_emit_text(ATC_EVENT_PROGRESS, browser, nil, nil, (int)(progress * 1000), 0, 0);
    ATC_RELEASE(browser);
}

static void CEF_CALLBACK on_loading_state_change(cef_load_handler_t *self, cef_browser_t *browser, int loading, int back, int forward) {
    (void)self;
    atc_emit_text(ATC_EVENT_LOADING, browser, nil, nil, loading, back, forward);
    ATC_RELEASE(browser);
}

static void CEF_CALLBACK on_load_error(cef_load_handler_t *self, cef_browser_t *browser, cef_frame_t *frame, cef_errorcode_t code,
                                       const cef_string_t *text, const cef_string_t *url) {
    (void)self;
    // A page that was left before it loaded is not an error to tell of.
    if (frame && frame->is_main(frame) && code != ERR_ABORTED) {
        atc_emit_text(ATC_EVENT_LOAD_ERROR, browser, atc_text(text), atc_text(url), (int)code, 0, 0);
    }
    ATC_RELEASE(frame);
    ATC_RELEASE(browser);
}

static void CEF_CALLBACK on_render_process_terminated(cef_request_handler_t *self, cef_browser_t *browser, cef_termination_status_t status,
                                                      int error_code, const cef_string_t *error_string) {
    (void)self;
    atc_emit_text(ATC_EVENT_CRASHED, browser, atc_text(error_string), nil, (int)status, error_code, 0);
    ATC_RELEASE(browser);
}

static int CEF_CALLBACK can_download(cef_download_handler_t *self, cef_browser_t *browser, const cef_string_t *url, const cef_string_t *method) {
    (void)self, (void)url, (void)method;
    ATC_RELEASE(browser);
    return 1;
}

/// A path in the downloads folder that is not taken: "name 2.ext" after "name.ext".
static NSString *atc_free_path(NSString *name) {
    if (name.length == 0) name = @"download";
    name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSString *path = [g_downloads stringByAppendingPathComponent:name];
    NSFileManager *files = NSFileManager.defaultManager;
    for (int number = 2; [files fileExistsAtPath:path] && number < 10000; number++) {
        NSString *stem = name.stringByDeletingPathExtension, *extension = name.pathExtension;
        NSString *numbered = [NSString stringWithFormat:@"%@ %d", stem, number];
        if (extension.length) numbered = [numbered stringByAppendingPathExtension:extension];
        path = [g_downloads stringByAppendingPathComponent:numbered];
    }
    return path;
}

static int CEF_CALLBACK on_before_download(cef_download_handler_t *self, cef_browser_t *browser, cef_download_item_t *item,
                                           const cef_string_t *suggested_name, cef_before_download_callback_t *callback) {
    (void)self;
    [NSFileManager.defaultManager createDirectoryAtPath:g_downloads withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = atc_free_path(atc_text(suggested_name));
    cef_string_t target;
    atc_set(&target, path.UTF8String);
    callback->cont(callback, &target, 0);
    atc_clear(&target);
    atc_emit_text(ATC_EVENT_DOWNLOAD, browser, path, atc_take(item->get_url(item)), (int)item->get_id(item), 0, 0);
    ATC_RELEASE(callback);
    ATC_RELEASE(item);
    ATC_RELEASE(browser);
    return 1;
}

static void CEF_CALLBACK on_download_updated(cef_download_handler_t *self, cef_browser_t *browser, cef_download_item_t *item,
                                             cef_download_item_callback_t *callback) {
    (void)self;
    int identifier = (int)item->get_id(item);
    int finished = item->is_complete(item) ? 1 : (item->is_canceled(item) || item->is_interrupted(item)) ? 2 : 0;
    NSNumber *key = @(identifier);
    NSValue *kept = g_downloads_running[key];
    if (finished) {
        if (kept) ATC_RELEASE((cef_download_item_callback_t *)kept.pointerValue);
        [g_downloads_running removeObjectForKey:key];
        ATC_RELEASE(callback);
    } else if (!kept) {
        g_downloads_running[key] = [NSValue valueWithPointer:callback];
    } else {
        ATC_RELEASE(callback);
    }
    NSString *path = atc_take(item->get_full_path(item));
    atc_emit_text(ATC_EVENT_DOWNLOAD, browser, path, atc_take(item->get_url(item)), identifier, item->get_percent_complete(item), finished);
    ATC_RELEASE(item);
    ATC_RELEASE(browser);
}

/// Keeps what a prompt waits on, and returns the number it is told by.
static int atc_keep_prompt(void *callback, int kind, uint32_t asked, uint64_t prompt_id) {
    int number = g_next_prompt++;
    g_prompts[@(number)] = [NSValue valueWithPointer:callback];
    g_prompt_kinds[@(number)] = @(kind);
    g_prompt_asked[@(number)] = @(asked);
    g_prompt_ids[@(number)] = @(prompt_id);
    return number;
}

static int CEF_CALLBACK on_show_permission_prompt(cef_permission_handler_t *self, cef_browser_t *browser, uint64_t prompt_id,
                                                  const cef_string_t *origin, uint32_t permissions, cef_permission_prompt_callback_t *callback) {
    (void)self;
    int number = atc_keep_prompt(callback, 0, permissions, prompt_id);
    atc_emit_text(ATC_EVENT_PERMISSION, browser, atc_text(origin), nil, number, (int)permissions, 0);
    ATC_RELEASE(browser);
    return 1;
}

static void CEF_CALLBACK on_dismiss_permission_prompt(cef_permission_handler_t *self, cef_browser_t *browser, uint64_t prompt_id,
                                                      cef_permission_request_result_t result) {
    (void)self, (void)result;
    for (NSNumber *number in g_prompt_ids.allKeys) {
        if (g_prompt_ids[number].unsignedLongLongValue == prompt_id && g_prompt_kinds[number].intValue == 0) {
            ATC_RELEASE((cef_permission_prompt_callback_t *)g_prompts[number].pointerValue);
            [g_prompts removeObjectForKey:number];
            [g_prompt_ids removeObjectForKey:number];
            atc_emit_text(ATC_EVENT_PERMISSION, browser, nil, nil, number.intValue, -1, 0);
        }
    }
    ATC_RELEASE(browser);
}

static int CEF_CALLBACK on_request_media_access_permission(cef_permission_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                                           const cef_string_t *origin, uint32_t permissions, cef_media_access_callback_t *callback) {
    (void)self;
    int number = atc_keep_prompt(callback, 1, permissions, 0);
    // Media is told apart by the high bit.
    atc_emit_text(ATC_EVENT_PERMISSION, browser, atc_text(origin), nil, number, (int)(permissions | 0x40000000u), 0);
    ATC_RELEASE(frame);
    ATC_RELEASE(browser);
    return 1;
}

static void CEF_CALLBACK on_find_result(cef_find_handler_t *self, cef_browser_t *browser, int identifier, int count, const cef_rect_t *rect,
                                        int active, int final_update) {
    (void)self, (void)identifier, (void)rect;
    atc_emit_text(ATC_EVENT_FIND, browser, nil, nil, count, active, final_update);
    ATC_RELEASE(browser);
}

static void CEF_CALLBACK on_got_focus(cef_focus_handler_t *self, cef_browser_t *browser) {
    (void)self;
    atc_emit_text(ATC_EVENT_FOCUS, browser, nil, nil, 0, 0, 0);
    ATC_RELEASE(browser);
}

static int CEF_CALLBACK on_set_focus(cef_focus_handler_t *self, cef_browser_t *browser, cef_focus_source_t source) {
    (void)self, (void)source;
    ATC_RELEASE(browser);
    return 0;
}

static void CEF_CALLBACK on_take_focus(cef_focus_handler_t *self, cef_browser_t *browser, int next) {
    (void)self, (void)next;
    ATC_RELEASE(browser);
}

static int CEF_CALLBACK on_dev_tools_message(cef_dev_tools_message_observer_t *self, cef_browser_t *browser, const void *message, size_t size) {
    (void)self, (void)message, (void)size;
    ATC_RELEASE(browser);
    // Left to CEF, which answers with the two below.
    return 0;
}

static void CEF_CALLBACK on_dev_tools_method_result(cef_dev_tools_message_observer_t *self, cef_browser_t *browser, int message_id, int success,
                                                    const void *result, size_t size) {
    (void)self;
    atc_event event = {ATC_EVENT_DEVTOOLS_RESULT, atc_id(browser), message_id, success, 0, (const char *)result, NULL, size};
    atc_emit(event);
    ATC_RELEASE(browser);
}

static void CEF_CALLBACK on_dev_tools_event(cef_dev_tools_message_observer_t *self, cef_browser_t *browser, const cef_string_t *method,
                                            const void *params, size_t size) {
    (void)self;
    NSString *name = atc_text(method);
    atc_event event = {ATC_EVENT_DEVTOOLS_EVENT, atc_id(browser), 0, 0, 0, name.UTF8String, (const char *)params, size};
    atc_emit(event);
    ATC_RELEASE(browser);
}

static void CEF_CALLBACK on_dev_tools_agent(cef_dev_tools_message_observer_t *self, cef_browser_t *browser) {
    (void)self;
    ATC_RELEASE(browser);
}

static void atc_make_handlers(void) {
    g_app = atc_app_new();
    g_app->value.get_browser_process_handler = get_browser_process_handler;
    g_app->value.on_before_command_line_processing = on_before_command_line_processing;
    g_process = atc_process_handler_new();
    g_process->value.on_schedule_message_pump_work = on_schedule_message_pump_work;
    g_process->value.on_context_initialized = on_context_initialized;
    g_client = atc_client_new();
    g_client->value.get_life_span_handler = get_life_span_handler;
    g_client->value.get_display_handler = get_display_handler;
    g_client->value.get_load_handler = get_load_handler;
    g_client->value.get_request_handler = get_request_handler;
    g_client->value.get_download_handler = get_download_handler;
    g_client->value.get_permission_handler = get_permission_handler;
    g_client->value.get_find_handler = get_find_handler;
    g_client->value.get_focus_handler = get_focus_handler;
    g_life_span = atc_life_span_new();
    g_life_span->value.on_before_popup = on_before_popup;
    g_life_span->value.on_after_created = on_after_created;
    g_life_span->value.do_close = do_close;
    g_life_span->value.on_before_close = on_before_close;
    g_display = atc_display_new();
    g_display->value.on_address_change = on_address_change;
    g_display->value.on_title_change = on_title_change;
    g_display->value.on_favicon_urlchange = on_favicon_urlchange;
    g_display->value.on_loading_progress_change = on_loading_progress_change;
    g_loader = atc_load_handler_new();
    g_loader->value.on_loading_state_change = on_loading_state_change;
    g_loader->value.on_load_error = on_load_error;
    g_request = atc_request_new();
    g_request->value.on_render_process_terminated = on_render_process_terminated;
    g_download_handler = atc_downloads_new();
    g_download_handler->value.can_download = can_download;
    g_download_handler->value.on_before_download = on_before_download;
    g_download_handler->value.on_download_updated = on_download_updated;
    g_permission_handler = atc_permissions_new();
    g_permission_handler->value.on_show_permission_prompt = on_show_permission_prompt;
    g_permission_handler->value.on_dismiss_permission_prompt = on_dismiss_permission_prompt;
    g_permission_handler->value.on_request_media_access_permission = on_request_media_access_permission;
    g_finder = atc_finder_new();
    g_finder->value.on_find_result = on_find_result;
    g_focus = atc_focus_handler_new();
    g_focus->value.on_got_focus = on_got_focus;
    g_focus->value.on_set_focus = on_set_focus;
    g_focus->value.on_take_focus = on_take_focus;
    g_observer = atc_observer_new();
    g_observer->value.on_dev_tools_message = on_dev_tools_message;
    g_observer->value.on_dev_tools_method_result = on_dev_tools_method_result;
    g_observer->value.on_dev_tools_event = on_dev_tools_event;
    g_observer->value.on_dev_tools_agent_attached = on_dev_tools_agent;
    g_observer->value.on_dev_tools_agent_detached = on_dev_tools_agent;
}

// MARK: The application, as Chromium wants it

// Chromium asks the application whether it is in the middle of sending an
// event, and tells it when it is. Its protocols are matched by name.
@protocol CrAppProtocol
- (BOOL)isHandlingSendEvent;
@end
@protocol CrAppControlProtocol <CrAppProtocol>
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent;
@end
@protocol CefAppProtocol <CrAppControlProtocol>
@end

static BOOL g_handling_send_event;
static IMP g_send_event;

static BOOL atc_is_handling(id self, SEL _cmd) {
    (void)self, (void)_cmd;
    return g_handling_send_event;
}

static void atc_set_handling(id self, SEL _cmd, BOOL handling) {
    (void)self, (void)_cmd;
    g_handling_send_event = handling;
}

static void atc_send_event(id self, SEL _cmd, NSEvent *event) {
    BOOL was = g_handling_send_event;
    g_handling_send_event = YES;
    ((void (*)(id, SEL, NSEvent *))g_send_event)(self, _cmd, event);
    g_handling_send_event = was;
}

/// Makes the running application one Chromium accepts, by giving the
/// methods to NSApplication itself. The application's class is not
/// changed: by then key-value observing has made a class of its own for
/// it, and an object moved off that class crashes the next observer that
/// is added (seen with CEF 156: Chromium adds one to NSApp as it starts).
static void atc_adopt_application(void) {
    NSApplication *app = NSApplication.sharedApplication;
    if ([app conformsToProtocol:@protocol(CefAppProtocol)]) return;
    Class base = [NSApplication class];
    class_addProtocol(base, @protocol(CrAppProtocol));
    class_addProtocol(base, @protocol(CrAppControlProtocol));
    class_addProtocol(base, @protocol(CefAppProtocol));
    class_addMethod(base, @selector(isHandlingSendEvent), (IMP)atc_is_handling, "c@:");
    class_addMethod(base, @selector(setHandlingSendEvent:), (IMP)atc_set_handling, "v@:c");
    // NSApplication's own sendEvent:, wrapped: a subclass that overrides it
    // still reaches it through super.
    Method send = class_getInstanceMethod(base, @selector(sendEvent:));
    if (!g_send_event) g_send_event = method_setImplementation(send, (IMP)atc_send_event);
}

// MARK: Starting and stopping

int atc_start(const atc_paths *paths, atc_event_fn events, void *context, char *error, size_t error_size) {
    if (g_started) return 1;
    NSString *failed = atc_load_library(paths->framework_path ? [[NSString stringWithUTF8String:paths->framework_path] stringByAppendingPathComponent:@"Chromium Embedded Framework"].UTF8String : "");
    if (failed) {
        atc_say(error, error_size, failed);
        return 0;
    }
    g_events = events;
    g_context = context;
    g_mock_keychain = paths->mock_keychain;
    g_downloads = paths->downloads_path ? [NSString stringWithUTF8String:paths->downloads_path] : [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
    g_browsers = [NSMutableDictionary new];
    g_contexts = [NSMutableDictionary new];
    g_prompts = [NSMutableDictionary new];
    g_prompt_kinds = [NSMutableDictionary new];
    g_prompt_asked = [NSMutableDictionary new];
    g_prompt_ids = [NSMutableDictionary new];
    g_downloads_running = [NSMutableDictionary new];
    atc_make_handlers();
    atc_adopt_application();

    cef_settings_t settings;
    memset(&settings, 0, sizeof(settings));
    settings.size = sizeof(settings);
    // Chromium's own sandbox, for every page's process.
    settings.no_sandbox = 0;
    atc_set(&settings.browser_subprocess_path, paths->helper_path);
    atc_set(&settings.framework_dir_path, paths->framework_path);
    atc_set(&settings.main_bundle_path, paths->main_bundle_path);
    atc_set(&settings.root_cache_path, paths->root_cache_path);
    atc_set(&settings.log_file, paths->log_file);
    atc_set(&settings.locale, paths->locale);
    atc_set(&settings.keychain_service_name, paths->keychain_service);
    atc_set(&settings.keychain_account_name, paths->keychain_account);
    settings.external_message_pump = 1;
    settings.multi_threaded_message_loop = 0;
    settings.windowless_rendering_enabled = 0;
    settings.persist_session_cookies = 1;
    // No DevTools port: one on localhost would let any program on the Mac
    // drive the browser, signed-in pages included. Agents go through the app.
    settings.remote_debugging_port = 0;
    settings.log_severity = LOGSEVERITY_WARNING;
    settings.command_line_args_disabled = 1;
    settings.background_color = 0xFF1E1E1E;

    char *argv0 = (char *)(NSProcessInfo.processInfo.arguments.firstObject.UTF8String ?: "AgentTerm");
    char *argv[] = {argv0, NULL};
    cef_main_args_t args = {1, argv};
    int ok = p_cef_initialize(&args, &settings, ATC_GIVE(g_app), NULL);
    atc_clear(&settings.browser_subprocess_path);
    atc_clear(&settings.framework_dir_path);
    atc_clear(&settings.main_bundle_path);
    atc_clear(&settings.root_cache_path);
    atc_clear(&settings.log_file);
    atc_clear(&settings.locale);
    atc_clear(&settings.keychain_service_name);
    atc_clear(&settings.keychain_account_name);
    if (!ok) {
        atc_say(error, error_size, @"Chromium did not start. Its log may say why.");
        return 0;
    }
    g_started = 1;
    atc_schedule(0);
    return 1;
}

int atc_started(void) { return g_started; }

void atc_shutdown(void) {
    if (!g_started) return;
    for (ATCBrowser *open in g_browsers.allValues) {
        cef_browser_host_t *host = open.browser->get_host(open.browser);
        host->close_browser(host, 1);
        ATC_RELEASE(host);
    }
    // The browsers close over a few turns of CEF's work.
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:2];
    while (g_browsers.count > 0 && [until timeIntervalSinceNow] > 0) {
        p_cef_do_message_loop_work();
        usleep(10000);
    }
    if (g_timer) {
        CFRunLoopTimerInvalidate(g_timer);
        CFRelease(g_timer);
        g_timer = NULL;
    }
    g_started = 0;
    p_cef_shutdown();
}

// MARK: Browsers

/// A profile: its request context, and the browsers that wait for it to
/// open. Chromium opens a profile in the background, and a browser is made
/// in it only once it says it is open.
@interface ATCProfile : NSObject
@property(nonatomic) cef_request_context_t *context;
@property(nonatomic) BOOL open;
@property(nonatomic, strong) NSMutableArray<void (^)(void)> *waiting;
@end
@implementation ATCProfile
@end

ATC_COUNTED(cef_request_context_handler_t, atc_context_handler)
static atc_context_handler *g_context_handler;

/// The profile being made, while its context is: it may say it is open
/// before the call that makes it has returned.
static ATCProfile *g_making_profile;

static void CEF_CALLBACK on_request_context_initialized(cef_request_context_handler_t *self, cef_request_context_t *context) {
    (void)self;
    for (NSValue *value in g_contexts.allValues) {
        ATCProfile *profile = (__bridge ATCProfile *)value.pointerValue;
        if (profile.open) continue;
        BOOL same = profile.context ? profile.context->is_same(profile.context, (context->base.base.add_ref(&context->base.base), context))
                                    : profile == g_making_profile;
        if (!same) continue;
        profile.open = YES;
        NSArray *waiting = profile.waiting.copy;
        [profile.waiting removeAllObjects];
        // After this callback: a browser is not made from inside it.
        dispatch_async(dispatch_get_main_queue(), ^{
          for (void (^work)(void) in waiting) work();
        });
    }
    context->base.base.release(&context->base.base);
}

static NSMutableArray<ATCProfile *> *g_profiles;

static ATCProfile *atc_profile(const char *name, const char *cache_path) {
    NSString *key = name ? [NSString stringWithUTF8String:name] ?: @"" : @"";
    NSValue *known = g_contexts[key];
    if (known) return (__bridge ATCProfile *)known.pointerValue;
    if (!g_context_handler) {
        g_context_handler = atc_context_handler_new();
        g_context_handler->value.on_request_context_initialized = on_request_context_initialized;
        g_profiles = [NSMutableArray new];
    }
    ATCProfile *profile = [ATCProfile new];
    profile.waiting = [NSMutableArray new];
    // Kept for as long as the app runs, or, in memory, until forgotten.
    [g_profiles addObject:profile];
    g_contexts[key] = [NSValue valueWithPointer:(__bridge void *)profile];
    cef_request_context_settings_t settings;
    memset(&settings, 0, sizeof(settings));
    settings.size = sizeof(settings);
    // No folder: Chromium keeps it in memory, an "incognito" profile.
    if (cache_path && cache_path[0]) {
        atc_set(&settings.cache_path, cache_path);
        settings.persist_session_cookies = 1;
    }
    g_making_profile = profile;
    profile.context = p_cef_request_context_create_context(&settings, ATC_GIVE(g_context_handler));
    g_making_profile = nil;
    atc_clear(&settings.cache_path);
    return profile;
}

static void atc_created(int token, int browser) {
    atc_event event = {ATC_EVENT_CREATED, 0, token, browser, 0, NULL, NULL, 0};
    atc_emit(event);
}

static ATCBrowser *atc_open(int browser) { return g_browsers[@(browser)]; }

static void atc_make(NSView *view, NSString *url, ATCProfile *profile, int token) {
    cef_window_info_t info;
    memset(&info, 0, sizeof(info));
    info.size = sizeof(info);
    info.parent_view = (__bridge void *)view;
    info.bounds.width = (int)view.bounds.size.width;
    info.bounds.height = (int)view.bounds.size.height;
    // A plain view of the page; the app draws its own address bar and tabs.
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    cef_browser_settings_t settings;
    memset(&settings, 0, sizeof(settings));
    settings.size = sizeof(settings);
    settings.background_color = 0xFFFFFFFF;
    cef_string_t address;
    atc_set(&address, url.UTF8String);
    cef_request_context_t *context = profile.context;
    if (context) context->base.base.add_ref(&context->base.base);
    cef_browser_t *browser = p_cef_browser_host_create_browser_sync(&info, ATC_GIVE(g_client), &address, &settings, NULL, context);
    atc_clear(&address);
    if (!browser) return atc_created(token, 0);
    ATCBrowser *open = [ATCBrowser new];
    open.browser = browser;
    cef_browser_host_t *host = browser->get_host(browser);
    open.devtools = host->add_dev_tools_message_observer(host, ATC_GIVE(g_observer));
    NSView *page = (__bridge NSView *)host->get_window_handle(host);
    page.frame = view.bounds;
    page.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    ATC_RELEASE(host);
    int identifier = atc_id(browser);
    g_browsers[@(identifier)] = open;
    atc_created(token, identifier);
}

void atc_forget_profile(const char *name) {
    if (!name || !g_contexts) return;
    NSString *key = [NSString stringWithUTF8String:name];
    NSValue *known = key ? g_contexts[key] : nil;
    if (!known) return;
    ATCProfile *profile = (__bridge ATCProfile *)known.pointerValue;
    [g_contexts removeObjectForKey:key];
    // Its browsers hold the context while they close; then it goes.
    if (profile.context) profile.context->base.base.release(&profile.context->base.base);
    profile.context = NULL;
    [g_profiles removeObject:profile];
}

void atc_create(void *parent, const char *url, const char *key, const char *cache_path, int token) {
    if (!g_started || !parent) return atc_created(token, 0);
    NSView *view = (__bridge NSView *)parent;
    NSString *address = [NSString stringWithUTF8String:url ?: "about:blank"] ?: @"about:blank";
    ATCProfile *profile = atc_profile(key, cache_path);
    if (!profile.context) return atc_created(token, 0);
    if (profile.open) {
        atc_make(view, address, profile, token);
    } else {
        [profile.waiting addObject:^{
          atc_make(view, address, profile, token);
        }];
    }
}

#define ATC_HOST(browser, body)                                       \
    do {                                                              \
        ATCBrowser *open = atc_open(browser);                         \
        if (!open) break;                                             \
        cef_browser_host_t *host = open.browser->get_host(open.browser); \
        body;                                                         \
        ATC_RELEASE(host);                                            \
    } while (0)

void *atc_view(int browser) {
    void *view = NULL;
    ATC_HOST(browser, view = host->get_window_handle(host));
    return view;
}

void atc_close(int browser) { ATC_HOST(browser, host->close_browser(host, 1)); }

void atc_load(int browser, const char *url) {
    ATCBrowser *open = atc_open(browser);
    if (!open) return;
    cef_frame_t *frame = open.browser->get_main_frame(open.browser);
    if (!frame) return;
    cef_string_t address;
    atc_set(&address, url);
    frame->load_url(frame, &address);
    atc_clear(&address);
    ATC_RELEASE(frame);
}

void atc_back(int browser) {
    ATCBrowser *open = atc_open(browser);
    if (open) open.browser->go_back(open.browser);
}

void atc_forward(int browser) {
    ATCBrowser *open = atc_open(browser);
    if (open) open.browser->go_forward(open.browser);
}

void atc_reload(int browser, int ignore_cache) {
    ATCBrowser *open = atc_open(browser);
    if (!open) return;
    if (ignore_cache) open.browser->reload_ignore_cache(open.browser);
    else open.browser->reload(open.browser);
}

void atc_stop(int browser) {
    ATCBrowser *open = atc_open(browser);
    if (open) open.browser->stop_load(open.browser);
}

void atc_set_zoom(int browser, double level) { ATC_HOST(browser, host->set_zoom_level(host, level)); }

double atc_zoom(int browser) {
    double level = 0;
    ATC_HOST(browser, level = host->get_zoom_level(host));
    return level;
}

void atc_find(int browser, const char *text, int forward, int match_case, int find_next) {
    cef_string_t search;
    atc_set(&search, text);
    ATC_HOST(browser, host->find(host, &search, forward, match_case, find_next));
    atc_clear(&search);
}

void atc_stop_finding(int browser, int clear) { ATC_HOST(browser, host->stop_finding(host, clear)); }

void atc_focus(int browser, int focus) { ATC_HOST(browser, host->set_focus(host, focus)); }

void atc_resized(int browser) { ATC_HOST(browser, host->was_resized(host)); }

int atc_devtools(int browser, const char *json, size_t size) {
    int sent = 0;
    ATC_HOST(browser, sent = host->send_dev_tools_message(host, json, size));
    return sent;
}

void atc_show_devtools(int browser) {
    cef_window_info_t info;
    memset(&info, 0, sizeof(info));
    info.size = sizeof(info);
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    info.bounds.width = 1100;
    info.bounds.height = 760;
    cef_browser_settings_t settings;
    memset(&settings, 0, sizeof(settings));
    settings.size = sizeof(settings);
    ATC_HOST(browser, host->show_dev_tools(host, &info, NULL, &settings, NULL));
}

void atc_answer_permission(int prompt, int allow) {
    NSNumber *key = @(prompt);
    NSValue *kept = g_prompts[key];
    if (!kept) return;
    int kind = g_prompt_kinds[key].intValue;
    uint32_t asked = (uint32_t)g_prompt_asked[key].unsignedIntValue;
    // Out of the tables before CEF is answered: answering calls
    // on_dismiss_permission_prompt at once, from inside `cont`, which
    // released the callback a second time when it was still found there
    // (the app crashed on Allow, seen on 2026-11-15).
    [g_prompts removeObjectForKey:key];
    [g_prompt_kinds removeObjectForKey:key];
    [g_prompt_asked removeObjectForKey:key];
    [g_prompt_ids removeObjectForKey:key];
    if (kind == 1) {
        cef_media_access_callback_t *callback = kept.pointerValue;
        if (allow) callback->cont(callback, asked);
        else callback->cancel(callback);
        ATC_RELEASE(callback);
    } else {
        cef_permission_prompt_callback_t *callback = kept.pointerValue;
        callback->cont(callback, allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
        ATC_RELEASE(callback);
    }
}

void atc_cancel_download(int download) {
    NSValue *kept = g_downloads_running[@(download)];
    if (!kept) return;
    cef_download_item_callback_t *callback = kept.pointerValue;
    callback->cancel(callback);
}

// MARK: The helper processes

/// The folder the running program is in.
static NSString *atc_executable_folder(void) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char *path = malloc(size + 1);
    if (_NSGetExecutablePath(path, &size) != 0) {
        free(path);
        return nil;
    }
    NSString *folder = [NSString stringWithUTF8String:path].stringByDeletingLastPathComponent;
    free(path);
    return folder;
}

int atc_helper_main(int argc, char **argv) {
    @autoreleasepool {
        NSString *folder = atc_executable_folder();
        // "<App>.app/Contents/Frameworks/<App> Browser (Chromium).app/Contents/MacOS".
        NSString *frameworks = folder.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        NSString *framework = [frameworks stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
        // The sandbox is entered before the framework is loaded.
        NSString *sandboxPath = [framework stringByAppendingPathComponent:@"Libraries/libcef_sandbox.dylib"];
        void *sandbox = dlopen(sandboxPath.UTF8String, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
        if (!sandbox) {
            fprintf(stderr, "AgentTerm Browser: %s\n", dlerror());
            return 1;
        }
        __typeof__(&cef_sandbox_initialize) initialize = (__typeof__(&cef_sandbox_initialize))dlsym(sandbox, "cef_sandbox_initialize");
        if (!initialize || !initialize(argc, argv)) {
            fprintf(stderr, "AgentTerm Browser: the sandbox could not be entered\n");
            return 1;
        }
        NSString *failed = atc_load_library([framework stringByAppendingPathComponent:@"Chromium Embedded Framework"].UTF8String);
        if (failed) {
            fprintf(stderr, "AgentTerm Browser: %s\n", failed.UTF8String);
            return 1;
        }
    }
    cef_main_args_t args = {argc, argv};
    return p_cef_execute_process(&args, NULL, NULL);
}

#else

// Built without CEF's headers: the browser says it is not in this build.

int atc_start(const atc_paths *paths, atc_event_fn events, void *context, char *error, size_t error_size) {
    (void)paths, (void)events, (void)context;
    atc_say(error, error_size, @"This build of AgentTerm was made without Chromium (scripts/fetch-cef.sh).");
    return 0;
}
int atc_started(void) { return 0; }
void atc_shutdown(void) {}
void atc_create(void *parent, const char *url, const char *key, const char *cache_path, int token) {
    // Never asked for: Chromium does not start in such a build.
    (void)parent, (void)url, (void)key, (void)cache_path, (void)token;
}
void atc_forget_profile(const char *key) { (void)key; }
void *atc_view(int browser) { (void)browser; return NULL; }
void atc_close(int browser) { (void)browser; }
void atc_load(int browser, const char *url) { (void)browser, (void)url; }
void atc_back(int browser) { (void)browser; }
void atc_forward(int browser) { (void)browser; }
void atc_reload(int browser, int ignore_cache) { (void)browser, (void)ignore_cache; }
void atc_stop(int browser) { (void)browser; }
void atc_set_zoom(int browser, double level) { (void)browser, (void)level; }
double atc_zoom(int browser) { (void)browser; return 0; }
void atc_find(int browser, const char *text, int forward, int match_case, int find_next) { (void)browser, (void)text, (void)forward, (void)match_case, (void)find_next; }
void atc_stop_finding(int browser, int clear) { (void)browser, (void)clear; }
void atc_focus(int browser, int focus) { (void)browser, (void)focus; }
void atc_resized(int browser) { (void)browser; }
int atc_devtools(int browser, const char *json, size_t size) { (void)browser, (void)json, (void)size; return 0; }
void atc_show_devtools(int browser) { (void)browser; }
void atc_answer_permission(int prompt, int allow) { (void)prompt, (void)allow; }
void atc_cancel_download(int download) { (void)download; }
int atc_chrome_major(void) { return 0; }
int atc_helper_main(int argc, char **argv) {
    (void)argc, (void)argv;
    fprintf(stderr, "AgentTerm Browser: built without Chromium\n");
    return 1;
}

#endif
