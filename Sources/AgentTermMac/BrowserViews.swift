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
            // Which profile's sign-ins it uses.
            Text(model.profiles.profile(tab.profile)?.name ?? "")
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .help("Uses the profile “\(model.profiles.profile(tab.profile)?.name ?? "")”: its sign-ins, cookies and cache")
                .accessibilityIdentifier("browser-profile")
            if let device = tab.emulating {
                Button {
                    model.emulate(tab, nil)
                } label: {
                    Label(device.name, systemImage: "iphone").labelStyle(.titleAndIcon).font(.system(size: 11))
                }
                .help("Shown as \(device.name). Press to show it as itself again.")
            }
            Menu {
                Menu("Show As") {
                    ForEach([("Phones", BrowserDevice.Kind.phone), ("Tablets", .tablet), ("Computers", .computer)], id: \.0) { title, kind in
                        Menu(title) {
                            ForEach(BrowserDevice.presets.filter { $0.kind == kind }, id: \.name) { device in
                                Button("\(device.name)  \(device.width)×\(device.height)") { model.emulate(tab, device) }
                            }
                        }
                    }
                    if tab.emulating != nil {
                        Divider()
                        Button("This Mac") { model.emulate(tab, nil) }
                    }
                }
                Button("Find in Page…") { finding = true }
                Divider()
                Button("Zoom In") { tab.setZoom(tab.zoom + 0.5) }
                Button("Zoom Out") { tab.setZoom(tab.zoom - 0.5) }
                Button("Actual Size") { tab.setZoom(0) }
                Divider()
                Button("Developer Tools") { tab.showDevTools() }
                Button("Send to Agent…") { model.pickForAgent(tab) }
                    .disabled(model.agentsInProject(of: tab).isEmpty)
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
                    Text(tab.userHasIt ? BrowserWords.userHas(agents) : BrowserWords.agentDrives(agents))
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

/// The tab's label in a strip.
struct BrowserTabLabel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tab: BrowserTab
    let number: Int
    @State private var hovering = false
    @Environment(\.paneFront) private var paneFront
    @Environment(\.paneID) private var paneID

    private var selected: Bool { paneFront == tab.tabID }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.loading ? "arrow.triangle.2.circlepath" : "globe")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tab.owner != nil ? Color.accentColor : .secondary)
            Text(tab.displayTitle)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            ZStack {
                if number <= 9, !hovering {
                    Text("⌘\(number)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Button {
                    model.closeBrowserTab(tab)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Close this tab")
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
        .onTapGesture { model.selectTab(id: tab.tabID) }
        .help(tab.url)
        .contextMenu {
            TabArrangeMenu(id: tab.tabID)
            Divider()
            Button("Close Tab") { model.closeBrowserTab(tab) }
        }
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
                    if let agent { model.send(pick, note: note, to: agent) }
                    dismiss()
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
