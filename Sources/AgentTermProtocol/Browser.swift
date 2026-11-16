import Foundation

/// The browser of the Mac app (#76): Chromium, which the user and the agents
/// use alike. It runs inside the AgentTerm app on the Mac whose host started
/// the agents; the host passes what an agent asks of it to that app, and the
/// iPhone sees its tabs through the host.

/// A tab of the browser, as every device sees it.
public struct BrowserTabInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    /// The project whose profile it uses: its sign-ins and cookies. "" for
    /// none.
    public var project: String
    /// The agent's session that opened it, the only one that sees and
    /// drives it; nil for the user's, which no agent reaches.
    public var openedBy: SessionID?
    public var loading: Bool
    /// The user took it back from its agent, which waits until it is given
    /// back.
    public var userHasIt: Bool
    /// What it pretends to be, when it does (`BrowserDevice.name`).
    public var emulating: String?
    /// The name of the profile it uses: its sign-ins and cookies.
    public var profile: String
    /// A private tab: a profile of its own in memory, which keeps nothing
    /// and is gone with the last of its tabs.
    public var isPrivate: Bool

    public init(
        id: String, title: String, url: String, project: String, openedBy: SessionID? = nil, loading: Bool = false,
        userHasIt: Bool = false, emulating: String? = nil, profile: String = "", isPrivate: Bool = false
    ) {
        self.profile = profile
        self.isPrivate = isPrivate
        self.id = id
        self.title = title
        self.url = url
        self.project = project
        self.openedBy = openedBy
        self.loading = loading
        self.userHasIt = userHasIt
        self.emulating = emulating
    }

    /// Whether an agent's session sees it and may drive it: only the one
    /// that opened it, and not while the user has it.
    public func reachable(by agent: SessionID) -> Bool { openedBy == agent }

    public var displayTitle: String { title.isEmpty ? (url.isEmpty ? "New Tab" : url) : title }
}

/// A profile of the browser, as the user named it in Settings > Browser:
/// its own sign-ins, cookies, storage and cache.
public struct BrowserProfileInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The one the user's tabs open in.
    public var isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// A phone, a tablet or a size of window a page can be shown as, through
