import AppKit
import XCTest
@testable import Tovri

final class EditorFeatureTests: XCTestCase {
    private let touchedKeys = [Settings.Key.rulers, Settings.Key.rulerColumn, Settings.Key.languageIndentation,
                               Settings.Key.fontLigatures, Settings.Key.fontWeight, Settings.Key.autoSaveDelay]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        _ = Settings.shared
    }

    override func tearDown() {
        AutoSave.shared.save = nil
        AutoSave.shared.delayOverride = nil
        for k in touchedKeys { UserDefaults.standard.removeObject(forKey: k) }
        waitForSettings()
        super.tearDown()
    }

    private func waitForSettings() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func document(_ text: String) -> Document {
        Document(text: text, name: "Bookmarks", language: LanguageRegistry.shared.plain)
    }

    private func edit(_ doc: Document, _ range: NSRange, _ text: String) {
        doc.textStorage.replaceCharacters(in: range, with: text)
    }

    private func withEditor(_ text: String, _ body: (EditorView) -> Void) {
        let editor = EditorView(document: document(text))
        defer { editor.close() }
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        editor.layoutSubtreeIfNeeded()
        body(editor)
    }

    private func temporaryFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EditorFeatureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func file(_ name: String, _ text: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Bookmarks

    func testBookmarksMoveWithEditsAndDieWithDeletedLines() {
        let doc = document("a\nb\nc\nd\ne\n")
        doc.bookmarks.set([1, 3], lineCount: doc.lines.count)

        edit(doc, NSRange(location: 0, length: 0), "new\n")
        XCTAssertEqual(doc.bookmarks.lines, [2, 4], "a line added above moves bookmarks down")

        let b = doc.lines.start(of: 2)
        edit(doc, NSRange(location: b + 1, length: 0), "x")
        XCTAssertEqual(doc.bookmarks.lines, [2, 4], "typing on a bookmarked line keeps it there")

        edit(doc, NSRange(location: doc.lines.start(of: 2), length: 0), "\n")
        XCTAssertEqual(doc.bookmarks.lines, [3, 5], "a new line before the text pushes the bookmark down with it")

        edit(doc, doc.lines.fullRange(of: 3, textLength: doc.length), "")
        XCTAssertEqual(doc.bookmarks.lines, [4], "deleting a bookmarked line removes its bookmark")

        doc.bookmarks.set([1, 2, 4], lineCount: doc.lines.count)
        let from = doc.lines.start(of: 1) + 1
        let to = doc.lines.start(of: 3) + 1
        edit(doc, NSRange(location: from, length: to - from), "")
        XCTAssertEqual(doc.bookmarks.lines, [1, 2], "a line deleted from inside a selection loses its bookmark; the rest keep theirs")

        edit(doc, NSRange(location: 0, length: doc.length), "")
        XCTAssertEqual(doc.bookmarks.lines, [], "deleting everything removes every bookmark")
    }

    func testJoiningLinesKeepsTheBookmarkOfTheLineWithText() {
        let doc = document("a\n\nb\nc")
        doc.bookmarks.set([1, 2, 3], lineCount: doc.lines.count)
        edit(doc, NSRange(location: 1, length: 1), "")
        XCTAssertEqual(doc.bookmarks.lines, [1, 2], "the empty line is gone, the lines after it move up")
        edit(doc, NSRange(location: 1, length: 1), "")
        XCTAssertEqual(doc.bookmarks.lines, [0, 1], "the joined line keeps the bookmark of the text that moved into it")
    }

    func testBookmarksSurviveLineCommands() {
        withEditor("one\ntwo\nthree\nfour\n") { editor in
            let tv = editor.textView
            let doc = editor.document
            tv.setAllSelections([NSRange(location: doc.lines.start(of: 1), length: 0)])
            tv.toggleBookmark(nil)
            XCTAssertEqual(doc.bookmarks.lines, [1])

            tv.moveLineDown(nil)
            XCTAssertEqual(doc.bookmarks.lines, [2], "moving a line takes its bookmark along")
            tv.moveLineUp(nil)
            XCTAssertEqual(doc.bookmarks.lines, [1])

            tv.setAllSelections([NSRange(location: doc.lines.start(of: 0), length: 0)])
            tv.deleteLine(nil)
            XCTAssertEqual(doc.bookmarks.lines, [0], "deleting the line above moves the bookmark up")
            tv.deleteLine(nil)
            XCTAssertEqual(doc.bookmarks.lines, [], "deleting the bookmarked line removes it")

            tv.setAllSelections([NSRange(location: 0, length: doc.length)])
            tv.toggleBookmark(nil)
            XCTAssertEqual(doc.bookmarks.lines, [0, 1], "every selected line is bookmarked")
            tv.toggleBookmark(nil)
            XCTAssertEqual(doc.bookmarks.lines, [], "toggling again removes them")
        }
    }

    func testNextAndPreviousBookmarkWrap() {
        let b = Bookmarks()
        XCTAssertNil(b.next(after: 0))
        XCTAssertNil(b.previous(before: 0))
        b.set([7, 2, 5, 2, 40], lineCount: 10)
        XCTAssertEqual(b.lines, [2, 5, 7])
        XCTAssertEqual(b.next(after: 2), 5)
        XCTAssertEqual(b.next(after: 7), 2)
        XCTAssertEqual(b.previous(before: 5), 2)
        XCTAssertEqual(b.previous(before: 2), 7)
        XCTAssertEqual(b.previous(before: 0), 7)

        withEditor("0\n1\n2\n3\n4\n5\n") { editor in
            let tv = editor.textView
            let doc = editor.document
            doc.bookmarks.set([1, 4], lineCount: doc.lines.count)
            func caretLine() -> Int { doc.lines.line(containing: tv.selectedRange().location) }
            tv.setAllSelections([NSRange(location: doc.lines.start(of: 2), length: 0)])
            tv.nextBookmark(nil)
            XCTAssertEqual(caretLine(), 4)
            tv.nextBookmark(nil)
            XCTAssertEqual(caretLine(), 1, "next wraps to the first bookmark")
            tv.previousBookmark(nil)
            XCTAssertEqual(caretLine(), 4, "previous wraps to the last bookmark")
            tv.clearBookmarks(nil)
            XCTAssertTrue(doc.bookmarks.isEmpty)
        }
    }

    func testBookmarksPersistThroughSessionRoundTrip() throws {
        let dir = try temporaryFolder()
        let url = try file("marked.txt", "one\ntwo\nthree\nfour\n", in: dir)
        var data = Data()
        try autoreleasepool {
            let controller = MainWindowController()
            defer {
                for group in controller.groups { for tab in group.tabs { tab.close() } }
                controller.window?.delegate = nil
                controller.window?.close()
            }
            let doc = try XCTUnwrap(controller.open(url: url))
            doc.bookmarks.set([0, 2], lineCount: doc.lines.count)
            data = try JSONEncoder().encode(controller.sessionState())
        }
        let session = try JSONDecoder().decode(WindowSession.self, from: data)
        XCTAssertEqual(session.groups.first?.tabs.first?.bookmarks, [0, 2])

        let controller = MainWindowController()
        defer {
            for group in controller.groups { for tab in group.tabs { tab.close() } }
            controller.window?.delegate = nil
            controller.window?.close()
        }
        controller.restore(session)
        XCTAssertEqual(controller.activeDocument?.bookmarks.lines, [0, 2])

        let old = Data(#"{"path":"/tmp/a.txt","selection":0,"selectionLength":0,"scrollX":0,"scrollY":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TabSession.self, from: old).bookmarks, "sessions from before bookmarks still load")
    }

    // MARK: Auto save

    func testAutoSaveRunsOnceAfterTypingPauses() throws {
        let dir = try temporaryFolder()
        let url = try file("auto.txt", "start\n", in: dir)
        let doc = try Document(contentsOf: url)
        var saves = 0
        AutoSave.shared.delayOverride = 0.3
        AutoSave.shared.save = { d in
            saves += 1
            try? d.save()
        }
        edit(doc, NSRange(location: 0, length: 0), "a")
        spin(0.15)
        edit(doc, NSRange(location: 0, length: 0), "b")
        spin(0.15)
        XCTAssertEqual(saves, 0, "still typing")
        spin(0.4)
        XCTAssertEqual(saves, 1)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bastart\n")
        spin(0.4)
        XCTAssertEqual(saves, 1, "a saved document isn't saved again")
    }

    func testAutoSaveSkipsDocumentsWithoutAFileOnDisk() throws {
        let dir = try temporaryFolder()
        var saved: [Document] = []
        AutoSave.shared.delayOverride = 0.1
        AutoSave.shared.save = { saved.append($0) }

        let untitled = Document()
        let newFile = Document(newFileAt: dir.appendingPathComponent("new.txt"))
        let readOnly = try Document(contentsOf: try file("locked.txt", "x\n", in: dir))
        readOnly.isReadOnly = true
        let transient = try Document(contentsOf: try file("results.txt", "x\n", in: dir))
        transient.isTransient = true
        let deleted = try Document(contentsOf: try file("gone.txt", "x\n", in: dir))
        for d in [untitled, newFile, readOnly, transient, deleted] { edit(d, NSRange(location: 0, length: 0), "edit") }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone.txt"))
        spin(0.4)
        XCTAssertTrue(saved.isEmpty, "only files already on disk are saved automatically")

        AutoSave.shared.delayOverride = nil
        UserDefaults.standard.set(0, forKey: Settings.Key.autoSaveDelay)
        let off = try Document(contentsOf: try file("off.txt", "x\n", in: dir))
        edit(off, NSRange(location: 0, length: 0), "edit")
        spin(0.3)
        XCTAssertTrue(saved.isEmpty, "off by default")
    }

    // MARK: Rulers

    func testRulerColumnsParse() {
        XCTAssertEqual(Settings.parseRulers("80, 120"), [80, 120])
        XCTAssertEqual(Settings.parseRulers("120,80 80"), [80, 120])
        XCTAssertEqual(Settings.parseRulers("0, 501, abc, -4, 72"), [72])
        XCTAssertEqual(Settings.parseRulers(""), [])
        XCTAssertEqual(Settings.formatRulers([80, 120]), "80, 120")

        let d = UserDefaults.standard
        d.set(100, forKey: Settings.Key.rulerColumn)
        XCTAssertEqual(Settings.shared.rulerColumns, [100], "a single ruler from an older version still shows")
        Settings.shared.rulersText = "120, 80"
        XCTAssertEqual(Settings.shared.rulerColumns, [80, 120])
        XCTAssertEqual(d.integer(forKey: Settings.Key.rulerColumn), 80)
        Settings.shared.rulersText = ""
        XCTAssertEqual(Settings.shared.rulerColumns, [])
        XCTAssertEqual(SettingsBackup.ranges[Settings.Key.rulerColumn], 0...500)
    }

    // MARK: Indentation per language

    func testLanguageIndentationParses() {
        let entries = Settings.parseLanguageIndentation("swift:2s, Go:4t,bad,python:0s,ruby:3x,swift:8t")
        XCTAssertEqual(entries.map(\.language), ["swift", "go"])
        XCTAssertEqual(entries.map(\.indentation), [Settings.Indentation(tabs: false, width: 2), Settings.Indentation(tabs: true, width: 4)])
        XCTAssertEqual(Settings.formatLanguageIndentation(entries), "swift:2s,go:4t")
    }

    func testIndentationPrecedence() throws {
        let d = UserDefaults.standard
        let dir = try temporaryFolder()
        let fourSpaces = "func a() {\n    b()\n    if c {\n        d()\n    }\n}\n"

        let detected = try Document(contentsOf: try file("detected.swift", fourSpaces.replacingOccurrences(of: "    ", with: "  "), in: dir))
        XCTAssertEqual(detected.indentWidth, 2, "without a language setting the file's own indentation is used")
        XCTAssertFalse(detected.indentUsesTabs)

        d.set("swift:3t", forKey: Settings.Key.languageIndentation)
        let indented = try Document(contentsOf: try file("indented.swift", fourSpaces, in: dir))
        XCTAssertFalse(indented.indentUsesTabs, "a file's own indentation wins over the language setting")
        XCTAssertEqual(indented.indentWidth, 4)
        let swift = try Document(contentsOf: try file("a.swift", "let a = 1\nlet b = 2\n", in: dir))
        XCTAssertTrue(swift.indentUsesTabs, "the language setting covers text without indentation")
        XCTAssertEqual(swift.indentWidth, 3)

        let project = dir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try file(".editorconfig", "root = true\n\n[*]\nindent_style = space\nindent_size = 5\n", in: project)
        let configured = try Document(contentsOf: try file("b.swift", fourSpaces, in: project))
        XCTAssertFalse(configured.indentUsesTabs, ".editorconfig wins over the language setting")
        XCTAssertEqual(configured.indentWidth, 5)

        let other = try Document(contentsOf: try file("c.py", "a = 1\nb = 2\n", in: dir))
        XCTAssertEqual(other.indentWidth, 4)
        XCTAssertFalse(other.indentUsesTabs, "other languages aren't affected")

        swift.setIndentation(tabs: false, width: 8)
        d.set("swift:2s,python:2t", forKey: Settings.Key.languageIndentation)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        XCTAssertEqual(swift.indentWidth, 8, "indentation chosen for a tab is kept")
        XCTAssertFalse(swift.indentUsesTabs)
        XCTAssertTrue(other.indentUsesTabs, "changing the setting updates open files")
        XCTAssertEqual(other.indentWidth, 2)
        XCTAssertEqual(configured.indentWidth, 5)

        let untitled = Document()
        untitled.setLanguage(LanguageRegistry.shared.language(id: "python")!)
        XCTAssertTrue(untitled.indentUsesTabs, "choosing a language for a new document uses its setting")
        XCTAssertEqual(untitled.indentWidth, 2)
    }

    // MARK: Fonts

    func testLigatureSettingChangesTextAttributes() {
        let doc = document("a -> b != c")
        XCTAssertEqual(doc.textStorage.attribute(.ligature, at: 0, effectiveRange: nil) as? Int, 0, "off by default")
        UserDefaults.standard.set(true, forKey: Settings.Key.fontLigatures)
        XCTAssertEqual(Settings.shared.ligatureAttribute, 1)
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        XCTAssertEqual(doc.textStorage.attribute(.ligature, at: 0, effectiveRange: nil) as? Int, 1)
        XCTAssertEqual(doc.baseAttributes[.ligature] as? Int, 1)
    }

    func testFontWeightChangesTheFontButNotTheLineHeight() {
        UserDefaults.standard.set("", forKey: Settings.Key.fontName)
        waitForSettings()
        defer { UserDefaults.standard.removeObject(forKey: Settings.Key.fontName) }
        let regular = Settings.shared.font
        let regularLayout = TovriLayoutManager()
        regularLayout.configure(font: regular, lineHeightMultiple: 1.4)

        UserDefaults.standard.set(Settings.FontWeight.semibold.rawValue, forKey: Settings.Key.fontWeight)
        let deadline = Date().addingTimeInterval(2)
        while Settings.shared.font == regular && Date() < deadline { spin(0.02) }
        let semibold = Settings.shared.font
        XCTAssertNotEqual(semibold.fontName, regular.fontName)
        XCTAssertGreaterThan(NSFontManager.shared.weight(of: semibold), NSFontManager.shared.weight(of: regular))
        XCTAssertEqual(semibold.pointSize, regular.pointSize)
        let semiboldLayout = TovriLayoutManager()
        semiboldLayout.configure(font: semibold, lineHeightMultiple: 1.4)
        XCTAssertEqual(semiboldLayout.lineHeight, regularLayout.lineHeight, "weights share line metrics")
        XCTAssertEqual((" " as NSString).size(withAttributes: [.font: semibold]).width,
                       (" " as NSString).size(withAttributes: [.font: regular]).width, accuracy: 0.01)

        let doc = document("text")
        XCTAssertEqual((doc.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName, semibold.fontName)
        XCTAssertEqual(Settings.FontWeight(rawValue: "nonsense"), nil)
    }
}
