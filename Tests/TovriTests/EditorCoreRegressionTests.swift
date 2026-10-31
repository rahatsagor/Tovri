import AppKit
import XCTest
@testable import Tovri

final class EditorCoreRegressionTests: XCTestCase {
    private func makeEditor(_ text: String, lang: Language? = nil) -> EditorView {
        _ = NSApplication.shared
        let doc = Document(text: text, name: "Probe", language: lang ?? LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        editor.layoutSubtreeIfNeeded()
        return editor
    }

    private func withController(_ body: (MainWindowController) throws -> Void) rethrows {
        _ = NSApplication.shared
        let controller = MainWindowController()
        defer {
            for group in controller.groups { for tab in group.tabs { tab.close() } }
            controller.window?.delegate = nil
            controller.window?.close()
        }
        try body(controller)
    }

    private func temporaryDirectory() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-core-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testSwapCaseHandlesCharactersThatChangeLength() {
        let e = makeEditor("straße Ǆ")
        defer { e.close() }
        e.textView.setSelectedRange(NSRange(location: 0, length: e.document.length))
        e.textView.swapCase(nil)
        XCTAssertEqual(e.document.string as String, "STRASSE ǆ")
    }

    func testOverlappingMultiCaretDeletionsMerge() {
        let words = makeEditor("foo bar")
        defer { words.close() }
        words.textView.setAllSelections([NSRange(location: 5, length: 0), NSRange(location: 7, length: 0)])
        words.textView.doCommand(by: #selector(NSResponder.deleteWordBackward(_:)))
        XCTAssertEqual(words.document.string as String, "foo ")

        let line = makeEditor("abcdef")
        defer { line.close() }
        line.textView.setAllSelections([NSRange(location: 3, length: 0), NSRange(location: 6, length: 0)])
        line.textView.doCommand(by: #selector(NSResponder.deleteToBeginningOfLine(_:)))
        XCTAssertEqual(line.document.string as String, "")
    }

    func testDeleteLineOnTheEmptyLastLine() {
        let e = makeEditor("a\nb\n")
        defer { e.close() }
        e.textView.setAllSelections([NSRange(location: 4, length: 0)])
        e.textView.deleteLine(nil)
        XCTAssertEqual(e.document.string as String, "a\nb")
    }

    func testDuplicateLineKeepsSelectionsOnTheirText() {
        let e = makeEditor("abcdef\nxyz\n")
        defer { e.close() }
        e.textView.setAllSelections([NSRange(location: 1, length: 0), NSRange(location: 3, length: 2)])
        e.textView.duplicateLine(nil)
        let s = e.document.string
        for r in e.textView.allSelections where r.length > 0 { XCTAssertEqual(s.substring(with: r), "de") }
    }

    func testDroppedWindowsTextIsNormalized() {
        let e = makeEditor("x\n")
        defer { e.close() }
        let pb = NSPasteboard(name: NSPasteboard.Name("tovri-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.declareTypes([.string], owner: nil)
        pb.setString("a\r\nb", forType: .string)
        e.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(e.textView.readSelection(from: pb, type: .string))
        XCTAssertEqual(e.document.string.range(of: "\r").location, NSNotFound)
    }

    func testReplaceAllWithManyMatchesIsFastAndUndoable() {
        let state = FindState.shared
        let saved = (state.query, state.replacement, state.regex, state.caseSensitive, state.wholeWord)
        defer { (state.query, state.replacement, state.regex, state.caseSensitive, state.wholeWord) = saved }
        state.query = "foo"; state.replacement = "barx"; state.regex = false; state.caseSensitive = true; state.wholeWord = false
        let n = 40_000
        let e = makeEditor(String(repeating: "foo ", count: n))
        defer { e.close() }
        e.showFindBar(replace: true)
        let start = Date()
        e.findBar!.replaceAll()
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(e.document.length, n * 5)
        e.document.undoManager.undo()
        XCTAssertEqual(e.document.string as String, String(repeating: "foo ", count: n))
    }

    func testLayoutWithThousandsOfFoldsStaysFast() {
        var s = ""
        for i in 0..<2000 { s += "def f\(i)():\n    a = \(i)\n    b = a + 1\n    return b\n\n" }
        let e = makeEditor(s, lang: LanguageRegistry.shared.language(id: "python"))
        defer { e.close() }
        e.foldAll()
        XCTAssertGreaterThan(e.folds.count, 1000)
        let start = Date()
        e.layoutManager.ensureLayout(for: e.textContainer)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testReopeningADiscardedDocumentReadsTheFile() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data("disk a\n".utf8).write(to: a)
        try Data("disk b\n".utf8).write(to: b)
        try withController { c in
            try autoreleasepool {
                let docA = try XCTUnwrap(c.open(url: a))
                let tv = try XCTUnwrap(c.activeEditor?.textView)
                tv.insertText("UNSAVED ", replacementRange: NSRange(location: 0, length: 0))
                _ = c.open(url: b)
                let g = c.activeGroup
                if let i = g.index(of: docA) { g.removeTab(at: i) }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let reopened = try XCTUnwrap(c.open(url: a))
            XCTAssertEqual(reopened.string as String, "disk a\n")
            XCTAssertFalse(reopened.isDirty)
        }
    }

    func testRenamingAFolderMovesOpenFilesInside() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let f = sub.appendingPathComponent("main.txt")
        try Data("hello\n".utf8).write(to: f)
        try withController { c in
            let doc = try XCTUnwrap(c.open(url: f))
            let dest = dir.appendingPathComponent("lib")
            try FileManager.default.moveItem(at: sub, to: dest)
            c.sidebar(c.sidebar, didMove: sub, to: dest)
            XCTAssertEqual(doc.url?.standardizedFileURL.path, dest.appendingPathComponent("main.txt").standardizedFileURL.path)
            XCTAssertNoThrow(try doc.save())
        }
    }
}
