import AppKit
import CryptoKit
import XCTest
@testable import Tovri

final class ReplaceInFilesTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(false, forKey: Settings.Key.gitEnabled)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Settings.Key.gitEnabled)
        super.tearDown()
    }

    private func makeFolder(_ files: [String: Data] = [:]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-replace-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, data) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func utf8(_ s: String) -> Data { Data(s.utf8) }

    private func options(_ query: String, in dir: URL, regex: Bool = false, caseSensitive: Bool = false,
                         wholeWord: Bool = false) -> FileSearcher.Options {
        FileSearcher.Options(query: query, regex: regex, caseSensitive: caseSensitive, wholeWord: wholeWord,
                             root: dir, include: [], exclude: [])
    }

    private func plan(_ o: FileSearcher.Options, _ replacement: String, open: [Document] = []) throws -> ReplaceInFiles.Plan {
        try XCTUnwrap(ReplaceInFiles.plan(o, replacement: replacement, open: ReplaceInFiles.openFiles(under: o.root, in: open)))
    }

    @discardableResult
    private func apply(_ plan: ReplaceInFiles.Plan, batch: ReplaceBatch = ReplaceBatch()) -> [String: ReplaceInFiles.Outcome] {
        let outcomes = ReplaceInFiles.applyInEditors(plan, batch: batch) + ReplaceInFiles.applyOnDisk(plan, batch: batch)
        return Dictionary(outcomes.map { (($0.path as NSString).lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func read(_ dir: URL, _ name: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(name)) }

    // MARK: Files on disk

    func testReplacingOnDiskKeepsEncodingLineEndingsAndPermissions() throws {
        let utf16 = Data([0xFF, 0xFE]) + "alpha beta\r\nalpha\r\n".data(using: .utf16LittleEndian)!
        let latin1 = "café alpha\n".data(using: .isoLatin1)!
        let bom = Data([0xEF, 0xBB, 0xBF]) + utf8("alpha\n")
        let dir = try makeFolder(["utf16.txt": utf16, "latin1.txt": latin1, "crlf.txt": utf8("alpha\r\nbeta alpha\r\n"), "bom.txt": bom])
        let crlf = dir.appendingPathComponent("crlf.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: crlf.path)

        let p = try plan(options("alpha", in: dir), "omega")
        XCTAssertFalse(p.isLimited)
        XCTAssertEqual(p.targets.count, 4)
        XCTAssertEqual(p.matches, 6)
        let out = apply(p)
        XCTAssertEqual(out.values.filter { $0.skipped == nil }.count, 4, "\(out.values.compactMap(\.skipped))")
        XCTAssertEqual(out["utf16.txt"]?.replaced, 2)

        XCTAssertEqual(try read(dir, "utf16.txt"), Data([0xFF, 0xFE]) + "omega beta\r\nomega\r\n".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try read(dir, "latin1.txt"), "café omega\n".data(using: .isoLatin1)!)
        XCTAssertEqual(try read(dir, "crlf.txt"), utf8("omega\r\nbeta omega\r\n"))
        XCTAssertEqual(try read(dir, "bom.txt"), Data([0xEF, 0xBB, 0xBF]) + utf8("omega\n"))
        let mode = try FileManager.default.attributesOfItem(atPath: crlf.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o640)
        XCTAssertTrue(out["crlf.txt"]?.lines.contains("     2: beta omega") == true, out["crlf.txt"]?.lines ?? "")
    }

    func testRegexCapturesAndEscapesWorkAndNewLinesFollowTheFile() throws {
        let dir = try makeFolder(["a.txt": utf8("let a = f(x, y)\n"), "b.txt": utf8("one;two\r\n")])
        var p = try plan(options("f\\((\\w+), (\\w+)\\)", in: dir, regex: true), "g($2,\\n\\t$1\\\\)")
        apply(p)
        XCTAssertEqual(String(decoding: try read(dir, "a.txt"), as: UTF8.self), "let a = g(y,\n\tx\\)\n")
        p = try plan(options(";", in: dir, regex: true), "\\n")
        apply(p)
        XCTAssertEqual(try read(dir, "b.txt"), utf8("one\r\ntwo\r\n"), "A new line in a CRLF file is written as CRLF")
    }

    func testLiteralReplacementIsNotATemplate() throws {
        let dir = try makeFolder(["a.txt": utf8("price\n")])
        apply(try plan(options("price", in: dir), "$1 \\n"))
        XCTAssertEqual(String(decoding: try read(dir, "a.txt"), as: UTF8.self), "$1 \\n\n")
    }

    func testWholeWordUsesTheEditorsWordRuleInSearchAndReplace() throws {
        let dir = try makeFolder(["a.txt": utf8("foo food afoo foo2 foo.\n"), "b.txt": utf8("echo $var; $variable\n")])
        let r = try XCTUnwrap(FileSearcher().run(options("$var", in: dir, wholeWord: true)))
        XCTAssertEqual(r.matches, 1, "Whole Word must not need a word character at the start of the query")
        apply(try plan(options("foo", in: dir, wholeWord: true), "X"))
        apply(try plan(options("$var", in: dir, wholeWord: true), "$x"))
        XCTAssertEqual(String(decoding: try read(dir, "a.txt"), as: UTF8.self), "X food afoo foo2 X.\n")
        XCTAssertEqual(String(decoding: try read(dir, "b.txt"), as: UTF8.self), "echo $x; $variable\n")
    }

    func testFilesThatCantBeSavedExactlyAreLeftAlone() throws {
        let dir = try makeFolder(["latin1.txt": "café alpha\n".data(using: .isoLatin1)!, "mixed.txt": utf8("alpha\r\nbeta\nalpha\r\n"),
                                  "locked.txt": utf8("alpha\n")])
        let locked = dir.appendingPathComponent("locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let out = apply(try plan(options("alpha", in: dir), "😀"))
        XCTAssertTrue(out["latin1.txt"]?.skipped?.contains("can’t be saved in") == true, out["latin1.txt"]?.skipped ?? "")
        XCTAssertTrue(out["mixed.txt"]?.skipped?.contains("mixed line endings") == true, out["mixed.txt"]?.skipped ?? "")
        XCTAssertTrue(out["locked.txt"]?.skipped?.contains("permission") == true, out["locked.txt"]?.skipped ?? "")
        XCTAssertEqual(try read(dir, "latin1.txt"), "café alpha\n".data(using: .isoLatin1)!)
        XCTAssertEqual(try read(dir, "mixed.txt"), utf8("alpha\r\nbeta\nalpha\r\n"))
        XCTAssertEqual(try read(dir, "locked.txt"), utf8("alpha\n"))
    }

    func testALinkToAFileOutsideTheFolderIsNeverWritten() throws {
        let outside = try makeFolder(["secret.txt": utf8("alpha\n")])
        let dir = try makeFolder(["a.txt": utf8("alpha\n")])
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        let out = apply(try plan(options("alpha", in: dir), "omega"))
        XCTAssertEqual(try read(outside, "secret.txt"), utf8("alpha\n"))
        XCTAssertEqual(try read(dir, "a.txt"), utf8("omega\n"))
        XCTAssertTrue(out["link.txt"]?.skipped?.contains("outside the folder") == true, "\(out.keys)")
    }

    func testFilesChangedAfterTheSearchAreSkipped() throws {
        let dir = try makeFolder(["a.txt": utf8("alpha\n"), "b.txt": utf8("alpha\n"), "c.txt": utf8("alpha\n")])
        let doc = try Document(contentsOf: dir.appendingPathComponent("c.txt"))
        let p = try plan(options("alpha", in: dir), "omega", open: [doc])
        try utf8("alpha, edited elsewhere\n").write(to: dir.appendingPathComponent("b.txt"))
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        let out = apply(p)
        XCTAssertNil(out["a.txt"]?.skipped)
        XCTAssertTrue(out["b.txt"]?.skipped?.contains("changed after the search") == true)
        XCTAssertTrue(out["c.txt"]?.skipped?.contains("edited after the search") == true)
        XCTAssertEqual(try read(dir, "b.txt"), utf8("alpha, edited elsewhere\n"))
        XCTAssertEqual(doc.string as String, "xalpha\n")
    }

    // MARK: Open documents

    func testOpenDocumentsGetOneUndoableEditAndTheFileOnDiskIsUntouched() throws {
        let dir = try makeFolder(["dirty.txt": utf8("alpha\n"), "clean.txt": utf8("alpha alpha\n")])
        let dirty = try Document(contentsOf: dir.appendingPathComponent("dirty.txt"))
        let clean = try Document(contentsOf: dir.appendingPathComponent("clean.txt"))
        dirty.textStorage.replaceCharacters(in: NSRange(location: dirty.length, length: 0), with: "alpha typed\n")
        XCTAssertTrue(dirty.isDirty)
        let p = try plan(options("alpha", in: dir), "omega", open: [dirty, clean])
        XCTAssertEqual(p.matches, 4, "The unsaved text is searched, not the file")
        let batch = ReplaceBatch()
        let out = apply(p, batch: batch)
        XCTAssertEqual(out["dirty.txt"]?.inEditor, true)
        XCTAssertEqual(dirty.string as String, "omega\nomega typed\n")
        XCTAssertEqual(clean.string as String, "omega omega\n")
        XCTAssertTrue(dirty.isDirty)
        XCTAssertTrue(clean.isDirty, "The replace isn't saved")
        XCTAssertEqual(try read(dir, "dirty.txt"), utf8("alpha\n"))
        XCTAssertEqual(try read(dir, "clean.txt"), utf8("alpha alpha\n"))
        XCTAssertTrue(batch.saved.isEmpty)
        XCTAssertEqual(batch.edited.count, 2)

        XCTAssertEqual(clean.undoManager.undoActionName, ReplaceInFiles.actionName)
        XCTAssertTrue(batch.canUndo(batch.edited.first { $0.document === clean }!))
        clean.undoManager.undo()
        XCTAssertEqual(clean.string as String, "alpha alpha\n", "The replace is one undo step")
        clean.undoManager.redo()
        XCTAssertEqual(clean.string as String, "omega omega\n")
        dirty.undoManager.undo()
        XCTAssertEqual(dirty.string as String, "alpha\nalpha typed\n")
    }

    // MARK: Limits

    func testACappedSearchIsRefused() throws {
        let many = utf8(String(repeating: "e\n", count: 4_000))
        var dir = try makeFolder(["a.txt": many, "b.txt": many, "c.txt": many])
        XCTAssertTrue(try plan(options("e", in: dir), "f").isLimited, "More than 10,000 matches")
        dir = try makeFolder(["a.txt": utf8(String(repeating: "e\n", count: 6_000))])
        let p = try plan(options("e", in: dir), "f")
        XCTAssertTrue(p.isLimited, "One file with more matches than Find in Files lists")

        try withController { c in
            c.replaceInFiles.confirmsAutomatically = true
            var done = false
            c.replaceInFiles.start(options("e", in: dir), replacement: "f") { done = true }
            wait { done }
            XCTAssertEqual(try read(dir, "a.txt"), utf8(String(repeating: "e\n", count: 6_000)))
            XCTAssertFalse(c.replaceInFiles.canUndo)
        }
    }

    // MARK: Undo

    func testUndoReplaceRestoresOriginalsAndKeepsLaterChanges() throws {
        let dir = try makeFolder(["a.txt": utf8("alpha\n"), "b.txt": utf8("alpha\r\n"), "open.txt": utf8("alpha\n")])
        try withController { c in
            let doc = try XCTUnwrap(c.open(url: dir.appendingPathComponent("open.txt")))
            let r = c.replaceInFiles
            r.confirmsAutomatically = true
            func enabled() -> Bool { c.validateMenuItem(NSMenuItem(title: "", action: #selector(MainWindowController.undoReplaceInFiles(_:)), keyEquivalent: "")) }
            XCTAssertFalse(enabled())
            var done = false
            r.start(options("alpha", in: dir), replacement: "omega") { done = true }
            wait { done }
            XCTAssertEqual(try read(dir, "a.txt"), utf8("omega\n"))
            XCTAssertEqual(try read(dir, "b.txt"), utf8("omega\r\n"))
            XCTAssertEqual(try read(dir, "open.txt"), utf8("alpha\n"), "The open file changes in the editor only")
            XCTAssertEqual(doc.string as String, "omega\n")
            XCTAssertTrue(enabled())
            XCTAssertTrue(c.activeDocument?.isFindResults == true)
            XCTAssertTrue(c.activeDocument?.string.contains("Saved: 2 files, 2 replacements") == true, c.activeDocument?.string as String? ?? "")

            try utf8("omega, then edited\r\n").write(to: dir.appendingPathComponent("b.txt"))
            done = false
            r.undoLast { done = true }
            wait { done }
            XCTAssertEqual(try read(dir, "a.txt"), utf8("alpha\n"))
            XCTAssertEqual(try read(dir, "b.txt"), utf8("omega, then edited\r\n"), "A file changed after the replace is kept")
            XCTAssertEqual(doc.string as String, "alpha\n")
            XCTAssertFalse(enabled(), "A replace is undone once")
            XCTAssertTrue(c.activeDocument?.string.contains("b.txt — It changed after the replace.") == true, c.activeDocument?.string as String? ?? "")
        }
    }

    func testRestoringRefusesAFileModifiedAfterTheReplace() throws {
        let dir = try makeFolder(["a.txt": utf8("alpha\n"), "b.txt": utf8("alpha\n")])
        let batch = ReplaceBatch()
        apply(try plan(options("alpha", in: dir), "omega"), batch: batch)
        XCTAssertEqual(batch.saved.count, 2)
        let a = try XCTUnwrap(batch.saved.first { $0.url.lastPathComponent == "a.txt" })
        let b = try XCTUnwrap(batch.saved.first { $0.url.lastPathComponent == "b.txt" })
        try utf8("mine\n").write(to: b.url)
        XCTAssertNil(batch.problem(with: a))
        XCTAssertNotNil(batch.problem(with: b))
        XCTAssertNil(batch.restore(a))
        XCTAssertNotNil(batch.restore(b))
        XCTAssertEqual(try read(dir, "a.txt"), utf8("alpha\n"))
        XCTAssertEqual(try read(dir, "b.txt"), utf8("mine\n"))
        try FileManager.default.removeItem(at: a.url)
        XCTAssertEqual(batch.restore(a), "It was moved or deleted after the replace.")
    }

    // MARK: Helpers

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

    private func wait(timeout: TimeInterval = 10, until condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), "Timed out")
    }
}
