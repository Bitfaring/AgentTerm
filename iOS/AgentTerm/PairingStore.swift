import Foundation
import Security

/// A Mac this iPhone is paired with, and the token it connects to it with.
struct SavedHost: Codable, Equatable, Identifiable {
    var id: String
    var host: String
    var port: UInt16
    var name: String
    /// This device's own token for that Mac, given when pairing. The Mac can
    /// revoke it without affecting other devices.
    var token: String
}

/// Keeps the paired Macs in the Keychain, since the tokens grant shell access.
enum PairingStore {
    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.manhpham.agentterm",
            kSecAttrAccount as String: account,
        ]
    }

    /// The Keychain could not be read when the app started (a launch before
    /// the first unlock, say): the paired Macs are not known, and nothing is
    /// written over them (#287).
    private(set) static var unreadable = false

    private static func read(account: String) -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status != errSecSuccess, status != errSecItemNotFound { unreadable = true }
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func load() -> [SavedHost] {
        unreadable = false
        if let data = read(account: "hosts"), let hosts = try? JSONDecoder().decode([SavedHost].self, from: data) {
            return hosts
        }
        if unreadable { return [] }
        // Builds that paired with a single Mac kept it under another name.
        struct Single: Codable {
            var host: String
            var port: UInt16
            var name: String
            var token: String
        }
        guard let data = read(account: "host"), let old = try? JSONDecoder().decode(Single.self, from: data) else { return [] }
        let migrated = [SavedHost(id: UUID().uuidString, host: old.host, port: old.port, name: old.name, token: old.token)]
        save(migrated)
        SecItemDelete(query(account: "host") as CFDictionary)
        return migrated
    }

    @discardableResult
    static func save(_ hosts: [SavedHost]) -> Bool {
        // Never over what could not be read: it may hold every paired Mac.
        guard !unreadable else { return false }
        guard !hosts.isEmpty else {
            let status = SecItemDelete(query(account: "hosts") as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard let data = try? JSONEncoder().encode(hosts) else { return false }
        // Changed in place: the list is never deleted before the new one is
        // there, so a failure keeps the old one (#287).
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query(account: "hosts") as CFDictionary, changes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = query(account: "hosts")
        item.merge(changes) { $1 }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
