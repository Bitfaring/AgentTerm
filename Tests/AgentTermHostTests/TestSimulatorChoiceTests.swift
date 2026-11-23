import Foundation
import XCTest

/// TEST-13 (#311): a test script that resets a simulator's keychain, run
/// with no simulator named and not from a terminal, takes "iPhone Air", never
/// the booted simulator, which is most likely the one in use.
final class TestSimulatorChoiceTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// What `choose_test_simulator` takes, with a stand-in `xcrun` that lists
    /// "iPhone Air" shut down and "iPhone 17" booted; nothing real is asked.
    private func chosen(argument: String, simulator: String? = nil) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sim-choice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let xcrun = folder.appendingPathComponent("xcrun")
        try """
        #!/bin/bash
        cat <<'L'
        == Devices ==
        -- iOS 27.2 --
            iPhone Air (11111111-1111-1111-1111-111111111111) (Shutdown)
            iPhone 17 (22222222-2222-2222-2222-222222222222) (Booted)
        L
        """.write(to: xcrun, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source scripts/lib-simulator.sh; choose_test_simulator \"$1\" >/dev/null; echo \"$SIM_NAME\"", "bash", argument]
        process.currentDirectoryURL = Self.repository
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = folder.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["SIMULATOR"] = simulator
        process.environment = environment
        // Not a terminal: as an agent or another script runs it.
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let name = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testWithNoSimulatorNamedNotFromATerminalItIsIPhoneAirAndNotTheBootedOne() throws {
        XCTAssertEqual(try chosen(argument: ""), "iPhone Air")
    }

    func testASimulatorNamedIsTheOneTaken() throws {
        XCTAssertEqual(try chosen(argument: "iPhone 17"), "iPhone 17")
        XCTAssertEqual(try chosen(argument: "", simulator: "iPhone 17"), "iPhone 17")
    }

    /// Both scripts that reset the keychain choose this way. Before the fix
    /// `test-both.sh` called `choose_simulator "${1:-}"`, which takes the
    /// booted simulator when not run from a terminal.
    func testTheScriptsThatResetAKeychainChooseThisWay() throws {
        for script in ["test-ios.sh", "test-both.sh"] {
            let text = try String(contentsOf: Self.repository.appendingPathComponent("scripts/\(script)"), encoding: .utf8)
            XCTAssertTrue(text.contains("choose_test_simulator \"${1:-}\""), "\(script) does not use choose_test_simulator")
            XCTAssertFalse(text.contains("choose_simulator \"${1:-}\""), "\(script) still takes the booted simulator")
        }
    }
}