/// Chromium's own emulation: its size, its user agent with the client
/// hints and `navigator.platform` that go with it, touch and, when asked,
/// a location.
public struct BrowserDevice: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case phone, tablet, computer
    }

    /// What the page is told of the device through the client hints
    /// (`navigator.userAgentData`, the `Sec-CH-UA-*` headers).
    public struct Hints: Codable, Equatable, Hashable, Sendable {
        public var platform: String
        public var platformVersion: String
        public var architecture: String
        public var model: String
        public var mobile: Bool

        public init(platform: String, platformVersion: String, architecture: String, model: String, mobile: Bool) {
            self.platform = platform
            self.platformVersion = platformVersion
            self.architecture = architecture
            self.model = model
            self.mobile = mobile
        }
    }

    public var name: String
    public var width: Int
    public var height: Int
    public var scale: Double
    public var mobile: Bool
    public var touch: Bool
    /// Its user agent; `%s` stands for the browser's own version.
    public var userAgent: String?
    public var kind: Kind
    public var hints: Hints?
    public var latitude: Double?
    public var longitude: Double?

    public init(
        name: String, width: Int, height: Int, scale: Double = 1, mobile: Bool = false, touch: Bool = false, userAgent: String? = nil,
        kind: Kind? = nil, hints: Hints? = nil, latitude: Double? = nil, longitude: Double? = nil
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.scale = scale
        self.mobile = mobile
        self.touch = touch
        self.userAgent = userAgent
        self.kind = kind ?? (mobile ? .phone : .computer)
        self.hints = hints
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Its user agent with the browser's version, `major.0.0.0` as Chrome
    /// gives it.
    public func userAgent(chromeMajor: Int) -> String? {
        userAgent?.replacingOccurrences(of: "%s", with: "\(chromeMajor).0.0.0")
    }

    /// What `navigator.platform` says on such a device; nil leaves the
    /// Mac's.
    public var platform: String? {
        switch hints?.platform ?? (userAgent?.contains("Windows") == true ? "Windows" : nil) {
        case "iOS": return userAgent?.contains("Macintosh") == true ? "MacIntel" : (kind == .tablet ? "iPad" : "iPhone")
        case "Android": return "Linux armv81"
        case "Windows": return "Win32"
        default: return nil
        }
    }

    /// The devices offered by name, to the user and to the agents: Chrome's
    /// DevTools' own, with their sizes, user agents and client hints
    /// (devtools-frontend, `front_end/models/emulation/EmulatedDevices.ts`,
    /// 2026-11-15), and a laptop and a desktop of the Mac's own.
    public static let presets: [BrowserDevice] = [
        BrowserDevice(
            name: "iPhone SE", width: 375, height: 667, scale: 2, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone XR", width: 414, height: 896, scale: 2, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 12 Pro", width: 390, height: 844, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 14", width: 390, height: 844, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 14 Plus", width: 428, height: 926, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 14 Pro", width: 393, height: 852, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 14 Pro Max", width: 430, height: 932, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 15", width: 393, height: 852, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 15 Plus", width: 430, height: 932, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 15 Pro", width: 393, height: 852, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 15 Pro Max", width: 430, height: 932, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 16e", width: 390, height: 844, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 16", width: 393, height: 852, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 16 Plus", width: 430, height: 932, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 16 Pro", width: 402, height: 874, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "iPhone 16 Pro Max", width: 440, height: 956, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .phone,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true)),
        BrowserDevice(
            name: "Pixel 7", width: 412, height: 915, scale: 2.625, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "13", architecture: "", model: "Pixel 7", mobile: true)),
        BrowserDevice(
            name: "Pixel 8", width: 412, height: 915, scale: 2.625, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "14", architecture: "", model: "Pixel 8", mobile: true)),
        BrowserDevice(
            name: "Pixel 8 Pro", width: 448, height: 997, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "14", architecture: "", model: "Pixel 8 Pro", mobile: true)),
        BrowserDevice(
            name: "Pixel 8a", width: 412, height: 915, scale: 2.625, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 8a) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "14", architecture: "", model: "Pixel 8a", mobile: true)),
        BrowserDevice(
            name: "Pixel 9", width: 412, height: 924, scale: 2.625, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "14", architecture: "", model: "Pixel 9", mobile: true)),
        BrowserDevice(
            name: "Pixel 9 Pro", width: 427, height: 952, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 9 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "14", architecture: "", model: "Pixel 9 Pro", mobile: true)),
        BrowserDevice(
            name: "Pixel 9 Pro XL", width: 448, height: 997, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 9 Pro XL) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "14", architecture: "", model: "Pixel 9 Pro XL", mobile: true)),
        BrowserDevice(
            name: "Pixel 9 Pro Fold", width: 412, height: 922, scale: 2.625, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 9 Pro Fold) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "14", architecture: "", model: "Pixel 9 Pro Fold", mobile: true)),
        BrowserDevice(
            name: "Pixel 10", width: 412, height: 924, scale: 2.625, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 16; Pixel 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "16", architecture: "", model: "Pixel 10", mobile: true)),
        BrowserDevice(
            name: "Samsung Galaxy S8+", width: 360, height: 740, scale: 4, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 8.0.0; SM-G955U Build/R16NW) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "8.0.0", architecture: "", model: "SM-G955U", mobile: true)),
        BrowserDevice(
            name: "Samsung Galaxy S20 Ultra", width: 412, height: 915, scale: 3.5, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 13; SM-G981B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "13", architecture: "", model: "SM-G981B", mobile: true)),
        BrowserDevice(
            name: "Samsung Galaxy A51/71", width: 412, height: 914, scale: 2.625, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 8.0.0; SM-G955U Build/R16NW) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "8.0.0", architecture: "", model: "SM-G955U", mobile: true)),
        BrowserDevice(
            name: "Samsung Galaxy A55", width: 360, height: 800, scale: 2.25, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 14; SM-A556B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "14", architecture: "", model: "SM-A556B", mobile: true)),
        BrowserDevice(
            name: "Galaxy Z Fold 5", width: 344, height: 882, scale: 2.625, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "10.0", architecture: "", model: "SM-F946U", mobile: true)),
        BrowserDevice(
            name: "Galaxy Z Fold 6", width: 412, height: 968, scale: 2.625, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 14; SM-F956U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "14", architecture: "", model: "SM-F956U", mobile: true)),
        BrowserDevice(
            name: "Moto G4", width: 360, height: 640, scale: 3, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 6.0.1; Moto G (4)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "6.0.1", architecture: "", model: "Moto G (4)", mobile: true)),
        BrowserDevice(
            name: "Moto G Power", width: 412, height: 823, scale: 1.75, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 11; moto g power (2022)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "11", architecture: "", model: "moto g power (2022)", mobile: true)),
        BrowserDevice(
            name: "Surface Duo", width: 540, height: 720, scale: 2.5, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 11.0; Surface Duo) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Mobile Safari/537.36", kind: .phone,
            hints: Hints(platform: "Android", platformVersion: "11.0", architecture: "", model: "Surface Duo", mobile: true)),
        BrowserDevice(
            name: "Facebook on Android", width: 412, height: 892, scale: 3.5, mobile: true, touch: true,
            userAgent:
                "Mozilla/5.0 (Linux; Android 12; Pixel 6 Build/SQ3A.220705.004; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/%s Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/407.0.0.0.65;]",
            kind: .phone, hints: Hints(platform: "Android", platformVersion: "12", architecture: "", model: "Pixel 6", mobile: true)),
        BrowserDevice(
            name: "iPad Mini", width: 768, height: 1024, scale: 2, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", kind: .tablet,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPad", mobile: true)),
        BrowserDevice(
            name: "iPad Pro 13", width: 1032, height: 1376, scale: 2, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15", kind: .tablet,
            hints: Hints(platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPad", mobile: true)),
        BrowserDevice(
            name: "Galaxy Tab S4", width: 712, height: 1138, scale: 2.25, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Linux; Android 8.1.0; SM-T837A) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Safari/537.36", kind: .tablet,
            hints: Hints(platform: "Android", platformVersion: "8.1.0", architecture: "", model: "SM-T837A", mobile: false)),
        BrowserDevice(
            name: "Surface Pro 7", width: 912, height: 1368, scale: 2, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Safari/537.36", kind: .tablet),
        BrowserDevice(
            name: "Surface Pro 10", width: 960, height: 1440, scale: 2, mobile: true, touch: true,
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Safari/537.36", kind: .tablet),
        BrowserDevice(
            name: "Asus Zenbook Fold", width: 853, height: 1280, scale: 1.5, touch: true,
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Safari/537.36", kind: .tablet,
            hints: Hints(platform: "Windows", platformVersion: "11.0", architecture: "", model: "UX9702AA", mobile: false)),
        BrowserDevice(name: "Laptop", width: 1280, height: 800, scale: 2, kind: .computer),
        BrowserDevice(name: "Laptop with touch", width: 1280, height: 950, scale: 1, touch: true, kind: .computer),
        BrowserDevice(name: "Laptop with HiDPI screen", width: 1440, height: 900, scale: 2, kind: .computer),
        BrowserDevice(name: "Laptop with MDPI screen", width: 1280, height: 800, scale: 1, kind: .computer),
        BrowserDevice(name: "Desktop", width: 1920, height: 1080, scale: 1, kind: .computer),
    ]

    /// A preset by its name, whatever its case and spaces.
    public static func preset(named name: String) -> BrowserDevice? {
        let wanted = name.lowercased().filter { !$0.isWhitespace }
        return presets.first { $0.name.lowercased().filter { !$0.isWhitespace } == wanted }
    }
}

/// What an agent asks of the browser, through AgentTerm's MCP server, or
/// what the iPhone or the user asks of a tab. Tabs are named by their id;
/// elements by the `ref` the last snapshot gave them.
public enum BrowserRequest: Codable, Equatable, Sendable {
    /// Opens a tab of the agent's own, at `url` or empty, beside the agent
    /// where the user sees it: in the profile named, or the one its tabs
    /// use, or the only one there is; or private, in a profile of its own
    /// in memory.
    case open(url: String?, profile: String?, private: Bool)
    /// The tabs the agent may drive.
    case tabs
    /// The profiles there are.
    case profiles
    case navigate(tab: String, url: String)
    /// Back (-1) or forward (+1) in the tab's history, or reload (0).
    case history(tab: String, step: Int)
    /// What the page holds, as text: its parts by role and name, each that
    /// can be acted on with a `ref`. `within` narrows it to one element.
    case snapshot(tab: String, within: String?)
    /// A picture of the page as shown, of all of it, or of one element.
    case screenshot(tab: String, ref: String?, fullPage: Bool)
    case click(tab: String, ref: String, double: Bool)
    case hover(tab: String, ref: String)
    /// Types into a field: what is in it first goes, unless `append`.
    case type(tab: String, ref: String, text: String, submit: Bool, append: Bool)
    /// Picks options of a list by their value or their words.
    case select(tab: String, ref: String, values: [String])
    /// Chooses files for a file field, as its dialog would: files of the
    /// agent's project only.
    case upload(tab: String, ref: String, paths: [String])
    /// A key, with Control, Alt, Shift or Meta: "Enter", "Control+A".
    case press(tab: String, key: String)
    /// Scrolls the page, or an element, by points.
    case scroll(tab: String, ref: String?, x: Double, y: Double)
    /// Waits until a text shows, or goes, or the page has loaded, or the
    /// time is up.
    case wait(tab: String, text: String?, gone: String?, seconds: Double)
    /// Runs JavaScript in the page and answers with what it gives.
    case evaluate(tab: String, script: String)
    /// What the page wrote to its console, and its errors.
    case console(tab: String, errorsOnly: Bool)
    /// The page's requests: those that failed, or all.
    case network(tab: String, failedOnly: Bool)
    /// Shows the page as a device does, or as itself again with nil.
    case emulate(tab: String, device: BrowserDevice?)
    case close(tab: String)
    /// For the iPhone: a small picture of a tab, and taking it from its
    /// agent or giving it back.
    case picture(tab: String)
    case takeOver(tab: String)
    case giveBack(tab: String)
    /// A device shows the page as it is, live: it is sent pictures of it,
    /// at most `width` pixels wide, while one watches (`browserFrame`).
    case watch(tab: String, on: Bool, width: Int)
    /// A touch at a point of the page, in its CSS pixels: a click.
    case tap(tab: String, x: Double, y: Double)
    /// Text typed into what has the keyboard in the page.
    case text(tab: String, text: String)
    /// A device opens a tab of the user's in a project, at `url` or empty,
    /// in a profile (its id), the default, or private; the Mac does not
    /// bring it to the front.
    case newTab(project: String, url: String?, profile: String?, private: Bool)
    /// Stops loading the page.
    case stop(tab: String)

    /// The tab it is about, when it is about one.
    public var tab: String? {
        switch self {
        case .open, .tabs, .newTab, .profiles: return nil
        case .navigate(let tab, _), .history(let tab, _), .snapshot(let tab, _), .screenshot(let tab, _, _), .click(let tab, _, _), .hover(let tab, _),
            .type(let tab, _, _, _, _), .select(let tab, _, _), .upload(let tab, _, _), .press(let tab, _), .scroll(let tab, _, _, _), .wait(let tab, _, _, _),
            .evaluate(let tab, _), .console(let tab, _), .network(let tab, _), .emulate(let tab, _), .close(let tab), .picture(let tab),
            .takeOver(let tab), .giveBack(let tab), .watch(let tab, _, _), .tap(let tab, _, _), .text(let tab, _), .stop(let tab):
            return tab
        }
    }

    /// Whether it acts on the page, which is refused while the user has
    /// the tab; looking at it is not.
    public var acts: Bool {
        switch self {
        case .navigate, .history, .click, .hover, .type, .select, .upload, .press, .scroll, .evaluate, .emulate, .tap, .text, .stop: return true
        default: return false
        }
    }

    /// What a device may ask of a tab: the user, who uses the page through
    /// it (#76), as on the Mac. An agent's own tab the device takes over by
    /// acting on its page; showing it as a device, or closing it, does not.
    public var isTheDevices: Bool {
        switch self {
        case .picture, .takeOver, .giveBack, .watch, .tap, .text, .press, .scroll, .history, .navigate, .stop, .newTab, .emulate, .close, .profiles:
            return true
        default: return false
        }
    }
}

public enum BrowserResult: Codable, Equatable, Sendable {
    /// What happened, in words for the agent.
    case text(String)
    /// A picture, with words about it.
    case image(png: Data, text: String)
    /// The tabs an agent may drive, or every tab for the iPhone.
    case tabs([BrowserTabInfo])
    /// Not done, and why, in words for the agent or the user.
    case refused(String)
    /// A device's touch: whether it gave the keyboard to a field of the
    /// page, which the device then types into.
    case touched(field: Bool)
    /// A device's new tab.
    case opened(tab: String)
    /// The profiles there are, for a device.
    case profiles([BrowserProfileInfo])
}

/// What the apps and the agents are told about the browser, in the same
/// words everywhere (principle 9).
public enum BrowserWords {
    /// No app shows the browser of the Mac whose agent asks.
    public static let noApp =
        "The browser runs in the AgentTerm app on this Mac, and that app is not connected to this Mac's host: it is closed, or it shows another Mac. Ask the user to open it on this Mac."
    public static let notInBuild = "This build of AgentTerm has no browser."
    /// The name a private tab's profile goes by.
    public static let privateProfile = "Private"
    /// The profiles, for an agent: `names` with the default first.
    public static func profiles(_ names: [String], uses: String?) -> String {
        "The browser's profiles, each with its own sign-ins and cookies: \(names.joined(separator: ", ")) (the first is the user's default)."
            + (uses.map { " Your tabs use \($0)." } ?? "")
            + " Or private: true, for a private tab of your own that keeps nothing and has none of the user's sign-ins."
    }
    /// An agent's first tab, with several profiles and none named.
    public static func whichProfile(_ names: [String]) -> String {
        "There are several browser profiles: \(names.joined(separator: ", ")) (the first is the user's default). Ask the user which one to use, then call browser_open again with profile set to its name; or open a private tab with private: true."
    }
    /// A file an agent would upload that is not its project's.
    public static func notInProject(_ path: String, _ project: String) -> String {
        "\(path) is not a file of your project (\(project)): only those can be uploaded. Copy it into the project first if the user wants it sent."
    }
    public static func noFile(_ path: String) -> String { "There is no file at \(path)." }
    /// The frames of a page, whose insides a snapshot does not read.
    public static func frames(_ addresses: [String]) -> String {
        "This page has \(addresses.count == 1 ? "a frame" : "\(addresses.count) frames") whose insides are not in this snapshot and cannot be acted on here: \(addresses.joined(separator: ", ")). To use one, open its address in a tab (browser_navigate or browser_open)."
    }
    public static func noProfile(_ name: String, _ names: [String]) -> String {
        "There is no browser profile called “\(name)”. The profiles: \(names.joined(separator: ", "))."
    }
    public static func notYours(_ tab: String) -> String {
        "There is no tab \(tab) of yours: you see and use only the tabs you opened. Open one with browser_open, or list yours with browser_tabs."
    }
    public static func noTab(_ tab: String) -> String { "There is no tab \(tab): it was closed. List yours with browser_tabs." }
    public static func userHasIt(_ tab: String) -> String {
        "The user took tab \(tab) over and is using it. Wait until they give it back, or open a tab of your own with browser_open."
    }
    public static func staleRef(_ ref: String) -> String {
        "The page changed since the snapshot that gave \(ref): take a new snapshot with browser_snapshot and use its refs."
    }
    public static func unknownRef(_ ref: String) -> String { "No element \(ref) in the last snapshot of this tab: take a snapshot with browser_snapshot." }

    /// The bar over an agent's tab while it may drive it.
    public static func agentDrives(_ agent: String) -> String { "\(agent) is using this tab" }
    /// The bar while the user has it: the same whichever agent's it is,
    /// rather than a session's name, which may be long (asked by the owner).
    public static let userHas = "You have this tab: AgentTerm waits until you give it back"
    public static func giveBack(_ agent: String) -> String { "Let \(agent) Go On" }
    public static let takeOver = "Take Over"
    /// Why a page did not load, for a server of the project that is not running.
    public static func nothingAnswers(_ url: String) -> String {
        "Nothing answers at \(url). If it is a development server, it may not be running: start it in a shell, then reload."
    }
}
