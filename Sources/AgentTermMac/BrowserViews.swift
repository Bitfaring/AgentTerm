import AgentTermProtocol
import SwiftUI

/// A tab of the browser in a pane (#76): its bar, what an agent is doing in
/// it, what the page asks, and the page.
struct BrowserPaneView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: BrowserTab
    let focused: Bool
    @State private var address = ""
    @State private var editing = false
    @FocusState private var addressFocused: Bool
    @State private var finding = false
    @State private var findText = ""

    /// The least width its bar's buttons, address and names are whole in.
    static let barWidth: CGFloat = 460

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Theme.hairline.frame(height: 1)
            AgentBar(tab: tab)
            if let permission = tab.permission { PermissionBar(tab: tab, origin: permission.origin, what: permission.what) }
            if finding { findBar }
            ZStack {
                // Shown as a device: the page as wide and as tall as its
                // screen, no white beside it. The same views either way, so
                // that the page's is not made again.
                let device = tab.emulating.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
                BrowserHost(tab: tab, focused: focused)
                    .background(PaneFrameReader(place: .page(tab.tabID)))
                    .frame(maxWidth: device.map { CGFloat($0.width) } ?? .infinity, maxHeight: device.map { CGFloat($0.height) } ?? .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if let problem = tab.problem {
                    message("globe", "The browser cannot show this page", problem, retry: false)
                } else if tab.crashed {
                    message("exclamationmark.triangle", "The page's process stopped", "Reload to open it again.", retry: true)
                } else if let error = tab.loadError {
                    message("wifi.exclamationmark", Self.headline(for: error.url), Self.words(for: error), retry: true)
                }
            }
            DownloadsBar(tab: tab)
        }
        .background(Theme.canvas)
        .onAppear { address = tab.url }
        .onChange(of: tab.url) { _, url in if !editing { address = url } }
        .onChange(of: model.browserAddressRequest) { _, _ in if focused { addressFocused = true } }
        .onChange(of: model.browserFindRequest) { _, _ in if focused { finding = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-\(tab.id)")
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                tab.back()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!tab.canGoBack)
            .help("Back (⌘[)")
            .accessibilityLabel("Back")
            Button {
                tab.forward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!tab.canGoForward)
            .help("Forward (⌘])")
            .accessibilityLabel("Forward")
            Button {
                tab.loading ? tab.stop() : tab.reload()
            } label: {
                Image(systemName: tab.loading ? "xmark" : "arrow.clockwise")
            }
            .help(tab.loading ? "Stop" : "Reload (⌘R)")
            .accessibilityLabel(tab.loading ? "Stop" : "Reload")
            // The page's two modes, in sight: browsing, or picking its
            // elements to send to an agent with a note.
            Button {
                model.setPicking(tab, !tab.picking)
            } label: {
                Label(tab.picking ? "Picking" : "Pick", systemImage: "cursorarrow.rays")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tab.picking ? Color.white : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tab.picking ? Color.accentColor : Color.white.opacity(0.08)))
            }
            .help(
                tab.picking
                    ? "Picking: click an element of the page to send it to an agent with a note. Press to browse again."
                    : "Pick an element of the page, a button or a view, to send to an agent with what to do with it"
            )
            .accessibilityLabel(tab.picking ? "Stop Picking" : "Pick an Element for an Agent")
            .accessibilityIdentifier("browser-pick")
            TextField("Address or search", text: $address, onEditingChanged: { editing = $0 })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($addressFocused)
                .onSubmit {
                    tab.load(address)
                    editing = false
                    tab.focus()
                }
                .accessibilityIdentifier("browser-address")
            // Which profile's sign-ins it uses, or none: a private tab.
            let isPrivate = BrowserProfiles.isPrivate(tab.profile)
            let profileName = isPrivate ? BrowserWords.privateProfile : model.profiles.profile(tab.profile)?.name ?? ""
            Label(profileName, systemImage: isPrivate ? "eye.slash" : "person.crop.circle")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(isPrivate ? Color.purple.opacity(0.28) : Color.white.opacity(0.08)))
                .help(
                    isPrivate
                        ? "A private tab: it keeps nothing, has none of the profiles' sign-ins, and what it has is gone with the last private tab"
                        : "Uses the profile “\(profileName)”: its sign-ins, cookies and cache"
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(profileName)
                .accessibilityValue(profileName)
                .accessibilityIdentifier("browser-profile")
            ShowAsButton(tab: tab)
            Menu {
                Button("Find in Page…") { finding = true }
                Divider()
                Button("Zoom In") { tab.setZoom(tab.zoom + 0.5) }
                Button("Zoom Out") { tab.setZoom(tab.zoom - 0.5) }
                Button("Actual Size") { tab.setZoom(0) }
                Divider()
                Button("Developer Tools") { tab.showDevTools() }
                Divider()
                Button("Close Tab") { model.closeBrowserTab(tab) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Browser")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.panel)
        .overlay(alignment: .bottom) {
            if tab.loading, tab.progress < 1 {
                GeometryReader { proxy in Color.accentColor.frame(width: proxy.size.width * max(0.05, tab.progress), height: 2) }.frame(height: 2)
            }
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            TextField("Find in page", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit { tab.find(findText, next: true) }
                .onChange(of: findText) { _, text in tab.find(text) }
            Text(tab.findCount == 0 ? (findText.isEmpty ? "" : "Not found") : "\(tab.findActive) of \(tab.findCount)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                tab.find(findText, forward: false, next: true)
            } label: {
                Image(systemName: "chevron.up")
            }
            .accessibilityLabel("Previous")
            Button {
                tab.find(findText, next: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .accessibilityLabel("Next")
            Spacer()
            Button("Done") {
                finding = false
                findText = ""
                tab.stopFinding()
            }
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }

    private func message(_ symbol: String, _ title: String, _ text: String, retry: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            if retry { Button("Reload") { tab.reload() } }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    static func headline(for url: String) -> String {
        "This page did not load"
    }

    /// Why a page did not load, and for a development server of the Mac,
    /// what to do about it.
    static func words(for error: (code: Int32, text: String, url: String)) -> String {
        let host = URL(string: error.url)?.host ?? ""
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local")
        // net::ERR_CONNECTION_REFUSED
        if local, error.code == -102 { return BrowserWords.nothingAnswers(error.url) }
        return "\(error.url)\n\(error.text.isEmpty ? "Error \(error.code)" : error.text)"
    }
}

/// Over a tab an agent opened, which it alone drives: which agent, what it
/// did last, and taking it over or giving it back (#76).
private struct AgentBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: BrowserTab

    var body: some View {
        let agents = model.agentNames(of: tab)
        if !agents.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: tab.userHasIt ? "hand.raised.fill" : "sparkles")
                    .foregroundStyle(tab.userHasIt ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.userHasIt ? BrowserWords.userHas : BrowserWords.agentDrives(agents))
                        .font(.system(size: 12, weight: .medium))
                    if let action = tab.agentAction, !tab.userHasIt {
                        Text(action).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer()
                Button(tab.userHasIt ? BrowserWords.giveBack(agents) : BrowserWords.takeOver) { model.setUserHas(tab, !tab.userHasIt) }
                    .controlSize(.small)
                    .accessibilityIdentifier("browser-control")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background((tab.userHasIt ? Color.orange : Color.accentColor).opacity(0.12))
            .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("browser-agent-bar")
        }
    }
}

/// A page asks for something only the user decides: an agent never answers it.
private struct PermissionBar: View {
    @ObservedObject var tab: BrowserTab
    let origin: String
    let what: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.yellow)
            Text("\(URL(string: origin)?.host ?? origin) wants \(what).").font(.system(size: 12))
            Spacer()
            Button("Don't Allow") { tab.answerPermission(false) }
            Button("Allow") { tab.answerPermission(true) }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.yellow.opacity(0.12))
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-permission")
    }
}

private struct DownloadsBar: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        if !tab.downloads.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tab.downloads) { download in
                        HStack(spacing: 6) {
                            Image(systemName: download.state == 1 ? "checkmark.circle" : download.state == 2 ? "xmark.circle" : "arrow.down.circle")
                                .foregroundStyle(download.state == 2 ? Color.red : .secondary)
                            Text((download.path as NSString).lastPathComponent).font(.system(size: 11)).lineLimit(1)
                            if download.state == 0 {
                                Text(download.percent >= 0 ? "\(download.percent)%" : "…").font(.system(size: 11)).foregroundStyle(.secondary)
                                Button {
                                    tab.cancelDownload(download)
                                } label: {
                                    Image(systemName: "xmark")
                                }.buttonStyle(.plain)
                            } else if download.state == 1 {
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: download.path)]) }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                    Button("Clear") { tab.downloads.removeAll { $0.state != 0 } }.buttonStyle(.link).font(.system(size: 11))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .background(Theme.panel)
            .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        }
    }
}

