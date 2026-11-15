#if os(macOS)
import AgentTermProtocol
import Foundation

/// The browser's tools of AgentTerm's MCP server (#76): an agent opens tabs
/// of its own in the browser the user sees, reads them, acts on them and
/// looks at them, through the app that shows the browser.
extension AgentShellsMCP {
    static let browserTools: [[String: Any]] = [
        browserTool(
            "browser_open",
            "Opens a tab of your own in AgentTerm's browser (Chromium), beside you where the user sees it, at a URL or empty. It uses the profile the user picks for you, and has its sign-ins and cookies. Returns the tab's id.",
            ["url": string("The address to load")], required: []),
        browserTool("browser_tabs", "The browser tabs you opened that are still open. The user's tabs, and another agent's, you do not see.", [:], required: []),
        browserTool("browser_navigate", "Loads an address in a tab, and says where it ended up.", ["tab": tabArgument, "url": string("The address")], required: ["tab", "url"]),
        browserTool("browser_back", "Goes back in a tab's history.", ["tab": tabArgument], required: ["tab"]),
        browserTool("browser_forward", "Goes forward in a tab's history.", ["tab": tabArgument], required: ["tab"]),
        browserTool("browser_reload", "Loads a tab's page again.", ["tab": tabArgument], required: ["tab"]),
        browserTool(
            "browser_snapshot",
            "What a tab's page holds, as text: its parts by role and name, with the states and values that matter, and a ref for each that can be acted on. Take one before acting, and again after the page changed: refs belong to one snapshot of one page.",
            ["tab": tabArgument, "ref": string("Only this element and what is inside it")], required: ["tab"]),
        browserTool(
            "browser_screenshot", "A picture of a tab's page as it is shown, of all of it, or of one element.",
            ["tab": tabArgument, "ref": string("Only this element"), "full_page": boolean("All of the page, not only what is in view")], required: ["tab"]),
        browserTool(
            "browser_click", "Clicks an element by its ref, as the pointer would, and says what came of it.",
            ["tab": tabArgument, "ref": refArgument, "double": boolean("A double click")], required: ["tab", "ref"]),
        browserTool("browser_hover", "Moves the pointer over an element.", ["tab": tabArgument, "ref": refArgument], required: ["tab", "ref"]),
        browserTool(
            "browser_type", "Types into a field by its ref, as the keyboard would. What is in the field is replaced, unless append.",
            [
                "tab": tabArgument, "ref": refArgument, "text": string("What to type"), "submit": boolean("Press Enter after it"),
                "append": boolean("Keep what is in the field and type after it"),
            ], required: ["tab", "ref", "text"]),
        browserTool(
            "browser_select", "Picks options of a list by their values or their words.",
            ["tab": tabArgument, "ref": refArgument, "values": ["type": "array", "items": ["type": "string"], "description": "The options to pick"]],
            required: ["tab", "ref", "values"]),
        browserTool(
            "browser_press", "Presses a key in a tab, with Control, Alt, Shift or Meta when asked: Enter, Escape, Tab, ArrowDown, Control+A.",
            ["tab": tabArgument, "key": string("The key")], required: ["tab", "key"]),
        browserTool(
            "browser_scroll", "Scrolls a tab's page, or an element, by points: down and right are positive.",
            ["tab": tabArgument, "ref": string("The element to scroll; the page when none"), "x": number("Across"), "y": number("Down")],
            required: ["tab"]),
        browserTool(
            "browser_wait", "Waits until a text is on the page, or is gone, or the page has loaded, or the time is up.",
            [
                "tab": tabArgument, "text": string("Wait until this text shows"), "gone": string("Wait until this text is gone"),
                "seconds": number("At most this long; 10 by default"),
            ], required: ["tab"]),
        browserTool(
            "browser_evaluate", "Runs JavaScript in a tab's page and returns what it gives, as JSON. A promise is waited for.",
            ["tab": tabArgument, "script": string("An expression, or a function's body that returns")], required: ["tab", "script"]),
        browserTool(
            "browser_console", "What a tab's page wrote to its console, and its uncaught errors, newest last.",
            ["tab": tabArgument, "errors_only": boolean("Only errors and warnings")], required: ["tab"]),
        browserTool(
            "browser_network", "A tab's requests: their address, method, status and what failed, newest last.",
            ["tab": tabArgument, "failed_only": boolean("Only those that failed or answered 400 or more")], required: ["tab"]),
        browserTool(
            "browser_emulate",
            "Shows a tab's page as a device does: its size, user agent and touch, and a location when given. Devices by name: \(BrowserDevice.presets.map(\.name).joined(separator: ", ")); or a size of your own. off shows it as itself again.",
            [
                "tab": tabArgument, "device": string("A device by name"), "width": integer("Width in points"), "height": integer("Height in points"),
                "mobile": boolean("A phone's or tablet's page"), "touch": boolean("Touch instead of a mouse"), "user_agent": string("The user agent"),
                "latitude": number("A location to report"), "longitude": number("A location to report"), "off": boolean("Stop pretending"),
            ], required: ["tab"]),
        browserTool("browser_close", "Closes a tab you opened.", ["tab": tabArgument], required: ["tab"]),
    ]

