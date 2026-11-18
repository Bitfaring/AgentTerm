import AgentTermProtocol
import AppKit
import CAgentTermCEF

/// A tab's line to Chromium's DevTools protocol (#76), inside the process:
/// CEF's `SendDevToolsMessage`, no port. What the agents do in a page goes
/// through here, as do the console and the requests it keeps.
@MainActor
final class DevToolsSession {
    struct Failure: Error {
        let text: String
    }

    /// A line of the console.
    struct ConsoleEntry {
        let level: String
        let text: String
        let source: String?
    }

    /// One request of the page.
    struct Request {
        let id: String
        var url: String
        var method: String
        var type: String
        var status: Int?
        var failure: String?
        var done = false
    }

    private let browser: () -> Int32
    private var nextID: Int32 = 1
    private var pending: [Int32: (Result<[String: Any], Failure>) -> Void] = [:]
    /// What the page wrote to its console, newest last.
    private(set) var console: [ConsoleEntry] = []
    private(set) var requests: [Request] = []
    /// Goes up whenever the main frame's document is another: a ref of an
    /// older snapshot names nothing any more.
    private(set) var document = 0
    /// The main frame's load has fired since the last navigation.
    private(set) var loaded = false
    /// The refs of the last snapshot, to the nodes they name, and the
    /// document they were taken of.
    private var refs: [String: Int] = [:]
    private var refsDocument = -1
    private var nextRef = 1
    /// A downloads that started, a popup that opened: said after an action.
    var happened: [String] = []
    /// The element the user picked with the inspector, once.
    var picked: ((Int) -> Void)?

    init(browser: @escaping () -> Int32) {
        self.browser = browser
    }

    // MARK: The line