/// Which device the page is shown as, on its bar, in sight: pressed, the
/// devices by kind, with their screens, the one in use marked, and the Mac
/// itself first. Picking one shows the page as it at once.
struct ShowAsButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: BrowserTab
    @State private var choosing = false
    @State private var search = ""

    private static func symbol(_ kind: BrowserDevice.Kind?) -> String {
        switch kind {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .computer: return "laptopcomputer"
        case nil: return "macbook.and.iphone"
        }
    }

    var body: some View {
        let device = tab.emulating
        Button {
            choosing.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: Self.symbol(device?.kind)).font(.system(size: 10.5, weight: .semibold))
                if let device {
                    Text(device.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(device != nil ? Color.accentColor.opacity(0.32) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(device.map { "Shown as \($0.name), \($0.width) × \($0.height). Press to show it as another device, or as this Mac." } ?? "Show the page as a phone, a tablet or another computer")
        .accessibilityLabel("Show As")
        .accessibilityValue(device?.name ?? "This Mac")
        .accessibilityIdentifier("browser-show-as")
        .popover(isPresented: $choosing, arrowEdge: .bottom) { list }
    }

    private var list: some View {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        return VStack(alignment: .leading, spacing: 0) {
            TextField("Device", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .padding(8)
            Theme.hairline.frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if words.isEmpty {
                        row("This Mac", detail: "the page as it is", symbol: "macbook", chosen: tab.emulating == nil, id: "show-as-this-mac") { pick(nil) }
                    }
                    ForEach([("Phones", BrowserDevice.Kind.phone), ("Tablets", .tablet), ("Computers", .computer)], id: \.0) { title, kind in
                        let devices = BrowserDevice.presets.filter { $0.kind == kind && (words.isEmpty || $0.name.lowercased().contains(words)) }
                        if !devices.isEmpty {
                            Text(title.uppercased())
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                            ForEach(devices, id: \.name) { device in
                                row(
                                    device.name, detail: "\(device.width) × \(device.height)", symbol: Self.symbol(kind), chosen: tab.emulating?.name == device.name,
                                    id: "show-as-\(device.name)"
                                ) { pick(device) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 270, height: 380)
    }

    private func pick(_ device: BrowserDevice?) {
        model.emulate(tab, device)
        choosing = false
        search = ""
    }

    private func row(_ name: String, detail: String, symbol: String, chosen: Bool, id: String, action: @escaping () -> Void) -> some View {
        ShowAsRow(name: name, detail: detail, symbol: symbol, chosen: chosen, action: action)
            .accessibilityIdentifier(id)
    }
}

private struct ShowAsRow: View {
    let name: String
    let detail: String
    let symbol: String
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: chosen ? "checkmark" : symbol)
                    .font(.system(size: 10.5, weight: chosen ? .bold : .regular))
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(name).font(.system(size: 12, weight: chosen ? .medium : .regular))
                Spacer(minLength: 8)
                Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(hovering ? Color.white.opacity(0.07) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(chosen ? "shown" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// The Browser tab's label in a strip: the user's pages of the project,
/// all in this one tab, as a window of Chrome holds its tabs.
struct BrowserTabLabel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var browsers: BrowserModel
    @ObservedObject var tab: BrowserTab
    let number: Int
    @State private var hovering = false
    @Environment(\.paneFront) private var paneFront
    @Environment(\.paneID) private var paneID

    private var selected: Bool { paneFront == tab.tabID }

    var body: some View {
        let pages = model.userPages(in: tab.project)
        let loading = pages.contains { $0.loading }
        HStack(spacing: 6) {
            Image(systemName: loading ? "arrow.triangle.2.circlepath" : "globe")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(pages.count > 1 ? "Browser (\(pages.count))" : "Browser")
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            ZStack {
                if number <= 9, !hovering {
                    Text("⌘\(number)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Button {
                    model.requestCloseBrowser(in: tab.project)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help(pages.count > 1 ? "Close the browser's \(pages.count) pages" : "Close the browser")
            }
            .frame(minWidth: 22)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.white.opacity(0.12) : (hovering ? Color.white.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selectStripTab(tab.tabID) }
        .help(model.shownPage(in: tab.project)?.displayTitle ?? "Browser")
        .contextMenu {
            TabArrangeMenu(id: tab.tabID)
            Divider()
            Button("New Page") { model.openBrowserTab() }
            Button("Close Browser") { model.requestCloseBrowser(in: tab.project) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pages.count > 1 ? "Browser, \(pages.count) pages" : "Browser")
        .accessibilityIdentifier("strip-browser")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectStripTab(tab.tabID) }
        .accessibilityAction(named: "Close Browser") { model.requestCloseBrowser(in: tab.project) }
    }
}

/// The Browser tab of a project: a row of the user's pages there, with a
/// button for one more, and the page picked.
struct UserBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var browsers: BrowserModel
    let project: String
    let focused: Bool

    var body: some View {
        let pages = model.userPages(in: project)
        let shown = model.shownPage(in: project)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(pages) { page in
                            PageTab(tab: page, selected: page === shown)
                        }
                    }
                }
                .fixedSize(horizontal: pages.count < 6, vertical: false)
                Button {
                    model.openBrowserTab()
                } label: {
                    Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold)).frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New page")
                .accessibilityLabel("New Page")
                .accessibilityIdentifier("browser-new-page")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
            if let shown {
                BrowserPaneView(tab: shown, focused: focused).id(shown.id)
            } else {
                Theme.canvas
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("user-browser")
    }
}

/// One page in the Browser tab's row.
private struct PageTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.loading ? "arrow.triangle.2.circlepath" : "globe")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(tab.displayTitle)
                .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Button {
                model.closeBrowserTab(tab)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || selected ? 1 : 0)
            .help("Close this page")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.white.opacity(0.12) : (hovering ? Color.white.opacity(0.05) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selectTab(id: tab.tabID) }
        .help(tab.url)
        .contextMenu { Button("Close Page") { model.closeBrowserTab(tab) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityIdentifier("tab-b\(tab.id)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectTab(id: tab.tabID) }
        .accessibilityAction(named: "Close Tab") { model.closeBrowserTab(tab) }
    }
}

/// What the user sends an agent from a page (#76): a picture of an element
/// or of what is shown, its address and what is known of the element, with
/// a note, to the agent picked.
struct SendToAgentSheet: View {
    @EnvironmentObject private var model: AppModel
    let pick: AppModel.BrowserPick
    @State private var note = ""
    @State private var agent: SessionID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send to an Agent").font(.headline)
            if let image = NSImage(data: pick.png) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 240)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
            }
            Text(pick.url).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if !pick.details.isEmpty {
                ScrollView {
                    Text(pick.details).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            }
            TextField("What should the agent do with it?", text: $note, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("pick-note")
            Picker("Agent", selection: $agent) {
                ForEach(model.agentsInProject(of: pick.tab)) { session in
                    Text(session.displayName).tag(Optional(session.id))
                }
            }
            Text("The picture is saved in the project's .agentterm folder, and the agent is told where, with the rest.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") {
                    // A word still being composed (Vietnamese, Japanese) is
                    // not in the note yet: ending the editing commits it,
                    // and the note is read once it has.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    DispatchQueue.main.async {
                        if let agent { model.send(pick, note: note, to: agent) }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(agent == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { agent = model.agentsInProject(of: pick.tab).first?.id }
    }
}
