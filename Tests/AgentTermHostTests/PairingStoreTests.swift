import AgentTermClient
import Foundation
import Security
import XCTest

/// IOS-22 (#287): the iPhone's paired Macs are never lost to the Keychain.
/// A Keychain that cannot be read (a launch before the first unlock) makes
/// the app forget nothing: the next save is refused. A save that fails
/// keeps the list there was. Before the fix the list was deleted before
/// the new one was added, and a Keychain that could not be read was taken
/// for an empty one.
final class PairingStoreTests: XCTestCase {
    /// A Keychain of the test's own, whose answers it sets.
    final class FakeKeychain: KeychainItems, @unchecked Sendable {
        var items: [String: Data] = [:]
        var readStatus: OSStatus?
        var writeStatus: OSStatus?

        func read(account: String) -> (status: OSStatus, data: Data?) {
            if let readStatus { return (readStatus, nil) }
            guard let data = items[account] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
        func update(account: String, data: Data) -> OSStatus {
            if let writeStatus { return writeStatus }
            guard items[account] != nil else { return errSecItemNotFound }
            items[account] = data
            return errSecSuccess
        }
        func add(account: String, data: Data) -> OSStatus {
            if let writeStatus { return writeStatus }
            guard items[account] == nil else { return errSecDuplicateItem }
            items[account] = data
            return errSecSuccess
        }
        func delete(account: String) -> OSStatus {
            items[account] == nil
                ? errSecItemNotFound
                : {
                    items[account] = nil; return errSecSuccess
                }()
        }
    }

    private let first = SavedHost(id: "1", host: "100.64.0.1", port: 7840, name: "First Mac", token: "t1")
    private let second = SavedHost(id: "2", host: "100.64.0.2", port: 7840, name: "Second Mac", token: "t2")

    func testAKeychainThatCannotBeReadForgetsNothing() {
        let keychain = FakeKeychain()
        let store = PairingStore(keychain: keychain)
        XCTAssertTrue(store.save([first, second]))
        // The app starts before the first unlock.
        keychain.readStatus = errSecInteractionNotAllowed
        XCTAssertEqual(store.load(), [])
        XCTAssertTrue(store.unreadable)
        // Pairing a Mac then does not write over the two there are.
        XCTAssertFalse(store.save([SavedHost(id: "3", host: "100.64.0.3", port: 7840, name: "Third Mac", token: "t3")]))
        keychain.readStatus = nil
        XCTAssertEqual(store.load(), [first, second])
    }

    func testASaveThatFailsKeepsTheListThereWas() {
        let keychain = FakeKeychain()
        let store = PairingStore(keychain: keychain)
        XCTAssertTrue(store.save([first]))
        keychain.writeStatus = errSecNotAvailable
        XCTAssertFalse(store.save([first, second]))
        keychain.writeStatus = nil
        XCTAssertEqual(store.load(), [first], "a save that failed lost the paired Macs")
        XCTAssertTrue(store.save([first, second]))
        XCTAssertEqual(store.load(), [first, second])
    }
}
