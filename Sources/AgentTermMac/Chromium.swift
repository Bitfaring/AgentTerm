import AgentTermHost
import AgentTermProtocol
import AppKit
import CAgentTermCEF

/// Chromium, embedded with the Chromium Embedded Framework (#76), for the
/// user and the agents alike. It is started once, the first time a browser
/// is wanted, and runs inside the app: its pages' processes are the helper
/// apps in the app's Frameworks folder, each in Chromium's sandbox.
@MainActor
final class Chromium {
    static let shared = Chromium()

    /// What a browser said, as the bridge hands it over.
    struct Event {
        let kind: atc_event_kind
        let browser: Int32
        let a: Int32
        let b: Int32
        let c: Int32
        let text: String?
        let text2: String?
        /// The JSON of a DevTools answer or event.
        let data: Data?
    }

    /// Why Chromium is not running, once it was tried and did not start.
    private(set) var problem: String?
    private var tried = false
    /// Who hears each browser's events.
    private var listeners: [Int32: (Event) -> Void] = [:]

    var isRunning: Bool { atc_started() != 0 }
    /// Chromium has said it is ready: browsers can be made.
    private(set) var isReady = false
    /// What waits for it to be.
    private var whenReady: [() -> Void] = []

    /// Runs `work` once browsers can be made: at once, or when Chromium
    /// says it is ready.
    func onceReady(_ work: @escaping () -> Void) {
        if isReady { work() } else { whenReady.append(work) }
    }

    private func becameReady() {
        isReady = true
        let waiting = whenReady
        whenReady = []
        waiting.forEach { $0() }
    }

    /// Where every profile is kept: in the state folder of this build, so
    /// that the released and the development build never share one
    /// (principle 7), and a test's in its own.
    static var root: URL { HostEnvironment.supportDirectory.appendingPathComponent("browser", isDirectory: true) }
    nonisolated static var rootPath: String { HostEnvironment.supportDirectory.appendingPathComponent("browser", isDirectory: true).path }

    /// Whether cookies are encrypted with a key of Chromium's own rather
    /// than one in the keychain. A test, with a state folder of its own,
    /// leaves the user's keychain alone. A development build too, as the
    /// owner chose on 2026-11-15: it is signed anew with each build, and
    /// macOS asked again each time whether it may read its key.
    static var usesOwnKey: Bool {
        !(ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"] ?? "").isEmpty || AppChannel.current == .dev
    }

    /// Starts Chromium if it is not running. False when it cannot, with
    /// why in `problem`.
    func start() -> Bool {
        if isRunning { return true }
        if tried { return false }
        tried = true
        guard atc_built_with_cef() != 0 else {
            problem = "This build of AgentTerm was made without Chromium. Run scripts/fetch-cef.sh, then build it again."
            return false
        }
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", let frameworks = bundle.privateFrameworksURL else {
            problem = "The browser runs in the app only, which scripts/bundle-mac.sh builds."
            return false
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? AppChannel.current.appName
        let framework = frameworks.appendingPathComponent("Chromium Embedded Framework.framework")
        let helper = frameworks.appendingPathComponent("\(name) Helper.app/Contents/MacOS/\(name) Helper")
        guard FileManager.default.fileExists(atPath: framework.path), FileManager.default.fileExists(atPath: helper.path) else {
            problem = "Chromium is missing from the app: it was built without it."
            return false
        }
        let root = Self.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Profiles cleared or deleted while Chromium had them open.
        BrowserProfiles.wipePending()
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Downloads"
        // Its type said: the Swift of CodeQL's runner could not work it out
        // with the `map` (#102).
        let values: [String] = [
            framework.path, helper.path, bundle.bundlePath, root.path, root.appendingPathComponent("chromium.log").path,
            // Its own keychain item for each build (principle 7).
            "\(name) Safe Storage", name, downloads, "en-US",
        ]
        let strings: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var paths = atc_paths(
            framework_path: strings[0], helper_path: strings[1], main_bundle_path: strings[2], root_cache_path: strings[3],
            log_file: strings[4], keychain_service: strings[5], keychain_account: strings[6], downloads_path: strings[7], locale: strings[8],
            mock_keychain: Self.usesOwnKey ? 1 : 0)
        var error = [CChar](repeating: 0, count: 512)
        let started = atc_start(&paths, Chromium.received, nil, &error, error.count)
        if started == 0 {
            problem = String(cString: error)
            return false
        }
        problem = nil
        return true
    }

    /// The bridge's events, on the main thread, which is CEF's UI thread.
    private static let received: atc_event_fn = { _, pointer in
        guard let pointer else { return }
        let event = Event(pointer.pointee)
        MainActor.assumeIsolated {
            switch event.kind {
            case ATC_EVENT_READY: Chromium.shared.becameReady()
            case ATC_EVENT_CREATED where event.browser == 0: Chromium.shared.created(token: event.a, browser: event.b)
            default: Chromium.shared.listeners[event.browser]?(event)
            }
        }
    }

    /// What waits for a browser being made, by the token it was asked with.
    private var making: [Int32: (Int32) -> Void] = [:]
    private var nextToken: Int32 = 1

    /// Makes a browser inside `parent`, in the profile kept in `profile`,
    /// and hands its id to `done` (0 when it could not be made). `parent`
    /// is kept until then.
    func create(in parent: NSView, url: String, profile: URL, _ done: @escaping (Int32) -> Void) {
        onceReady { [self] in
            let token = nextToken
            nextToken += 1
            making[token] = done
            try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            atc_create(Unmanaged.passUnretained(parent).toOpaque(), url, profile.path, token)
        }
    }

    private func created(token: Int32, browser: Int32) {
        making.removeValue(forKey: token)?(browser)
    }

    func listen(to browser: Int32, _ listener: @escaping (Event) -> Void) { listeners[browser] = listener }
    func forget(_ browser: Int32) { listeners[browser] = nil }

    /// Closes every browser and stops Chromium, as the app quits.
    func shutDown() {
        guard isRunning else { return }
        atc_shutdown()
    }
}

extension Chromium.Event {
    init(_ event: atc_event) {
        kind = event.kind
        browser = event.browser
        a = event.a
        b = event.b
        c = event.c
        switch event.kind {
        case ATC_EVENT_DEVTOOLS_RESULT:
            text = nil
            text2 = nil
            data = event.text.map { Data(bytes: $0, count: event.size) }
        case ATC_EVENT_DEVTOOLS_EVENT:
            text = event.text.map { String(cString: $0) }
            text2 = nil
            data = event.text2.map { Data(bytes: $0, count: event.size) }
        default:
            text = event.text.map { String(cString: $0) }
            text2 = event.text2.map { String(cString: $0) }
            data = nil
        }
    }
}
