import Foundation
import XCTest

/// TEST-14 (#310): every host a test script starts lives in the test's home
/// and never asks the agents' services with the sign-ins of the person
/// running the tests.
final class TestScriptHostsTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The lines of the test scripts that start a host: the only ones with
    /// `--local-only`.
    private func hostLines() throws -> [(script: String, line: String)] {
        var found: [(String, String)] = []
        for script in ["test-ios.sh", "test-both.sh", "screenshots.sh"] {
            let text = try String(contentsOf: Self.repository.appendingPathComponent("scripts/\(script)"), encoding: .utf8)
            for line in text.components(separatedBy: "\n") where line.contains("--local-only") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                found.append((script, line))
            }
        }
        return found
    }

    func testEveryHostOfATestScriptHasItsOwnHomeAndAsksNoService() throws {
        let lines = try hostLines()
        XCTAssertGreaterThanOrEqual(lines.count, 4, "the hosts of test-ios.sh (2), test-both.sh and screenshots.sh")
        for (script, line) in lines {
            let start = String(line.prefix(80))
            XCTAssertTrue(line.contains("--no-account-usage"), "\(script): a host asks the agents' services: \(start)…")
            XCTAssertTrue(line.contains("HOME=\"$FAKE_HOME\""), "\(script): a host runs in the home of the person running the tests: \(start)…")
            XCTAssertTrue(line.contains("--home \"$FAKE_HOME\""), "\(script): a host looks at the agents of the person running the tests: \(start)…")
        }
    }
}