    private static let tabArgument: [String: Any] = ["type": "string", "description": "The tab's id, from browser_open or browser_tabs"]
    private static let refArgument: [String: Any] = ["type": "string", "description": "The element's ref, from the last browser_snapshot"]

    /// What only looks at a tab: said to the agents, which may then ask
    /// less of the user before using it.
    private static let looking: Set<String> = ["browser_tabs", "browser_snapshot", "browser_screenshot", "browser_wait", "browser_console", "browser_network"]

    private static func browserTool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        let readOnly = looking.contains(name)
        var annotations: [String: Any] = ["readOnlyHint": readOnly, "openWorldHint": true]
        if !readOnly { annotations["destructiveHint"] = name == "browser_close" }
        return [
            "name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": annotations,
        ]
    }
    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    private static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
    private static func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }

    /// The request a browser tool's call makes, or why it cannot be made.
    static func browserRequest(_ name: String, _ arguments: [String: Any]) -> Result<BrowserRequest, BrowserToolError> {
        func text(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func flag(_ key: String) -> Bool { (arguments[key] as? Bool) ?? (arguments[key] as? NSNumber)?.boolValue ?? false }
        func value(_ key: String) -> Double? { (arguments[key] as? NSNumber)?.doubleValue ?? (arguments[key] as? String).flatMap(Double.init) }
        // A tab's id is a string; a number is taken too.
        let tab = text("tab") ?? (arguments["tab"] as? NSNumber).map { $0.stringValue }
        func needs(_ key: String) -> BrowserToolError { BrowserToolError(text: "Give \(key == "tab" ? "the tab's id" : "`\(key)`") as `\(key)`.") }
        if name != "browser_open", name != "browser_tabs", tab == nil { return .failure(needs("tab")) }
        let id = tab ?? ""
        func withRef(_ make: (String) -> BrowserRequest) -> Result<BrowserRequest, BrowserToolError> {
            guard let ref = text("ref") else { return .failure(needs("ref")) }
            return .success(make(ref))
        }
        switch name {
        case "browser_open": return .success(.open(url: text("url")))
        case "browser_tabs": return .success(.tabs)
        case "browser_navigate":
            guard let url = text("url") else { return .failure(needs("url")) }
            return .success(.navigate(tab: id, url: url))
        case "browser_back": return .success(.history(tab: id, step: -1))
        case "browser_forward": return .success(.history(tab: id, step: 1))
        case "browser_reload": return .success(.history(tab: id, step: 0))
        case "browser_snapshot": return .success(.snapshot(tab: id, within: text("ref")))
        case "browser_screenshot": return .success(.screenshot(tab: id, ref: text("ref"), fullPage: flag("full_page")))
        case "browser_click": return withRef { .click(tab: id, ref: $0, double: flag("double")) }
        case "browser_hover": return withRef { .hover(tab: id, ref: $0) }
        case "browser_type":
            guard let typed = arguments["text"] as? String else { return .failure(needs("text")) }
            return withRef { .type(tab: id, ref: $0, text: typed, submit: flag("submit"), append: flag("append")) }
        case "browser_select":
            let values = (arguments["values"] as? [String]) ?? text("values").map { [$0] } ?? []
            guard !values.isEmpty else { return .failure(needs("values")) }
            return withRef { .select(tab: id, ref: $0, values: values) }
        case "browser_press":
            guard let key = text("key") else { return .failure(needs("key")) }
            return .success(.press(tab: id, key: key))
        case "browser_scroll": return .success(.scroll(tab: id, ref: text("ref"), x: value("x") ?? 0, y: value("y") ?? 0))
        case "browser_wait": return .success(.wait(tab: id, text: text("text"), gone: text("gone"), seconds: value("seconds") ?? 10))
        case "browser_evaluate":
            guard let script = text("script") else { return .failure(needs("script")) }
            return .success(.evaluate(tab: id, script: script))
        case "browser_console": return .success(.console(tab: id, errorsOnly: flag("errors_only")))
        case "browser_network": return .success(.network(tab: id, failedOnly: flag("failed_only")))
        case "browser_emulate":
            if flag("off") { return .success(.emulate(tab: id, device: nil)) }
            var device: BrowserDevice
            if let named = text("device") {
                guard let preset = BrowserDevice.preset(named: named) else {
                    return .failure(
                        BrowserToolError(text: "There is no device called “\(named)”. Devices: \(BrowserDevice.presets.map(\.name).joined(separator: ", ")); or give a width and a height."))
                }
                device = preset
            } else if let width = value("width"), let height = value("height") {
                device = BrowserDevice(name: "\(Int(width)) × \(Int(height))", width: Int(width), height: Int(height))
            } else if value("latitude") != nil {
                device = BrowserDevice(name: "This Mac", width: 0, height: 0)
            } else {
                return .failure(BrowserToolError(text: "Name a device, or give a width and a height, or a location, or off."))
            }
            if arguments["mobile"] != nil { device.mobile = flag("mobile") }
            if arguments["touch"] != nil { device.touch = flag("touch") }
            if let agent = text("user_agent") { device.userAgent = agent }
            device.latitude = value("latitude")
            device.longitude = value("longitude")
            return .success(.emulate(tab: id, device: device))
        case "browser_close": return .success(.close(tab: id))
        default: return .failure(BrowserToolError(text: "There is no tool called \(name)."))
        }
    }

    /// Answers a browser tool's call: what it says, as MCP content, and
    /// whether it failed.
    func callBrowser(_ name: String, _ arguments: [String: Any]) -> ([[String: Any]], Bool) {
        guard let askBrowser = browserAsker else {
            return ([["type": "text", "text": "Not in a session of AgentTerm: there is no browser."]], true)
        }
        switch Self.browserRequest(name, arguments) {
        case .failure(let error):
            return ([["type": "text", "text": error.text]], true)
        case .success(let request):
            return Self.content(askBrowser(request))
        }
    }

    /// A browser's answer as MCP content.
    static func content(_ result: BrowserResult) -> ([[String: Any]], Bool) {
        switch result {
        case .text(let text):
            return ([["type": "text", "text": text]], false)
        case .image(let png, let text):
            let mime = png.starts(with: [0xFF, 0xD8]) ? "image/jpeg" : "image/png"
            return ([["type": "image", "data": png.base64EncodedString(), "mimeType": mime], ["type": "text", "text": text]], false)
        case .tabs(let tabs):
            if tabs.isEmpty { return ([["type": "text", "text": "You have no tab. Open one with browser_open."]], false) }
            let lines = tabs.map { tab in
                "\(tab.id): \(tab.displayTitle) — \(tab.url)" + (tab.userHasIt ? " (the user has it now)" : "") + (tab.emulating.map { " (as \($0))" } ?? "")
            }
            return ([["type": "text", "text": lines.joined(separator: "\n")]], false)
        case .refused(let why):
            return ([["type": "text", "text": why]], true)
        }
    }
}

public struct BrowserToolError: Error, Equatable {
    public let text: String
}

#endif
