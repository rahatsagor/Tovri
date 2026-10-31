import AppKit
import XCTest
@testable import Tovri

final class ClipboardTests: XCTestCase {
    func testWindowsPasteNormalizesNewlinesBeforeSaving() throws {
        _ = NSApplication.shared
        let doc = Document()
        doc.lineEnding = .crlf
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.textView.insertPastedText("one\r\ntwo\r\n")
        XCTAssertEqual(doc.string as String, "one\ntwo\n")
        XCTAssertEqual(doc.lines.count, 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TovriPaste-" + UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.save(to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\r\ntwo\r\n")
    }

    func testWindowsPasteDistributesLinesAcrossCursors() {
        _ = NSApplication.shared
        let doc = Document(text: "a\nb", name: "Paste", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.textView.setAllSelections([NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)], scroll: false)
        editor.textView.insertPastedText("first\r\nsecond\r\n")
        XCTAssertEqual(doc.string as String, "first\nsecond")
        XCTAssertEqual(editor.textView.allSelections, [NSRange(location: 5, length: 0), NSRange(location: 12, length: 0)])
    }
}
