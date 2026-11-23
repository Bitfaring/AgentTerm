import AgentTermProtocol
import AppKit
import XCTest

/// Making, renaming and removing files, and the kinds of file that are not plain text.
final class MoreFilesTests: MacUITestCase {
    override func makeFixtures() throws {
        try super.makeFixtures()
        try write("# Guide\n\nSome words.\n\n```mermaid\ngraph TD; A-->B;\n```\n", to: "docs/guide.md")
        // The smallest picture there is: one pixel.
        let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        try XCTUnwrap(Data(base64Encoded: pixel)).write(to: project.appendingPathComponent("pixel.png"))
        try Data([0, 159, 146, 150, 255, 254, 0, 1]).write(to: project.appendingPathComponent("blob.bin"))
        try String(repeating: "0123456789abcdef\n", count: 140_000).write(to: project.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
    }

    /// A file's row in the tree, as apart from its tab.
    /// The Files panel's row of a file.
    private func row(_ name: String) -> MacDriver.Query { .idEnding("/project/" + name, prefix: "file-") }

    func testMakingRenamingAndRemovingFiles() throws {
        app.press(.button("Files"))
        app.wait(for: .button("notes.txt"))
        // FILE-2: a new file, which opens.
        app.press(.button("New file"))
        app.write("made-here.txt", into: .role(kAXTextFieldRole as String))
        app.press(.button("Create"))
        wait("the file on disk") { FileManager.default.fileExists(atPath: self.project.appendingPathComponent("made-here.txt").path) }
        app.wait(for: .button("made-here.txt"))
        // A name that is taken is refused, and nothing is overwritten.
        app.press(.button("New file"))
        app.write("notes.txt", into: .role(kAXTextFieldRole as String))
        app.press(.button("Create"))
        app.wait(for: .button("OK"))
        XCTAssertEqual(read("notes.txt"), "first line\nsecond line\n", "a file was overwritten by one of the same name")
        app.press(.button("OK"))
        // A new folder.
        app.press(.button("New folder"))
        app.write("assets", into: .role(kAXTextFieldRole as String))
        app.press(.button("Create"))
        var isDirectory: ObjCBool = false
        wait("the folder on disk") { FileManager.default.fileExists(atPath: self.project.appendingPathComponent("assets").path, isDirectory: &isDirectory) }
        XCTAssertTrue(isDirectory.boolValue)
        // Renamed.
        app.perform("Rename", on: row("made-here.txt"))
        app.write("renamed.txt", into: .role(kAXTextFieldRole as String))
        app.press(.button("Rename"))
        wait("the new name on disk") { FileManager.default.fileExists(atPath: self.project.appendingPathComponent("renamed.txt").path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("made-here.txt").path))
        // Moved to the Trash, after asking.
        app.perform("Move to Trash", on: row("renamed.txt"))
        app.press(.button("Move to Trash"))
        wait("the file gone from the project") { !FileManager.default.fileExists(atPath: self.project.appendingPathComponent("renamed.txt").path) }
        app.waitGone(row("renamed.txt"))
    }

    /// FILE-16 (#305): a file with unsaved changes is not put in the Trash:
    /// it is said why, the file stays, and so do the changes.
    func testAFileWithUnsavedChangesIsNotPutInTheTrash() throws {
        app.press(.button("Files"))
        app.press(.button("notes.txt"), timeout: 15)
        let editor = MacDriver.Query.role(kAXTextAreaRole as String)
        let saved = "first line\nsecond line\n"
        wait("the file's text in the editor") { self.app.value(of: editor) == saved }
        app.write(saved + "not saved\n", into: editor)
        app.wait(for: .button("Save"))
        app.perform("Move to Trash", on: row("notes.txt"))
        app.press(.button("Move to Trash"))
        app.wait(for: .containing("Save or discard the changes in notes.txt before putting it in the Trash."), timeout: 5)
        app.press(.button("OK"))
        XCTAssertEqual(read("notes.txt"), saved, "the file went to the Trash")
        XCTAssertEqual(app.value(of: editor), saved + "not saved\n", "the unsaved changes were lost")
    }

    func testFilesThatAreNotPlainText() throws {
        app.press(.button("Files"))
        app.wait(for: .button("notes.txt"))
        // FILE-5: a picture is shown.
        app.press(.button("pixel.png"))
        app.wait(for: .role(kAXImageRole as String), timeout: 10)
        // What is not text says so, and so does what is too large.
        app.press(.button("blob.bin"))
        app.wait(for: .containing("This file is not text"))
        app.press(.button("big.txt"))
        app.wait(for: .containing("too large to open by itself"))
        // FILE-4: Markdown opens as a preview, with its source one switch away.
        // With what GitHub draws (#126): a table, coloured code, a diagram,
        // a link, and a picture next to the document.
        try picture(width: 40, height: 30).write(to: project.appendingPathComponent("docs/chart.png"))
        try write(
            "# Guide\n\nSome words, and [a link](other.md).\n\n| Step | Done |\n|---|---|\n| lex | yes |\n\n- [x] parsed\n- [ ] ~~typed~~ checked\n\n"
                + "```swift\nlet x = parse(\"a\")\n```\n\n```mermaid\ngraph LR; Lexer-->Parser\n```\n\n![the chart](chart.png)\n",
            to: "docs/guide.md", in: project)
        app.press(.button("docs, folder, collapsed"))
        app.press(.button("guide.md"))
        app.wait(for: .containing("Some words"), timeout: 15)
        XCTAssertFalse(app.exists(.role(kAXTextAreaRole as String)), "a Markdown file opened as its source")
        XCTAssertNotNil(app.wait(for: .role("AXLink"), timeout: 10), "the link")
        // The table's cells, each on its own.
        XCTAssertNotNil(app.wait(for: .text("Step"), timeout: 10), "the table's heading cells")
        XCTAssertFalse(app.exists(.containing("StepDone")), "the table's cells run together")
        // The picture is read from beside the document, at its width: one
        // that is not found is drawn otherwise. Its line may be a point
        // taller.
        wait("the picture beside the document, 40 by 30", timeout: 10) {
            self.app.all(.text("the chart")).contains {
                let size = self.size(of: $0.element)
                return $0.role == kAXImageRole as String && size.width == 40 && abs(size.height - 30) <= 1
            }
        }
        // The diagram is drawn: its boxes' words are on their own, and its
        // code is not shown.
        app.wait(for: .text("Parser"), timeout: 15)
        XCTAssertFalse(app.exists(.containing("Lexer-->Parser")), "the diagram shown as its code")
        shot("markdown")
        app.press(.button("Edit"))
        wait("the source") { self.app.value(of: .role(kAXTextAreaRole as String))?.hasPrefix("# Guide") ?? false }
    }

    /// A PNG of one colour, of this many pixels.
    private func picture(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    private func size(of element: AXUIElement) -> CGSize {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        var size = CGSize.zero
        if let value, CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        return size
    }
}
