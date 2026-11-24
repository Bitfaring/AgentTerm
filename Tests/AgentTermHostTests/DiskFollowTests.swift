import Darwin
import XCTest

@testable import AgentTermHost

/// FILE-17 (#304): how the Mac app's open files follow the disk. A file
/// whose date and size did not change is not read; one that changed is; a
/// pipe is never read; and what was read is not shown over a document that
/// was edited, saved or closed meanwhile.
final class DiskFollowTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFollowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ text: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Changed behind the stamp's back (same size, the date put back): the
    /// stamp is the same, so the file is not read, and nothing is found.
    func testAFileWhoseDateAndSizeDidNotChangeIsNotRead() throws {
        let path = try file("a.txt", "one\n")
        // A whole second: the file system keeps what is set to the second.
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: path)
        let stamp = try XCTUnwrap(DiskStamp(of: path))
        try "two\n".write(toFile: path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: path)
        let looked = DiskFollow.look(at: [.init(path: path, saved: "one\n")], known: [path: stamp])
        XCTAssertEqual(looked.changed, [], "a file whose stamp is the same was read")
        XCTAssertEqual(looked.stamps[path], stamp)
    }

    func testAFileChangedOnTheDiskIsFound() throws {
        let path = try file("b.txt", "one\n")
        let stamp = try XCTUnwrap(DiskStamp(of: path))
        try "one, and more\n".write(toFile: path, atomically: false, encoding: .utf8)
        let looked = DiskFollow.look(at: [.init(path: path, saved: "one\n")], known: [path: stamp])
        XCTAssertEqual(looked.changed, [DiskFollow.Found(path: path, text: "one, and more\n", saved: "one\n")])
        XCTAssertNotEqual(looked.stamps[path], stamp)
    }

    /// Never looked at before: read, and found only if it differs.
    func testAFileWithoutAStampIsReadOnce() throws {
        let path = try file("c.txt", "same\n")
        let looked = DiskFollow.look(at: [.init(path: path, saved: "same\n")], known: [:])
        XCTAssertEqual(looked.changed, [])
        XCTAssertNotNil(looked.stamps[path])
    }

    /// A pipe has no writer: reading it would never end. It is not read.
    func testAPipeIsNotRead() throws {
        let path = folder.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        XCTAssertNil(DiskStamp(of: path))
        let done = expectation(description: "looked at")
        DispatchQueue.global().async {
            _ = DiskFollow.look(at: [.init(path: path, saved: "")], known: [:])
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testWhatWasReadIsShownOnlyOverTheSameDocumentWithoutEdits() {
        let found = DiskFollow.Found(path: "/x", text: "new", saved: "old")
        XCTAssertTrue(DiskFollow.takes(found, now: (isDirty: false, saved: "old")))
        XCTAssertFalse(DiskFollow.takes(found, now: nil), "shown in a document closed meanwhile")
        XCTAssertFalse(DiskFollow.takes(found, now: (isDirty: true, saved: "old")), "shown over unsaved edits")
        XCTAssertFalse(DiskFollow.takes(found, now: (isDirty: false, saved: "saved meanwhile")), "shown over a document saved meanwhile")
    }
}