    func send(_ method: String, _ params: [String: Any] = [:], done: @escaping (Result<[String: Any], Failure>) -> Void) {
        let id = nextID
        nextID += 1
        let message: [String: Any] = ["id": Int(id), "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return done(.failure(Failure(text: "\(method) could not be sent."))) }
        pending[id] = done
        let sent = data.withUnsafeBytes { buffer in atc_devtools(browser(), buffer.baseAddress?.assumingMemoryBound(to: CChar.self), buffer.count) }
        if sent == 0 {
            pending[id] = nil
            done(.failure(Failure(text: "The page is not there any more.")))
        }
    }

    /// Sends a command and waits for its answer, at most `seconds`.
    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], seconds: Double = 15) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            var answered = false
            send(method, params) { result in
                guard !answered else { return }
                answered = true
                continuation.resume(with: result)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                guard !answered else { return }
                answered = true
                continuation.resume(throwing: Failure(text: "The page did not answer \(method) within \(Int(seconds)) seconds."))
            }
        }
    }

    func received(result id: Int32, success: Bool, data: Data?) {
        guard let done = pending.removeValue(forKey: id) else { return }
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        if success {
            done(.success(object))
        } else {
            done(.failure(Failure(text: object["message"] as? String ?? "The page refused it.")))
        }
    }

    /// Turns on what is kept of the page: its console and its requests.
    func start() {
        for domain in ["Page.enable", "Runtime.enable", "Log.enable", "Network.enable", "DOM.enable"] {
            send(domain) { _ in }
        }
    }

    func received(event method: String, data: Data?) {
        let params = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        switch method {
        case "Page.frameNavigated":
            if let frame = params["frame"] as? [String: Any], frame["parentId"] == nil {
                document += 1
                loaded = false
                requests.removeAll { $0.done }
            }
        case "DOM.documentUpdated":
            document += 1
        case "Page.loadEventFired":
            loaded = true
        case "Page.screencastFrame":
            guard let session = params["sessionId"] as? Int else { return }
            if let base64 = params["data"] as? String, let jpeg = Data(base64Encoded: base64) { screencastFrame?(jpeg) }
            // The next one is sent once this one is acknowledged: in a
            // tenth of a second, as many as a device needs.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.screencastFrame != nil else { return }
                self.send("Page.screencastFrameAck", ["sessionId": session]) { _ in }
            }
        case "Runtime.consoleAPICalled":
            let level = params["type"] as? String ?? "log"
            let words = (params["args"] as? [[String: Any]] ?? []).map(Self.describe).joined(separator: " ")
            let frame = ((params["stackTrace"] as? [String: Any])?["callFrames"] as? [[String: Any]])?.first
            remember(ConsoleEntry(level: level, text: words, source: frame.map(Self.place)))
        case "Runtime.exceptionThrown":
            let details = params["exceptionDetails"] as? [String: Any] ?? [:]
            let exception = (details["exception"] as? [String: Any]).map(Self.describe)
            let text = exception ?? details["text"] as? String ?? "An error"
            remember(ConsoleEntry(level: "error", text: "Uncaught " + text, source: Self.place(details)))
        case "Log.entryAdded":
            let entry = params["entry"] as? [String: Any] ?? [:]
            remember(ConsoleEntry(level: entry["level"] as? String ?? "info", text: entry["text"] as? String ?? "", source: entry["url"] as? String))
        case "Network.requestWillBeSent":
            guard let id = params["requestId"] as? String, let request = params["request"] as? [String: Any] else { return }
            requests.removeAll { $0.id == id && $0.done == false && $0.status == nil }
            requests.append(Request(id: id, url: request["url"] as? String ?? "", method: request["method"] as? String ?? "GET", type: params["type"] as? String ?? ""))
            if requests.count > 400 { requests.removeFirst(requests.count - 400) }
        case "Network.responseReceived":
            guard let id = params["requestId"] as? String, let index = requests.lastIndex(where: { $0.id == id }) else { return }
            requests[index].status = (params["response"] as? [String: Any])?["status"] as? Int
        case "Network.loadingFinished":
            guard let id = params["requestId"] as? String, let index = requests.lastIndex(where: { $0.id == id }) else { return }
            requests[index].done = true
        case "Network.loadingFailed":
            guard let id = params["requestId"] as? String, let index = requests.lastIndex(where: { $0.id == id }) else { return }
            requests[index].done = true
            let canceled = params["canceled"] as? Bool ?? false
            requests[index].failure = canceled ? "canceled" : params["errorText"] as? String ?? "failed"
        case "Overlay.inspectNodeRequested":
            if let node = params["backendNodeId"] as? Int { picked?(node) }
        default:
            break
        }
    }

    private func remember(_ entry: ConsoleEntry) {
        console.append(entry)
        if console.count > 500 { console.removeFirst(console.count - 500) }
    }

    private static func describe(_ object: [String: Any]) -> String {
        if let value = object["value"] {
            if let text = value as? String { return text }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) { return String(decoding: data, as: UTF8.self) }
        }
        return object["description"] as? String ?? object["unserializableValue"] as? String ?? object["type"] as? String ?? ""
    }

    private static func place(_ frame: [String: Any]) -> String {
        let url = frame["url"] as? String ?? ""
        let line = (frame["lineNumber"] as? Int).map { ":\($0 + 1)" } ?? ""
        return url + line
    }

    // MARK: A snapshot of the page

    /// The roles an agent acts on: each gets a ref.
    private static let actionable: Set<String> = [
        "link", "button", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox", "option", "menuitem", "menuitemcheckbox",
        "menuitemradio", "tab", "switch", "slider", "spinbutton", "treeitem", "textfield", "TextField", "PopUpButton",
    ]
    /// Roles that say nothing of their own.
    private static let quiet: Set<String> = ["none", "generic", "InlineTextBox", "LineBreak", "presentation", "GenericContainer", "Section", "Ignored"]

    /// The page as text, by role and name, a ref for what can be acted on.
    func snapshot(within ref: String?) async throws -> String {
        let tree = try await call("Accessibility.getFullAXTree", [:], seconds: 20)
        let nodes = tree["nodes"] as? [[String: Any]] ?? []
        guard !nodes.isEmpty else { return "The page is empty." }
        var byID: [String: [String: Any]] = [:]
        for node in nodes { if let id = node["nodeId"] as? String { byID[id] = node } }
        if refsDocument != document {
            refs = [:]
            nextRef = 1
            refsDocument = document
        }
        var start = nodes.first { $0["parentId"] == nil } ?? nodes[0]
        if let ref {
            let backend = try node(for: ref)
            guard let found = nodes.first(where: { $0["backendDOMNodeId"] as? Int == backend }) else {
                throw Failure(text: BrowserWords.unknownRef(ref))
            }
            start = found
        }
        var lines: [String] = []
        var length = 0
        let limit = 40_000
        func value(_ node: [String: Any], _ key: String) -> String {
            ((node[key] as? [String: Any])?["value"]).map { "\($0)" } ?? ""
        }
        func walk(_ node: [String: Any], depth: Int, parentName: String) {
            guard length < limit else { return }
            let role = value(node, "role")
            let name = value(node, "name").trimmingCharacters(in: .whitespacesAndNewlines)
            let ignored = node["ignored"] as? Bool ?? false
            var shown = !ignored && !Self.quiet.contains(role)
            if role == "StaticText" || role == "text" {
                // Its words, unless they are what its parent is called.
                shown = !name.isEmpty && name != parentName
            }
            if role == "RootWebArea" || role == "WebArea" { shown = false }
            var nextDepth = depth
            if shown {
                var line = String(repeating: "  ", count: depth) + "- "
                if role == "StaticText" || role == "text" {
                    line += "text: " + Self.clip(name, 300)
                } else {
                    line += role
                    if !name.isEmpty { line += " \"" + Self.clip(name, 200).replacingOccurrences(of: "\"", with: "'") + "\"" }
                    var marks: [String] = []
                    for property in node["properties"] as? [[String: Any]] ?? [] {
                        let key = property["name"] as? String ?? ""
                        let raw = (property["value"] as? [String: Any])?["value"]
                        switch key {
                        case "level": if let raw { marks.append("level=\(raw)") }
                        case "checked", "pressed", "selected", "expanded":
                            if let raw, "\(raw)" != "false" { marks.append("\(key)" + ("\(raw)" == "true" ? "" : "=\(raw)")) }
                        case "disabled", "required", "focused", "readonly", "invalid":
                            if let raw, "\(raw)" == "true" { marks.append(key) }
                        default: break
                        }
                    }
                    let current = value(node, "value")
                    if !current.isEmpty { marks.append("value=\"\(Self.clip(current, 120))\"") }
                    if Self.actionable.contains(role), let backend = node["backendDOMNodeId"] as? Int {
                        let ref = "e\(nextRef)"
                        nextRef += 1
                        refs[ref] = backend
                        marks.append("ref=\(ref)")
                    }
                    if !marks.isEmpty { line += " [" + marks.joined(separator: "] [") + "]" }
                }
                lines.append(line)
                length += line.count + 1
                nextDepth = depth + 1
            }
            for child in node["childIds"] as? [String] ?? [] {
                if let next = byID[child] { walk(next, depth: nextDepth, parentName: shown ? name : parentName) }
            }
        }
        walk(start, depth: 0, parentName: "")
        if length >= limit { lines.append("… the page goes on; take a snapshot of a part with ref.") }
        // What a snapshot does not read: the insides of the page's frames,
        // said with their addresses so that one can be opened instead.
        if ref == nil,
            let frames = try? await evaluate("[...document.querySelectorAll('iframe, frame')].map(f => f.src || '(no address)')"),
            let data = frames.data(using: .utf8), let addresses = try? JSONDecoder().decode([String].self, from: data), !addresses.isEmpty
        {
            lines.append(BrowserWords.frames(addresses))
        }
        return lines.isEmpty ? "Nothing on the page can be read." : lines.joined(separator: "\n")
    }

    private static func clip(_ text: String, _ count: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > count ? String(flat.prefix(count)) + "…" : flat
    }

    /// The node a ref of the last snapshot names, if the page is still the
    /// one it was taken of.
    func node(for ref: String) throws -> Int {
        guard let backend = refs[ref] else { throw Failure(text: BrowserWords.unknownRef(ref)) }
        guard refsDocument == document else { throw Failure(text: BrowserWords.staleRef(ref)) }
        return backend
    }

    // MARK: Acting

    /// Where an element's middle is in the view, in its points, scrolled
    /// into view first.
    func center(of node: Int) async throws -> CGPoint {
        _ = try? await call("DOM.scrollIntoViewIfNeeded", ["backendNodeId": node])
        let model = try await call("DOM.getBoxModel", ["backendNodeId": node])
        guard let box = model["model"] as? [String: Any], let quad = box["content"] as? [Double] ?? box["border"] as? [Double], quad.count >= 8 else {
            throw Failure(text: "The element is not shown on the page, so it cannot be reached with the pointer.")
        }
        let xs = stride(from: 0, to: 8, by: 2).map { quad[$0] }, ys = stride(from: 1, to: 8, by: 2).map { quad[$0] }
        return CGPoint(x: xs.reduce(0, +) / 4, y: ys.reduce(0, +) / 4)
    }

    func mouse(_ type: String, at point: CGPoint, button: String = "left", clicks: Int = 1, deltaX: Double = 0, deltaY: Double = 0) async throws {
        var params: [String: Any] = ["type": type, "x": point.x, "y": point.y, "button": type == "mouseMoved" || type == "mouseWheel" ? "none" : button]
        if type == "mousePressed" || type == "mouseReleased" { params["clickCount"] = clicks }
        if type == "mouseWheel" {
            params["deltaX"] = deltaX
            params["deltaY"] = deltaY
        }
        try await call("Input.dispatchMouseEvent", params)
    }

    func click(_ node: Int, double: Bool) async throws {
        let point = try await center(of: node)
        try await mouse("mouseMoved", at: point)
        for count in double ? [1, 2] : [1] {
            try await mouse("mousePressed", at: point, clicks: count)
            try await mouse("mouseReleased", at: point, clicks: count)
        }
    }

    /// Runs a function on a node, `this` being the node, and returns its value.
    func run(_ function: String, on node: Int, arguments: [Any] = []) async throws -> Any? {
        let resolved = try await call("DOM.resolveNode", ["backendNodeId": node])
        guard let object = (resolved["object"] as? [String: Any])?["objectId"] as? String else { throw Failure(text: "The element is not there any more.") }
        let result = try await call(
            "Runtime.callFunctionOn",
            ["objectId": object, "functionDeclaration": function, "arguments": arguments.map { ["value": $0] }, "returnByValue": true, "awaitPromise": true, "userGesture": true])
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw Failure(text: ((exception["exception"] as? [String: Any])?["description"] as? String) ?? exception["text"] as? String ?? "It failed in the page.")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    func type(_ text: String, into node: Int, append: Bool, submit: Bool) async throws -> String? {
        _ = try? await call("DOM.focus", ["backendNodeId": node])
        if !append {
            // An editable element is emptied as a user empties it: all of it
            // selected, then a real Backspace, which an editor that keeps
            // its own state (Draft.js, as X's) handles itself. Emptied by
            // `execCommand`, its state kept its text and the node it draws
            // in was taken out of the page (#161).
            let hasText =
                try await run(
                    "function(){ this.focus(); if (this.isContentEditable) { const range = document.createRange(); range.selectNodeContents(this); const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); return this.innerText.trim().length > 0; } if ('value' in this) { this.select && this.select(); if (this.value) { this.value=''; this.dispatchEvent(new Event('input',{bubbles:true})); } } return false; }",
                    on: node) as? Bool ?? false
            if hasText { try await press("Backspace") }
        }
        // The caret in it, at the end of its last line, where a click would
        // put it: in its last text, its last empty block, or before its last
        // <br>. An editor that drew itself again keeps none of its own, and
        // after its last block nothing can be typed (#161).
        _ = try await run(
            "function(){ if (!this.isContentEditable) return; this.focus(); let at = this; while (at.lastChild && at.lastChild.nodeType === 1 && at.lastChild.nodeName !== 'BR') at = at.lastChild; const range = document.createRange(); const last = at.lastChild; if (last && last.nodeType === 3) range.setStart(last, last.length); else if (last && last.nodeName === 'BR') range.setStartBefore(last); else { range.selectNodeContents(at); range.collapse(false); } range.collapse(true); const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); }",
            on: node)
        try await call("Input.insertText", ["text": text])
        let value = try await run("function(){ return 'value' in this ? String(this.value) : this.innerText }", on: node) as? String
        // What shows nothing of what was typed did not take it: said, not
        // answered as holding "" (principle 3).
        if !text.isEmpty, (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure(text: BrowserWords.typedButNotShown)
        }
        if submit { try await press("Enter") }
        return value
    }

    /// Files chosen for a file field, as its dialog would choose them; the
    /// page is told they changed.
    func upload(_ paths: [String], into node: Int) async throws {
        let isFileField = try await run("function(){ return this.tagName === 'INPUT' && this.type === 'file'; }", on: node) as? Bool ?? false
        guard isFileField else { throw Failure(text: "That element is not a file field: give the ref of one (a button that chooses files).") }
        try await call("DOM.setFileInputFiles", ["files": paths, "backendNodeId": node])
    }

    func select(_ values: [String], in node: Int) async throws -> [String] {
        let picked = try await run(
            """
            function(wanted){
              if (!this.options) throw new Error('It is not a list of options.');
              const chosen = [];
              for (const option of this.options) {
                const take = wanted.includes(option.value) || wanted.includes(option.label) || wanted.includes(option.text.trim());
                if (take && (this.multiple || chosen.length === 0)) { option.selected = true; chosen.push(option.text.trim()); }
                else if (this.multiple) { option.selected = false; }
              }
              if (!chosen.length) throw new Error('None of its options is ' + wanted.join(', ') + '.');
              this.dispatchEvent(new Event('input',{bubbles:true}));
              this.dispatchEvent(new Event('change',{bubbles:true}));
              return chosen;
            }
            """, on: node, arguments: [values])
        return picked as? [String] ?? []
    }

    /// A key by name, with its modifiers: "Enter", "Control+A", "Meta+Shift+K".
    func press(_ combination: String) async throws {
        var parts = combination.split(separator: "+").map { String($0) }
        if combination.hasSuffix("++") { parts = parts.filter { !$0.isEmpty } + ["+"] }
        guard let name = parts.popLast() else { throw Failure(text: "No key was named.") }
        var modifiers = 0
        for part in parts {
            switch part.lowercased() {
            case "alt", "option": modifiers |= 1
            case "control", "ctrl": modifiers |= 2
            case "meta", "command", "cmd": modifiers |= 4
            case "shift": modifiers |= 8
            default: throw Failure(text: "There is no modifier called “\(part)”: Control, Alt, Shift or Meta.")
            }
        }
        guard let key = Self.keys(name, shift: modifiers & 8 != 0) else { throw Failure(text: "There is no key called “\(name)”.") }
        var down: [String: Any] = [
            "type": key.text == nil || modifiers & 6 != 0 ? "rawKeyDown" : "keyDown", "key": key.key, "code": key.code, "windowsVirtualKeyCode": key.code_, "modifiers": modifiers,
        ]
        if let text = key.text, modifiers & 6 == 0 {
            down["text"] = text
            down["unmodifiedText"] = text
        }
        try await call("Input.dispatchKeyEvent", down)
        try await call("Input.dispatchKeyEvent", ["type": "keyUp", "key": key.key, "code": key.code, "windowsVirtualKeyCode": key.code_, "modifiers": modifiers])
    }

    private struct Key {
        let key: String
        let code: String
        let code_: Int
        let text: String?
    }

    private static func keys(_ name: String, shift: Bool) -> Key? {
        let named: [String: Key] = [
            "enter": Key(key: "Enter", code: "Enter", code_: 13, text: "\r"), "return": Key(key: "Enter", code: "Enter", code_: 13, text: "\r"),
            "tab": Key(key: "Tab", code: "Tab", code_: 9, text: nil), "escape": Key(key: "Escape", code: "Escape", code_: 27, text: nil),
            "esc": Key(key: "Escape", code: "Escape", code_: 27, text: nil), "backspace": Key(key: "Backspace", code: "Backspace", code_: 8, text: nil),
            "delete": Key(key: "Delete", code: "Delete", code_: 46, text: nil), "space": Key(key: " ", code: "Space", code_: 32, text: " "),
            "arrowup": Key(key: "ArrowUp", code: "ArrowUp", code_: 38, text: nil), "arrowdown": Key(key: "ArrowDown", code: "ArrowDown", code_: 40, text: nil),
            "arrowleft": Key(key: "ArrowLeft", code: "ArrowLeft", code_: 37, text: nil), "arrowright": Key(key: "ArrowRight", code: "ArrowRight", code_: 39, text: nil),
            "up": Key(key: "ArrowUp", code: "ArrowUp", code_: 38, text: nil), "down": Key(key: "ArrowDown", code: "ArrowDown", code_: 40, text: nil),
            "left": Key(key: "ArrowLeft", code: "ArrowLeft", code_: 37, text: nil), "right": Key(key: "ArrowRight", code: "ArrowRight", code_: 39, text: nil),
            "home": Key(key: "Home", code: "Home", code_: 36, text: nil), "end": Key(key: "End", code: "End", code_: 35, text: nil),
            "pageup": Key(key: "PageUp", code: "PageUp", code_: 33, text: nil), "pagedown": Key(key: "PageDown", code: "PageDown", code_: 34, text: nil),
        ]
        if let key = named[name.lowercased().replacingOccurrences(of: " ", with: "")] { return key }
        guard name.count == 1, let character = name.first else { return nil }
        let text = shift ? name.uppercased() : name
        if character.isLetter, let ascii = character.uppercased().unicodeScalars.first?.value {
            return Key(key: text, code: "Key" + name.uppercased(), code_: Int(ascii), text: text)
        }
        if character.isNumber, let ascii = character.unicodeScalars.first?.value {
            return Key(key: text, code: "Digit" + name, code_: Int(ascii), text: text)
        }
        return Key(key: text, code: "", code_: 0, text: text)
    }

    /// What JavaScript gives, as JSON, or why it failed.
    func evaluate(_ script: String) async throws -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        func failed(_ result: [String: Any]) -> Failure? {
            guard let exception = result["exceptionDetails"] as? [String: Any] else { return nil }
            return Failure(text: ((exception["exception"] as? [String: Any])?["description"] as? String) ?? exception["text"] as? String ?? "It failed in the page.")
        }
        // REPL mode lets the script `await` at its top, and awaits only its
        // own promise: one the script gives is a value of it, and came back
        // as `{}` (#95). An object is asked for again, awaited when it is a
        // promise, and given as JSON.
        func run(_ expression: String) async throws -> [String: Any] {
            try await call("Runtime.evaluate", ["expression": expression, "awaitPromise": true, "userGesture": true, "replMode": true], seconds: 30)
        }
        var result = try await run(trimmed)
        // A function's body, with a return of its own: run as one. Told by
        // the page, not guessed from the text, where a return of a function
        // inside the script was taken for one (#95).
        if failed(result)?.text.contains("Illegal return statement") == true { result = try await run("(async () => { \(trimmed) })()") }
        if let failure = failed(result) { throw failure }
        if let object = (result["result"] as? [String: Any])?["objectId"] as? String {
            result = try await call(
                "Runtime.callFunctionOn",
                ["objectId": object, "functionDeclaration": "async function() { return await this; }", "returnByValue": true, "awaitPromise": true], seconds: 30)
            if let failure = failed(result) { throw failure }
        }
        let value = (result["result"] as? [String: Any]) ?? [:]
        if let raw = value["value"] {
            if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]) {
                let text = String(decoding: data, as: UTF8.self)
                return text.count > 30_000 ? String(text.prefix(30_000)) + "\n… cut at 30,000 characters" : text
            }
        }
        return value["description"] as? String ?? (value["type"] as? String == "undefined" ? "undefined" : "")
    }

    /// Waits until the page has loaded, at most `seconds`.
    func waitForLoad(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if loaded { return }
            if let state = try? await call("Runtime.evaluate", ["expression": "document.readyState", "returnByValue": true], seconds: 3),
                (state["result"] as? [String: Any])?["value"] as? String == "complete"
            {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// The page's title as the page has it now: Chromium tells the app a
    /// moment later.
    func pageTitle() async -> String? {
        let result = try? await call("Runtime.evaluate", ["expression": "document.title", "returnByValue": true], seconds: 5)
        return (result?["result"] as? [String: Any])?["value"] as? String
    }

    /// The text the page shows.
    func pageText() async -> String {
        let result = try? await call("Runtime.evaluate", ["expression": "document.body ? document.body.innerText : ''", "returnByValue": true], seconds: 5)
        return (result?["result"] as? [String: Any])?["value"] as? String ?? ""
    }

    func screenshot(clip: CGRect?, fullPage: Bool) async throws -> Data {
        var params: [String: Any] = ["format": "png"]
        if fullPage {
            let metrics = try await call("Page.getLayoutMetrics")
            let size = (metrics["cssContentSize"] as? [String: Any]) ?? (metrics["contentSize"] as? [String: Any]) ?? [:]
            let width = min(size["width"] as? Double ?? 1280, 4000), height = min(size["height"] as? Double ?? 800, 12_000)
            params = ["format": "jpeg", "quality": 80, "captureBeyondViewport": true, "clip": ["x": 0, "y": 0, "width": width, "height": height, "scale": 1]]
        } else if let clip {
            params["clip"] = ["x": clip.minX, "y": clip.minY, "width": max(clip.width, 1), "height": max(clip.height, 1), "scale": 1]
            params["captureBeyondViewport"] = true
        }
        let answer = try await call("Page.captureScreenshot", params, seconds: 30)
        guard let base64 = answer["data"] as? String, let data = Data(base64Encoded: base64) else { throw Failure(text: "The page gave no picture.") }
        return data
    }

    /// A picture of what the page shows, at most `width` pixels wide, as a
    /// JPEG, and the size in CSS pixels of what it shows, by which a touch
    /// on the picture is placed.
    func frame(width: Int) async throws -> (jpeg: Data, width: Double, height: Double) {
        let size = try await viewport()
        // What is drawn, as it is drawn: a clip, or a scale, has Chromium
        // lay the page out again for the picture (#100). Made smaller here
        // instead.
        let answer = try await call("Page.captureScreenshot", ["format": "jpeg", "quality": 55, "optimizeForSpeed": true], seconds: 10)
        guard let base64 = answer["data"] as? String, let data = Data(base64Encoded: base64) else { throw Failure(text: "The page gave no picture.") }
        return (Self.shrunk(data, width: max(width, 160)) ?? data, size.width, size.height)
    }

    /// The size in CSS pixels of what the page shows.
    func viewport() async throws -> (width: Double, height: Double) {
        let shown = try await call("Runtime.evaluate", ["expression": "[window.innerWidth, window.innerHeight]", "returnByValue": true], seconds: 5)
        guard let values = (shown["result"] as? [String: Any])?["value"] as? [Double], values.count == 2, values[0] > 0, values[1] > 0 else {
            throw Failure(text: "The page has no size yet.")
        }
        return (values[0], values[1])
    }

    /// What is streamed of the page: each picture Chromium draws, as a JPEG.
    private var screencastFrame: ((Data) -> Void)?

    /// Streams what the page draws as it draws it, at most `width` pixels
    /// wide and about ten pictures a second, to `frame`; nil stops it.
    func screencast(width: Int, _ frame: ((Data) -> Void)?) {
        let streaming = screencastFrame != nil
        screencastFrame = frame
        if frame != nil, !streaming {
            let wide = max(width, 160)
            send("Page.startScreencast", ["format": "jpeg", "quality": 55, "maxWidth": wide, "maxHeight": wide * 4, "everyNthFrame": 1]) { _ in }
        } else if frame == nil, streaming {
            send("Page.stopScreencast") { _ in }
        }
    }

    /// A JPEG made no wider than `width` pixels.
    static func shrunk(_ jpeg: Data, width: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let wide = properties[kCGImagePropertyPixelWidth] as? Int, let high = properties[kCGImagePropertyPixelHeight] as? Int, wide > 0
        else { return nil }
        guard wide > width else { return jpeg }
        let longest = (Double(max(wide, high)) * Double(width) / Double(wide)).rounded(.down)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: Int(longest), kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// A touch at a point of the page, in CSS pixels from its top left: a
    /// click of the mouse there, as the device's user means it.
    func tap(x: Double, y: Double) async throws {
        for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
            try await call(
                "Input.dispatchMouseEvent", ["type": type, "x": x, "y": y, "button": type == "mouseMoved" ? "none" : "left", "clickCount": type == "mouseMoved" ? 0 : 1],
                seconds: 5)
        }
    }

    /// Whether what has the keyboard in the page takes text: a field, a
    /// text area, something editable, or a frame of another site, whose
    /// insides are not seen.
    func fieldHasKeyboard() async throws -> Bool {
        let script = """
            (() => {
              let e = document.activeElement;
              for (;;) {
                if (e && e.shadowRoot && e.shadowRoot.activeElement) { e = e.shadowRoot.activeElement; continue; }
                if (e && (e.tagName === 'IFRAME' || e.tagName === 'FRAME')) {
                  let inner = null;
                  try { inner = e.contentDocument && e.contentDocument.activeElement; } catch (_) {}
                  if (!inner) return true;
                  e = inner; continue;
                }
                break;
              }
              if (!e || e === document.body) return false;
              if (e.isContentEditable) return true;
              if (e.tagName === 'TEXTAREA') return !e.readOnly && !e.disabled;
              if (e.tagName !== 'INPUT') return false;
              const kind = (e.type || 'text').toLowerCase();
              return !e.readOnly && !e.disabled && !['button', 'checkbox', 'radio', 'submit', 'reset', 'file', 'image', 'range', 'color', 'hidden'].includes(kind);
            })()
            """
        let answer = try await call("Runtime.evaluate", ["expression": script, "returnByValue": true], seconds: 5)
        return ((answer["result"] as? [String: Any])?["value"] as? Bool) ?? false
    }

    /// An element's box in the page, in its points.
    func box(of node: Int) async throws -> CGRect {
        _ = try? await call("DOM.scrollIntoViewIfNeeded", ["backendNodeId": node])
        let model = try await call("DOM.getBoxModel", ["backendNodeId": node])
        guard let box = model["model"] as? [String: Any], let quad = box["border"] as? [Double], quad.count >= 8 else {
            throw Failure(text: "The element is not shown on the page.")
        }
        let xs = stride(from: 0, to: 8, by: 2).map { quad[$0] }, ys = stride(from: 1, to: 8, by: 2).map { quad[$0] }
        // In the page, not the view: the picture of an element is taken of the page.
        let scroll = try? await call("Runtime.evaluate", ["expression": "[window.scrollX, window.scrollY]", "returnByValue": true])
        let offset = (scroll?["result"] as? [String: Any])?["value"] as? [Double] ?? [0, 0]
        return CGRect(x: xs.min()! + offset[0], y: ys.min()! + offset[1], width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Shows the page as `device` does, or as itself. `room`: the size in
    /// points of the pane it is shown in. A device whose screen is taller
    /// has the pane's height, the rest of the page reached by scrolling:
    /// what the Mac draws is whole and sharp, and so are the pictures the
    /// devices watching it are sent, which are what the Mac draws (#107).
    func emulate(_ device: BrowserDevice?, room: CGSize?) async throws {
        guard let device else {
            _ = try? await call("Emulation.clearDeviceMetricsOverride")
            _ = try? await call("Emulation.setUserAgentOverride", ["userAgent": ""])
            _ = try? await call("Emulation.setTouchEmulationEnabled", ["enabled": false])
            _ = try? await call("Emulation.clearGeolocationOverride")
            return
        }
        if device.width > 0, device.height > 0 {
            try await call("Emulation.setDeviceMetricsOverride", Self.metrics(of: device, in: room))
        }
        // The user agent with what goes with it, as the device gives it:
        // its client hints, as Chrome's DevTools give them, and
        // `navigator.platform`, which DevTools leave the Mac's.
        if let agent = device.userAgent(chromeMajor: Int(atc_chrome_major())) {
            var override: [String: Any] = ["userAgent": agent]
            if let platform = device.platform { override["platform"] = platform }
            if let hints = device.hints {
                override["userAgentMetadata"] = [
                    "platform": hints.platform, "platformVersion": hints.platformVersion, "architecture": hints.architecture, "model": hints.model,
                    "mobile": hints.mobile,
                ]
            }
            try await call("Emulation.setUserAgentOverride", override)
        }
        try await call("Emulation.setTouchEmulationEnabled", ["enabled": device.touch, "maxTouchPoints": device.touch ? 5 : 0])
        if let latitude = device.latitude, let longitude = device.longitude {
            try await call("Emulation.setGeolocationOverride", ["latitude": latitude, "longitude": longitude, "accuracy": 50])
        }
    }

    /// The pane changed size: the device's screen as tall as it again.
    func fit(_ device: BrowserDevice, in room: CGSize) async {
        guard device.width > 0, device.height > 0 else { return }
        _ = try? await call("Emulation.setDeviceMetricsOverride", Self.metrics(of: device, in: room))
    }

    /// A device's screen as the page is shown in a pane of `room`: as wide
    /// as the device's, and as tall as it or as the pane, whichever is
    /// less, never drawn smaller (the owner's decision, 2026-11-16): what
    /// is below is reached by scrolling the page, what is drawn has all its
    /// pixels, and so has what is streamed of it. The page is still told
    /// the device's whole screen (`screen.width`, `screen.height`).
    static func metrics(of device: BrowserDevice, in room: CGSize?) -> [String: Any] {
        var high = device.height
        if let room, room.height >= 1 { high = min(device.height, Int(room.height.rounded(.down))) }
        return [
            "width": device.width, "height": max(high, 1), "deviceScaleFactor": device.scale, "mobile": device.mobile,
            "screenWidth": device.width, "screenHeight": device.height,
        ]
    }

    // MARK: Picking an element for an agent

    /// Lets the user point at an element of the page; `done` gets it.
    func pickElement(_ done: @escaping (Int) -> Void) {
        picked = { [weak self] node in
            self?.picked = nil
            self?.send("Overlay.setInspectMode", ["mode": "none", "highlightConfig": [:]]) { _ in }
            done(node)
        }
        send("Overlay.enable") { _ in }
        send(
            "Overlay.setInspectMode",
            [
                "mode": "searchForNode",
                "highlightConfig": [
                    "showInfo": true, "contentColor": ["r": 111, "g": 168, "b": 220, "a": 0.55], "borderColor": ["r": 50, "g": 120, "b": 220, "a": 0.9],
                ],
            ]
        ) { _ in }
    }

    func stopPicking() {
        picked = nil
        send("Overlay.setInspectMode", ["mode": "none", "highlightConfig": [:]]) { _ in }
    }

    /// What an element is, for an agent: a selector, its HTML and the styles
    /// that usually matter.
    func describe(_ node: Int) async -> String {
        let script = """
            function(){
              const path = [];
              for (let e = this; e && e.nodeType === 1 && path.length < 6; e = e.parentElement) {
                let part = e.localName;
                if (e.id) { path.unshift(part + '#' + e.id); break; }
                const cls = [...e.classList].slice(0, 2).map(c => '.' + c).join('');
                const same = e.parentElement ? [...e.parentElement.children].filter(c => c.localName === e.localName) : [];
                part += cls + (same.length > 1 ? ':nth-of-type(' + (same.indexOf(e) + 1) + ')' : '');
                path.unshift(part);
              }
              const style = getComputedStyle(this);
              const keep = ['display','position','width','height','margin','padding','color','background-color','font-family','font-size','font-weight','line-height','border','border-radius','gap','flex-direction','justify-content','align-items','z-index','overflow'];
              const styles = keep.map(k => k + ': ' + style.getPropertyValue(k)).join('; ');
              let html = this.outerHTML || '';
              if (html.length > 3000) html = html.slice(0, 3000) + '…';
              return 'Selector: ' + path.join(' > ') + '\\nStyles: ' + styles + '\\nHTML: ' + html;
            }
            """
        return (try? await run(script, on: node)) as? String ?? ""
    }
}
