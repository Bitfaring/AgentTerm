import Foundation
import Security

/// A Mac this iPhone is paired with, and the token it connects to it with.
public struct SavedHost: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var host: String
    public var port: UInt16
    public var name: String
    /// This device's own token for that Mac, given when pairing. The Mac can
    /// revoke it without affecting other devices.
    public var token: String

    public init(id: String, host: String, port: UInt16, name: String, token: String) {
        self.id = id
        self.host = host
        self.port = port
        self.name = name
        self.token = token
    }
}

/// The Keychain's items of this app, by account: what `PairingStore` asks
/// of it, so that a test can stand a Keychain of its own in (#287).
public protocol KeychainItems: Sendable {
    func read(account: String) -> (status: OSStatus, data: Data?)
    func update(account: String, data: Data) -> OSStatus
    func add(account: String, data: Data) -> OSStatus
    func delete(account: String) -> OSStatus
}

/// The system's Keychain, a generic password per account, kept on this
/// device only and readable after its first unlock.
public struct SystemKeychain: KeychainItems {
    public init() {}

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.manhpham.agentterm",
            kSecAttrAccount as String: account,
        ]
    }

    public func read(account: String) -> (status: OSStatus, data: Data?) {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        return (status, status == errSecSuccess ? result as? Data : nil)
    }

    private func changes(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }

    public func update(account: String, data: Data) -> OSStatus {
        SecItemUpdate(query(account: account) as CFDictionary, changes(data) as CFDictionary)
    }

    public func add(account: String, data: Data) -> OSStatus {
        var item = query(account: account)
        item.merge(changes(data)) { $1 }
        return SecItemAdd(item as CFDictionary, nil)
    }

    public func delete(account: String) -> OSStatus {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

/// Keeps the paired Macs in the Keychain, since the tokens grant shell access.
public final class PairingStore: @unchecked Sendable {
    public static let shared = PairingStore()

    private let keychain: KeychainItems
    private let lock = NSLock()
    private var couldNotRead = false

    public init(keychain: KeychainItems = SystemKeychain()) {
        self.keychain = keychain
    }

    /// The Keychain could not be read when the list was loaded (a launch
    /// before the first unlock, say): the paired Macs are not known, and
    /// nothing is written over them (#287).
    public var unreadable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return couldNotRead
    }

    private func read(account: String) -> Data? {
        let (status, data) = keychain.read(account: account)
        if status != errSecSuccess, status != errSecItemNotFound {
            lock.lock()
            couldNotRead = true
            lock.unlock()
        }
        return data
    }

    public func load() -> [SavedHost] {
        lock.lock()
        couldNotRead = false
        lock.unlock()
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
        _ = keychain.delete(account: "host")
        return migrated
    }

    @discardableResult
    public func save(_ hosts: [SavedHost]) -> Bool {
        // Never over what could not be read: it may hold every paired Mac.
        guard !unreadable else { return false }
        guard !hosts.isEmpty else {
            let status = keychain.delete(account: "hosts")
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard let data = try? JSONEncoder().encode(hosts) else { return false }
        // Changed in place: the list is never deleted before the new one is
        // there, so a failure keeps the old one (#287).
        let updated = keychain.update(account: "hosts", data: data)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        return keychain.add(account: "hosts", data: data) == errSecSuccess
    }
}
