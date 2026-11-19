import Foundation
import Security

/// The key each Mac encrypts its pushes with, and the Mac's name, kept
/// where the app and its notification service extension both read them
/// (#66): a keychain group of their own, which holds nothing else. The
/// pairing tokens stay in the app's own group.
enum PushKeys {
    struct Saved: Codable, Equatable {
        var key: Data
        var macName: String
    }

    /// "<team>.com.manhpham.agentterm.push", from the Info.plist, which
    /// takes it from the entitlements' settings.
    static var group: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AgentTermPushKeychainGroup") as? String, !group.isEmpty, !group.hasPrefix("$(")
        else { return nil }
        return group
    }

    private static func query(mac: String) -> [String: Any]? {
        guard let group else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "push-keys",
            kSecAttrAccount as String: mac,
            kSecAttrAccessGroup as String: group,
        ]
    }

    static func load(mac: String) -> Saved? {
        guard var request = query(mac: mac) else { return nil }
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    /// Keeps it; false when this build cannot share it with its extension.
    @discardableResult
    static func save(_ saved: Saved, mac: String) -> Bool {
        guard let base = query(mac: mac), let data = try? JSONEncoder().encode(saved) else { return false }
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = data
        // The extension runs on a locked phone: after the first unlock.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(mac: String) {
        guard let base = query(mac: mac) else { return }
        SecItemDelete(base as CFDictionary)
    }
}
