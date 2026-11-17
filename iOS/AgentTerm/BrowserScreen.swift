import AgentTermProtocol
import AgentTermTerminal
import SwiftUI
import UIKit

/// The pages of the browser in AgentTerm on the Mac (#76) that no folder
/// shows: an agent's are under it, the user's in their project's folder.
struct BrowserSection: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var shown: PageSheetID?

    var body: some View {
        let pages = model.loosePages
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Browser on the Mac")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(pages) { tab in
                        Button {
                            shown = PageSheetID(id: tab.id)
                        } label: {
                            BrowserTabRow(tab: tab)
                        }
                        .buttonStyle(.plain)
                        if tab.id != pages.last?.id { Divider().padding(.leading, 44) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
            }
            .sheet(item: $shown) { page in
                BrowserTabSheet(tabID: page.id)
            }
            .accessibilityIdentifier("browser-tabs")
        }
    }
}

/// Which page a sheet shows.
struct PageSheetID: Identifiable, Hashable {
    let id: String
}

/// A page's row in a list: its title, and whose it is unless it is shown
/// under its agent.
struct BrowserTabRow: View {
    @EnvironmentObject private var model: PhoneModel
    let tab: BrowserTabInfo
    /// Set in under its agent, which it is shown under: it is not named.
    var nested = false
    /// Set in under the Browser heading of the user's pages (#127).
    var indented = false

    private var owner: String {
        let whose: String
        if let agent = tab.openedBy {
            let name = model.sessions.first { $0.id == agent }?.displayName ?? "An agent"
            if nested { whose = tab.userHasIt ? "You have it" : "Its agent's" } else { whose = tab.userHasIt ? "\(name)'s · you have it" : "\(name)'s" }
        } else {
            whose = "Yours"
        }
        // Which profile, when the user keeps several, or private.
        let profile = tab.isPrivate || model.browserProfiles.count > 1 ? " · \(tab.profile)" : ""
        return whose + profile
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.loading ? "arrow.triangle.2.circlepath" : tab.isPrivate ? "eye.slash" : "globe")
                .foregroundStyle(tab.openedBy != nil ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayTitle).font(.body).lineLimit(1)
                Text(owner + (tab.emulating.map { " · as \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.leading, nested || indented ? 38 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browser-tab-\(tab.id)")
    }
}

/// One page of the user's, in a sheet: live, and used by touch.
struct BrowserTabSheet: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    let tabID: String
    /// Whether the tab was in the Mac's list once: one just opened is not
    /// there yet, one that went was closed.
    @State private var seen = false

    private var tab: BrowserTabInfo? { model.browserTabs.first { $0.id == tabID } }

