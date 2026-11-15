import AgentTermProtocol
import SwiftUI

/// A profile of the browser (#76): its own cookies, sign-ins, storage and
/// cache, in a folder of its own. The user names and keeps them in
/// Settings > Browser; one is the default. An agent is asked for one when it
/// opens its first tab, and keeps it for the tabs it opens after.
struct BrowserProfile: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
}

@MainActor
final class BrowserProfiles: ObservableObject {
    @Published private(set) var list: [BrowserProfile] {
        didSet { save() }
    }
    /// The one the user's tabs open in, and that is picked when nothing
    /// else says which.
    @Published var defaultID: String {
        didSet { UserDefaults.standard.set(defaultID, forKey: Self.defaultKey) }
    }
    /// Profiles whose folder Chromium has open in this run: their data is
    /// cleared or deleted the next time the app opens, before Chromium does.
    private(set) var inUse: Set<String> = []

    private static let listKey = "browserProfiles"
    private static let defaultKey = "defaultBrowserProfile"
    private static let wipeKey = "browserProfilesToWipe"
    static let firstID = "default"

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.listKey).flatMap { try? JSONDecoder().decode([BrowserProfile].self, from: $0) } ?? []
        list = saved.isEmpty ? [BrowserProfile(id: Self.firstID, name: "Default")] : saved
        let chosen = UserDefaults.standard.string(forKey: Self.defaultKey) ?? Self.firstID
        defaultID = saved.contains { $0.id == chosen } || saved.isEmpty ? chosen : (saved.first?.id ?? Self.firstID)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.listKey) }
    }

    var defaultProfile: BrowserProfile { list.first { $0.id == defaultID } ?? list[0] }

    func profile(_ id: String) -> BrowserProfile? { list.first { $0.id == id } }

    /// The folder a profile keeps its data in: right in CEF's root folder,
    /// which Chromium's profiles have to be. One a level further down is
    /// refused ("Cannot create profile at path", CEF 156), and its pages
    /// fall back to a profile of Chromium's own.
    static func folder(for id: String) -> URL {
        Chromium.root.appendingPathComponent("profile-" + id, isDirectory: true)
    }

    func markInUse(_ id: String) { inUse.insert(id) }

    @discardableResult
    func add(named name: String) -> BrowserProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = BrowserProfile(id: UUID().uuidString.lowercased(), name: trimmed.isEmpty ? "Profile \(list.count + 1)" : trimmed)
        list.append(profile)
        return profile
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].name = trimmed
    }

    /// Takes a profile away with its data. The last one stays; the default
    /// moves to another.
    func delete(_ id: String) {
        guard list.count > 1 else { return }
        list.removeAll { $0.id == id }
        if defaultID == id { defaultID = list[0].id }
        wipe(id)
    }

    /// Throws its data away: at once when Chromium does not have it open,
    /// otherwise the next time the app opens. Says which.
    @discardableResult
    func clearData(_ id: String) -> Bool { wipe(id) }

    @discardableResult
    private func wipe(_ id: String) -> Bool {
        if inUse.contains(id) {
            var pending = UserDefaults.standard.stringArray(forKey: Self.wipeKey) ?? []
            if !pending.contains(id) { pending.append(id) }
            UserDefaults.standard.set(pending, forKey: Self.wipeKey)
            return false
        }
        try? FileManager.default.removeItem(at: Self.folder(for: id))
        return true
    }

    /// What was to be thrown away, before Chromium opens anything.
    static func wipePending() {
        for id in UserDefaults.standard.stringArray(forKey: wipeKey) ?? [] {
            try? FileManager.default.removeItem(at: folder(for: id))
        }
        UserDefaults.standard.removeObject(forKey: wipeKey)
    }

    /// How much a profile keeps on disk, in bytes.
    nonisolated static func size(of id: String) -> Int64 {
        let folder = Chromium.rootPath + "/profile-" + id
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Which profile an agent's first tab opens in (#76): asked of the user,
/// the default picked already.
struct ProfileQuestion: Identifiable {
    let id = UUID()
    let agent: SessionInfo
}

struct ProfileQuestionSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var profiles: BrowserProfiles
    let question: ProfileQuestion
    @State private var chosen = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which browser profile should \(question.agent.displayName) use?").font(.headline)
            Text("It opens a page in the browser. Its tabs use the profile's sign-ins and cookies, and the tabs it opens after use it too.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Profile", selection: $chosen) {
                ForEach(profiles.list) { profile in
                    Text(profile.id == profiles.defaultID ? "\(profile.name) (default)" : profile.name).tag(profile.id)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("profile-choice")
            HStack {
                Spacer()
                Button("Use Profile") { model.answerProfileQuestion(question, with: chosen) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("profile-use")
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { chosen = profiles.defaultID }
        .interactiveDismissDisabled()
    }
}

/// Settings > Browser (#76): the profiles, the default one, and whether the
/// agents may use the browser.
struct BrowserSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var profiles: BrowserProfiles
    @State private var sizes: [String: Int64] = [:]
    @State private var clearing: BrowserProfile?
    @State private var deleting: BrowserProfile?
    @State private var said: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(symbol: "globe", tint: .blue, title: "Browser", subtitle: "Chromium in \(AppChannel.current.appName), for you and the agents.")
            SettingsCard {
                SettingSwitch(
                    "Agents can use the browser", id: "agents-use-browser",
                    detail: "An agent can open tabs of its own in the browser, beside it, and use the tabs you share with it.",
                    help:
                        "Through AgentTerm's MCP server. An agent loads pages, reads them, clicks and types in them, takes pictures of them and reads their console. It never answers what a page asks you, and a tab you take over waits for you.",
                    isOn: $model.agentsUseBrowser)
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Profiles").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("New Profile") { _ = profiles.add(named: "") }
                            .accessibilityIdentifier("profile-new")
                    }
                    Text(
                        "Each keeps its own sign-ins, cookies, storage and cache. Your tabs, and agents nobody is at the Mac to ask, use the default; an agent is asked which one when it opens its first tab."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(profiles.list) { profile in
                        ProfileRow(
                            profile: profile, size: sizes[profile.id], isDefault: profile.id == profiles.defaultID, canDelete: profiles.list.count > 1,
                            makeDefault: { profiles.defaultID = profile.id }, clear: { clearing = profile }, delete: { deleting = profile })
                    }
                    if let said { Text(said).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 720, alignment: .leading)
        .task(id: profiles.list) { await measure() }
        .confirmationDialog("Clear the data of “\(clearing?.name ?? "")”?", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), titleVisibility: .visible) {
            Button("Clear Data", role: .destructive) {
                if let clearing { said = profiles.clearData(clearing.id) ? "Cleared." : "Its data is cleared the next time \(AppChannel.current.appName) opens: Chromium has it open now." }
                clearing = nil
                Task { await measure() }
            }
        } message: {
            Text("Its sign-ins, cookies, storage and cache are thrown away. The tabs that use it stay open.")
        }
        .confirmationDialog("Delete the profile “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) {
                if let deleting { model.deleteProfile(deleting.id) }
                deleting = nil
            }
        } message: {
            Text("Its tabs are closed, and its sign-ins, cookies, storage and cache are thrown away.")
        }
    }

    private func measure() async {
        let ids = profiles.list.map(\.id)
        let measured = await Task.detached { Dictionary(uniqueKeysWithValues: ids.map { ($0, BrowserProfiles.size(of: $0)) }) }.value
        sizes = measured
    }
}

private struct ProfileRow: View {
    @EnvironmentObject private var profiles: BrowserProfiles
    let profile: BrowserProfile
    let size: Int64?
    let isDefault: Bool
    let canDelete: Bool
    let makeDefault: () -> Void
    let clear: () -> Void
    let delete: () -> Void
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDefault ? Color.accentColor : .secondary)
                .onTapGesture(perform: makeDefault)
                .help(isDefault ? "The default profile" : "Make this the default profile")
                .accessibilityLabel(isDefault ? "Default" : "Make Default")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { makeDefault() }
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .onSubmit { profiles.rename(profile.id, to: name) }
                .accessibilityIdentifier("profile-name-\(profile.name)")
            Spacer()
            Text(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Clear Data…", action: clear).controlSize(.small)
            Button("Delete…", action: delete).controlSize(.small).disabled(!canDelete)
        }
        .padding(.vertical, 4)
        .onAppear { name = profile.name }
        .onChange(of: profile.name) { _, new in name = new }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile-\(profile.id)")
    }
}
