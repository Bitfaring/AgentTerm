// The Mac app's browser (#76): Chromium, through the C API of the Chromium
// Embedded Framework. This header is what Swift sees; it names nothing of
// CEF's own, so the app compiles where CEF's headers are not fetched, and
// the browser then says it is not in the build (`atc_built_with_cef`).
#ifndef AGENTTERM_CEF_H
#define AGENTTERM_CEF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when CEF's headers were there when this was compiled.
int atc_built_with_cef(void);

/// What happened in a browser, for `atc_event_fn`. The strings live only
/// for the call.
typedef enum {
    ATC_EVENT_CREATED = 1,
    ATC_EVENT_ADDRESS = 2,        // text: the URL
    ATC_EVENT_TITLE = 3,          // text: the title
    ATC_EVENT_LOADING = 4,        // a: loading, b: can go back, c: can go forward
    ATC_EVENT_LOAD_ERROR = 5,     // a: CEF's error code, text: its words, text2: the URL
    ATC_EVENT_POPUP = 6,          // text: the URL a page wanted to open elsewhere
    ATC_EVENT_CLOSED = 7,
    ATC_EVENT_DEVTOOLS_RESULT = 8, // a: message id, b: success, text: the JSON, size
    ATC_EVENT_DEVTOOLS_EVENT = 9,  // text: method, text2: params as JSON, size of params
    ATC_EVENT_FIND = 10,          // a: count, b: active match, c: final
    ATC_EVENT_DOWNLOAD = 11,      // a: id, b: percent (-1 unknown), c: 1 done 2 cancelled, text: path, text2: URL
    ATC_EVENT_PERMISSION = 12,    // a: prompt id, b: CEF's permission bits, text: the origin
    ATC_EVENT_CRASHED = 13,       // a: CEF's termination status
    ATC_EVENT_FAVICON = 14,       // text: the icon's URL
    ATC_EVENT_FOCUS = 15,         // the page took the keyboard's focus
    ATC_EVENT_PROGRESS = 16,      // a: progress in thousandths
    ATC_EVENT_READY = 17,         // browser 0: browsers can be made from now on
} atc_event_kind;

typedef struct {
    atc_event_kind kind;
    int browser;
    int a, b, c;
    const char *text;
    const char *text2;
    size_t size;
} atc_event;

typedef void (*atc_event_fn)(void *context, const atc_event *event);

/// Where things are, for `atc_start`.
typedef struct {
    /// "Chromium Embedded Framework.framework" itself.
    const char *framework_path;
    /// The helper app's executable, "<App> Helper.app/Contents/MacOS/<App> Helper".
    const char *helper_path;
    /// The app bundle.
    const char *main_bundle_path;
    /// Where every profile's folder is, and CEF's own.
    const char *root_cache_path;
    const char *log_file;
    /// The keychain item cookies are encrypted with: each build has its own.
    const char *keychain_service;
    const char *keychain_account;
    /// Where downloads go.
    const char *downloads_path;
    const char *locale;
    /// 1 for a test or a trial run: cookies are encrypted with a key of
    /// Chromium's own instead of one in the user's keychain, which a test
    /// must not touch.
    int mock_keychain;
} atc_paths;

/// Loads the framework and starts CEF, on the main thread, once. Returns 1
/// when it started; otherwise 0 and why in `error`.
int atc_start(const atc_paths *paths, atc_event_fn events, void *context, char *error, size_t error_size);
int atc_started(void);
/// Closes every browser and stops CEF. For the app's last moments.
void atc_shutdown(void);

/// Makes a browser inside `parent` (an NSView, kept alive by the caller
/// until it is answered), with the profile kept in `cache_path` (a folder
/// under the root), loading `url`. A profile opens in the background the
/// first time: the answer is ATC_EVENT_CREATED, sent to browser 0, with the
/// new browser's id in `b` (0 when it could not be made) and `token` in `a`.
void atc_create(void *parent, const char *url, const char *cache_path, int token);
/// The browser's own view, to be moved to another parent; NULL once closed.
void *atc_view(int browser);
void atc_close(int browser);
void atc_load(int browser, const char *url);
void atc_back(int browser);
void atc_forward(int browser);
void atc_reload(int browser, int ignore_cache);
void atc_stop(int browser);
void atc_set_zoom(int browser, double level);
double atc_zoom(int browser);
void atc_find(int browser, const char *text, int forward, int match_case, int find_next);
void atc_stop_finding(int browser, int clear);
void atc_focus(int browser, int focus);
void atc_resized(int browser);
/// Sends a DevTools protocol message (a JSON object with "id", "method",
/// "params"); answered with ATC_EVENT_DEVTOOLS_RESULT. Returns 1 when sent.
int atc_devtools(int browser, const char *json, size_t size);
/// Opens Chromium's own DevTools for the page, in a window of their own.
void atc_show_devtools(int browser);
/// Answers a permission prompt: 1 allows what was asked, 0 refuses it.
void atc_answer_permission(int prompt, int allow);
void atc_cancel_download(int download);

/// The helper processes' whole program: renderer, GPU, network and the rest.
int atc_helper_main(int argc, char **argv);

/// The major version of the Chromium the app was built with; 0 without it.
int atc_chrome_major(void);

#ifdef __cplusplus
}
#endif

#endif