    var body: some View {
        NavigationStack {
            Group {
                if tab != nil {
                    LivePageView(tabID: tabID) { dismiss() }
                } else if seen {
                    Text("This tab was closed on the Mac.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LoadingView("Opening the page on the Mac…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(tab?.displayTitle ?? "Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if tab != nil { seen = true } }
        .onChange(of: tab != nil) { _, there in if there { seen = true } }
    }
}

/// A page of the Mac's browser as it is now, sent about ten times a second
/// while it is on screen, and used by touch, as on the Mac (#76): a touch
/// clicks where it lands, and on a field brings the keyboard up, whose keys
/// go to the page; a drag scrolls it; two fingers zoom into the picture.
/// The address bar, back, forward, reload and stop, Show As and Close Tab
/// are those of the Mac's browser. An agent's tab becomes the user's at the
/// first thing done to its page, as a click on the Mac makes it; its agent
/// waits until it is given back.
struct LivePageView: View {
    @EnvironmentObject private var model: PhoneModel
    let tabID: String
    /// After Close Tab: what shows the page goes.
    var closed: () -> Void = {}

    /// The keyboard is up for the page.
    @State private var typing = false
    @State private var address = ""
    @FocusState private var editingAddress: Bool
    /// Into the picture, 1 to 4 times, and moved about while zoomed.
    @State private var zoom: CGFloat = 1
    @State private var zoomBefore: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBefore: CGSize = .zero
    /// What of a drag was already sent to the page as scrolling.
    @State private var scrolled: CGSize = .zero
    @State private var typed = TypedText()

    private var tab: BrowserTabInfo? { model.browserTabs.first { $0.id == tabID } }

    var body: some View {
        VStack(spacing: 0) {
            if let tab, let agent = tab.openedBy.flatMap({ id in model.sessions.first { $0.id == id } }) {
                HStack {
                    Text(tab.userHasIt ? BrowserWords.userHas : BrowserWords.agentDrives(agent.displayName))
                        .font(.footnote)
                        .lineLimit(2)
                    Spacer()
                    Button(tab.userHasIt ? BrowserWords.giveBack(agent.displayName) : BrowserWords.takeOver) {
                        model.setUserHas(tab.id, !tab.userHasIt)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("browser-control")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background((tab.userHasIt ? Color.orange : Color.accentColor).opacity(0.14))
            }
            toolbar
            page
            if let problem = model.browserProblems[tabID] {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Palette.panel)
                    .accessibilityIdentifier("browser-problem")
            }
        }
        .background {
            PageKeyInput(active: $typing, text: { typed.add($0) }, key: press)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("browser-keys")
        }
        .onAppear {
            let tab = tabID
            typed.send = { [weak model] text in model?.useBrowser(.text(tab: tab, text: text)) }
            model.watch(tabID, true)
            address = Self.shown(self.tab?.url)
            // A new tab, empty: where it goes is asked first.
            if address.isEmpty { editingAddress = true }
        }
        .onDisappear {
            typed.flush()
            model.watch(tabID, false)
        }
        .onChange(of: tab?.url) { _, url in
            if !editingAddress { address = Self.shown(url) }
        }
        .onChange(of: editingAddress) { _, editing in
            if editing { typing = false } else { address = Self.shown(tab?.url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { note in
            // All of the address chosen, as in Safari: what is typed takes its place.
            guard let field = note.object as? UITextField, field.accessibilityIdentifier == "browser-address" else { return }
            DispatchQueue.main.async { field.selectAll(nil) }
        }
    }

    /// The address shown in the bar: none for an empty tab.
    private static func shown(_ url: String?) -> String {
        guard let url, url != "about:blank" else { return "" }
        return url
    }

    // MARK: The bar

    private var toolbar: some View {
        HStack(spacing: 2) {
            barButton("chevron.left", "Back") { model.useBrowser(.history(tab: tabID, step: -1)) }
            barButton("chevron.right", "Forward") { model.useBrowser(.history(tab: tabID, step: 1)) }
            if tab?.loading == true {
                barButton("xmark", "Stop") { model.useBrowser(.stop(tab: tabID)) }
            } else {
                barButton("arrow.clockwise", "Reload") { model.useBrowser(.history(tab: tabID, step: 0)) }
            }
            TextField("Address or search", text: $address)
                .font(.callout)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($editingAddress)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
                .onSubmit {
                    let wanted = address.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !wanted.isEmpty else { return }
                    model.useBrowser(.navigate(tab: tabID, url: wanted))
                }
                .accessibilityIdentifier("browser-address")
                .padding(.horizontal, 4)
            barButton(typing ? "keyboard.chevron.compact.down" : "keyboard", typing ? "Hide Keyboard" : "Type into the Page") {
                typing.toggle()
                if typing { editingAddress = false }
            }
            .accessibilityIdentifier("browser-keyboard")
            Menu {
                showAs
                Divider()
                Button(role: .destructive) {
                    model.useBrowser(.close(tab: tabID)) { result in
                        if case .refused = result { return }
                        closed()
                    }
                } label: {
                    Label("Close Tab", systemImage: "xmark.square")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Page Menu")
            .accessibilityIdentifier("browser-menu")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(Palette.panel)
    }

    private func barButton(_ symbol: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    /// The devices the page can be shown as, as the Mac's Show As menu has them.
    @ViewBuilder private var showAs: some View {
        Menu {
            Button {
                emulate(nil)
            } label: {
                if tab?.emulating == nil { Label("As Itself", systemImage: "checkmark") } else { Text("As Itself") }
            }
            ForEach(BrowserDevice.Kind.allCases, id: \.self) { kind in
                Section(Self.title(of: kind)) {
                    ForEach(BrowserDevice.presets.filter { $0.kind == kind }, id: \.name) { device in
                        Button {
                            emulate(device)
                        } label: {
                            if tab?.emulating == device.name { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                        }
                    }
                }
            }
        } label: {
            Label(tab?.emulating.map { "Show As: \($0)" } ?? "Show As", systemImage: "iphone")
        }
    }

    private static func title(of kind: BrowserDevice.Kind) -> String {
        switch kind {
        case .phone: return "Phones"
        case .tablet: return "Tablets"
        case .computer: return "Computers"
        }
    }

    private func emulate(_ device: BrowserDevice?) {
        model.useBrowser(.emulate(tab: tabID, device: device))
    }

    // MARK: The page

    private var page: some View {
        GeometryReader { room in
            if let frame = model.browserFrames[tabID], frame.width > 0, frame.height > 0 {
                // The page fitted to the room, top first: its CSS pixels to
                // this screen's points. In the picture's own shape, never
                // squeezed into another: what the Mac shows of the page is
                // what is here, and the rest is reached by scrolling it.
                let picture = frame.image.size
                let high = picture.width > 0 && picture.height > 0 ? frame.width * picture.height / picture.width : frame.height
                let fit = min(room.size.width / frame.width, room.size.height / high)
                let shown = CGSize(width: frame.width * fit, height: high * fit)
                Image(uiImage: frame.image)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .contentShape(Rectangle())
                    // Where it lands on the picture, whatever its zoom.
                    .gesture(SpatialTapGesture().onEnded { touch in tap(at: touch.location, fit: fit, page: frame) })
                    .scaleEffect(zoom)
                    .offset(pan)
                    .frame(width: room.size.width, height: room.size.height, alignment: .top)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(drag(fit: fit, shown: shown))
                    .simultaneousGesture(magnify(shown: shown))
                    .overlay(alignment: .topTrailing) {
                        if zoom > 1.01 {
                            Button("1×") {
                                withAnimation(.snappy) {
                                    zoom = 1
                                    zoomBefore = 1
                                    pan = .zero
                                    panBefore = .zero
                                }
                            }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .padding(8)
                            .accessibilityLabel("Fit the Page")
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("The page, live")
                    .accessibilityValue("\(Int(frame.width))×\(Int(frame.height))")
                    .accessibilityIdentifier("browser-live")
            } else {
                LoadingView("Asking the Mac for the page…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.canvas)
    }

    private func tap(at point: CGPoint, fit: CGFloat, page: PhoneModel.BrowserFrame) {
        editingAddress = false
        typed.flush()
        // A finger a little past the picture's edge, which iOS still counts
        // as on it, means the edge, not a point outside the page.
        let x = min(max(point.x / fit, 0), page.width - 1), y = min(max(point.y / fit, 0), page.height - 1)
        model.useBrowser(.tap(tab: tabID, x: x, y: y)) { result in
            // A field took the keyboard: this one comes up for it.
            if case .touched(let field) = result { typing = field }
        }
    }

    /// Scrolls the page as the finger goes; moves the picture when zoomed.
    private func drag(fit: CGFloat, shown: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { drag in
                if zoom > 1.01 {
                    pan = Self.clamped(CGSize(width: panBefore.width + drag.translation.width, height: panBefore.height + drag.translation.height), zoom: zoom, shown: shown)
                    return
                }
                let step = CGSize(width: drag.translation.width - scrolled.width, height: drag.translation.height - scrolled.height)
                guard abs(step.width) >= 24 || abs(step.height) >= 24 else { return }
                scrolled = drag.translation
                model.useBrowser(.scroll(tab: tabID, ref: nil, x: -step.width / fit / zoom, y: -step.height / fit / zoom))
            }
            .onEnded { drag in
                if zoom > 1.01 {
                    panBefore = pan
                } else {
                    let step = CGSize(width: drag.translation.width - scrolled.width, height: drag.translation.height - scrolled.height)
                    if abs(step.width) >= 1 || abs(step.height) >= 1 {
                        model.useBrowser(.scroll(tab: tabID, ref: nil, x: -step.width / fit, y: -step.height / fit))
                    }
                }
                scrolled = .zero
            }
    }

    private func magnify(shown: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(4, max(1, zoomBefore * value.magnification))
                pan = Self.clamped(pan, zoom: zoom, shown: shown)
            }
            .onEnded { _ in
                zoomBefore = zoom
                if zoom <= 1.01 {
                    zoom = 1
                    zoomBefore = 1
                    pan = .zero
                }
                panBefore = pan
            }
    }

    /// Moved no further than the zoomed picture goes past its room.
    private static func clamped(_ pan: CGSize, zoom: CGFloat, shown: CGSize) -> CGSize {
        let most = CGSize(width: (zoom - 1) * shown.width / 2, height: (zoom - 1) * shown.height / 2)
        return CGSize(width: min(most.width, max(-most.width, pan.width)), height: min(most.height, max(-most.height, pan.height)))
    }

    private func press(_ key: String) {
        typed.flush()
        model.useBrowser(.press(tab: tabID, key: key))
    }
}

/// What is typed into a page, sent a few characters at a time rather than
/// one message for each.
@MainActor
final class TypedText {
    var send: ((String) -> Void)?
    private var pending = ""
    private var later: DispatchWorkItem?

    func add(_ text: String) {
        pending += text
        later?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        later = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    func flush() {
        later?.cancel()
        later = nil
        guard !pending.isEmpty else { return }
        let text = pending
        pending = ""
        send?(text)
    }
}

/// The keyboard of the iPhone, or the one of an iPad, for a page: what is
/// typed goes to what has the keyboard in it, Delete and Return as keys,
/// and on a keyboard of its own the arrows, Tab and Escape too.
struct PageKeyInput: UIViewRepresentable {
    @Binding var active: Bool
    let text: (String) -> Void
    let key: (String) -> Void

    func makeUIView(context: Context) -> PageKeyView { PageKeyView() }

    func updateUIView(_ view: PageKeyView, context: Context) {
        view.onText = text
        view.onKey = key
        let active = $active
        view.onResign = { if active.wrappedValue { active.wrappedValue = false } }
        if self.active, !view.isFirstResponder {
            DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        } else if !self.active, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }
}

final class PageKeyView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onKey: ((String) -> Void)?
    var onResign: (() -> Void)?

    // As typed: the page's own field does what it does with it.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.onResign?() } }
        return resigned
    }

    /// Always some, so that Delete is always sent: the text is the page's.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" {
            onKey?("Enter")
        } else if text == "\t" {
            onKey?("Tab")
        } else {
            onText?(text)
        }
    }

    func deleteBackward() { onKey?("Backspace") }

    private static let keys: [UIKeyboardHIDUsage: String] = [
        .keyboardUpArrow: "ArrowUp", .keyboardDownArrow: "ArrowDown", .keyboardLeftArrow: "ArrowLeft", .keyboardRightArrow: "ArrowRight",
        .keyboardEscape: "Escape", .keyboardTab: "Tab", .keyboardPageUp: "PageUp", .keyboardPageDown: "PageDown", .keyboardHome: "Home",
        .keyboardEnd: "End",
    ]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let named = presses.compactMap { press in press.key.flatMap { Self.keys[$0.keyCode] } }
        guard !named.isEmpty else { return super.pressesBegan(presses, with: event) }
        named.forEach { onKey?($0) }
    }
}
