import XCTest

/// BROWSER-39 (#133): the Mac app builds where Chromium's headers were not
/// fetched (`scripts/fetch-cef.sh`), and says there that the browser is not
/// in the build. The browser's C layer has two halves for it: one compiled
/// with the headers, and one of stubs that do nothing, compiled without
/// them. A build with the headers never compiles the stubs, so a function
/// that has none is seen only by the linker of a build without them, as
/// CodeQL's build of the Swift code is. The file is compiled here as such a
/// build compiles it.
final class BuildWithoutChromiumTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-without-chromium-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Runs one of the developer tools, and gives how it ended and what it said.
    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, said: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [tool] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let said = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: said, as: UTF8.self))
    }

    func testEveryFunctionOfTheBrowsersHasAStubWithoutChromium() throws {
        let sources = Self.repository.appendingPathComponent("Sources/CAgentTermCEF")

        // What the header declares, which is all that Swift can call: each
        // name of the layer's that is followed by its parameters, the
        // comments left out.
        let header = try String(contentsOf: sources.appendingPathComponent("include/AgentTermCEF.h"), encoding: .utf8)
        let code = header.replacingOccurrences(of: #"//[^\n]*|/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        let function = try NSRegularExpression(pattern: #"\b(atc_[A-Za-z0-9_]+)\s*\("#)
        let declared = Set(
            function.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { match in
                Range(match.range(at: 1), in: code).map { String(code[$0]) }
            })
        XCTAssertTrue(declared.contains("atc_start"), "the header's functions were not found: \(declared.sorted())")

        // The file as a build without the headers compiles it: Chromium's
        // folder is not among those searched, and were the headers found
        // all the same, this would not compile.
        let wrapper = folder.appendingPathComponent("without-chromium.m")
        try """
        #include "\(sources.appendingPathComponent("AgentTermCEF.m").path)"
        #if ATC_HAS_CEF
        #error "compiled with the headers of Chromium"
        #endif

        """.write(to: wrapper, atomically: true, encoding: .utf8)
        let object = folder.appendingPathComponent("without-chromium.o")
        let compiled = try run(
            "clang", ["-c", "-x", "objective-c", "-fobjc-arc", "-DCEF_API_VERSION=15600", "-I", sources.appendingPathComponent("include").path, wrapper.path, "-o", object.path])
        XCTAssertEqual(compiled.status, 0, "a build without Chromium does not compile: \(compiled.said)")

        // What it defines for others to call.
        let symbols = try run("nm", ["-g", "-U", object.path])
        XCTAssertEqual(symbols.status, 0, symbols.said)
        let defined = Set(
            symbols.said.split(separator: "\n").compactMap { line -> String? in
                guard let name = line.split(separator: " ").last, name.hasPrefix("_atc_") else { return nil }
                return String(name.dropFirst())
            })
        XCTAssertEqual(declared.subtracting(defined).sorted(), [], "declared in AgentTermCEF.h, and without a stub in a build without Chromium, which then does not link")
    }
}
