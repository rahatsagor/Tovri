import AppKit
import XCTest
@testable import Tovri

/// Regression tests for hot exit, reloading and saving paths that could lose edits or overwrite
/// newer text on disk.
final class FileSafetyRegressionTests2: XCTestCase {
    private var directory: URL!
    private var oldDirectory: URL!
    private var oldBufferDirectory: URL!
    private var oldProvider: (() -> [WindowSession])?
    private var oldArguments: [String: Any] = [:]
    private var controllers: [MainWindowController] = []
    private var store: SessionStore { SessionStore.shared }

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("TovriSafety2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        oldDirectory = store.directory
        oldBufferDirectory = store.bufferDirectory
        oldProvider = store.stateProvider
        store.directory = directory.appendingPathComponent("Support", isDirectory: true)
        store.bufferDirectory = store.directory.appendingPathComponent("Buffers", isDirectory: true)
        store.stateProvider = nil
        oldArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        setDefaults([Settings.Key.hotExit: true, Settings.Key.restoreSession: true,
                     Settings.Key.trimTrailingWhitespace: false, Settings.Key.ensureNewlineAtEOF: false])
    }

    override func tearDownWithError() throws {
        controllers.forEach(close)
        controllers = []
        store.stateProvider = { [] }
        _ = store.saveNow(synchronously: true)
        store.stateProvider = oldProvider
        store.directory = oldDirectory
        store.bufferDirectory = oldBufferDirectory
        UserDefaults.standard.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain)
        if let items = FileManager.default.enumerator(atPath: directory.path) {
            for case let item as String in items {
                let path = directory.appendingPathComponent(item).path
                chflags(path, 0)
                chmod(path, 0o755)
            }
        }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private func setDefaults(_ values: [String: Any]) {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        for (k, v) in values { arguments[k] = v }
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    private func file(_ name: String, _ text: String) throws -> URL { try file(name, Data(text.utf8)) }

    private func file(_ name: String, _ bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func append(_ text: String, to doc: Document) {
        doc.textStorage.replaceCharacters(in: NSRange(location: doc.length, length: 0), with: text)
    }

    private func makeController() -> MainWindowController {
        let c = MainWindowController()
        controllers.append(c)
        return c
    }

    private func close(_ controller: MainWindowController) {
        if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
        for group in controller.groups { for tab in group.tabs { tab.close() } }
        controller.teardown()
        controller.window?.delegate = nil
        controller.window?.close()
        controllers.removeAll { $0 === controller }
    }

    /// Runs `body` with windows that are closed and released afterwards, as quitting does.
    private func withWindows<T>(_ count: Int, restoring sessions: [WindowSession] = [],
                                _ body: ([MainWindowController]) throws -> T) rethrows -> T {
        try autoreleasepool {
            let cs = (0..<max(count, sessions.count)).map { _ in MainWindowController() }
            defer { cs.forEach(close) }
            for (c, w) in zip(cs, sessions) { c.restore(w) }
            return try body(cs)
        }
    }

    private func withWindow<T>(_ body: (MainWindowController) throws -> T) rethrows -> T {
        try withWindows(1) { try body($0[0]) }
    }

    /// Lets deferred editor work finish so the closed windows' documents are released.
    private func settle(releasing urls: [URL]) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        for url in urls { XCTAssertNil(DocumentRegistry.shared.existing(for: url), "\(url.lastPathComponent) must be released") }
    }

    /// Writes the windows as the session file, then reads them back as the next launch would.
    private func persist(_ windows: [WindowSession]) throws -> [WindowSession] {
        store.stateProvider = { windows }
        try store.saveNow(synchronously: true).get()
        store.stateProvider = nil
        return try XCTUnwrap(store.load()).windows
    }

    private func relaunch(_ windows: [WindowSession]) -> [MainWindowController] {
        windows.map { w in
            let c = makeController()
            c.restore(w)
            return c
        }
    }

    private func menuItem(_ value: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = value
        return item
    }

    private func document(_ c: MainWindowController, _ match: (Document) -> Bool) throws -> Document {
        try XCTUnwrap(c.allOpenDocuments().first(where: match))
    }

    // MARK: 1. A closed window's backup never replaces newer unsaved edits

    func testClosedWindowBackupDoesNotOverwriteAnotherWindowsEditsAtLaunch() throws {
        let url = try file("f.txt", "disk\n")
        let closedA = try withWindow { a in
            append("X\n", to: try XCTUnwrap(a.open(url: url)))
            return a.sessionState()
        }
        settle(releasing: [url])
        let saved = try withWindow { b in
            append("Y\n", to: try XCTUnwrap(b.open(url: url)))
            // AppDelegate.sessionWindows puts open windows first, then closed ones with unsaved changes.
            return try persist(AppDelegate.sessionWindows(open: [b.sessionState()], closed: [closedA]))
        }
        settle(releasing: [url])

        let restored = relaunch(saved)
        let doc = try document(restored[0]) { $0.url == url }
        XCTAssertEqual(doc.string as String, "disk\nY\n", "The newer window's edits must survive")
        XCTAssertTrue(doc.isDirty)
        XCTAssertNil(restored[1].allOpenDocuments().first { $0 === doc && ($0.string as String) != "disk\nY\n" })
        let copy = try document(restored[1]) { $0.url == nil }
        XCTAssertEqual(copy.displayName, "f.txt (unsaved copy)")
        XCTAssertEqual(copy.string as String, "disk\nX\n", "The closed window's independent edits are kept too")
        XCTAssertTrue(copy.isDirty)
        XCTAssertEqual(try read(url), "disk\n")
    }

    func testReopeningAClosedWindowKeepsTheLiveDocumentsEdits() throws {
        let url = try file("f.txt", "disk\n")
        let closedA = try withWindow { a in
            append("X\n", to: try XCTUnwrap(a.open(url: url)))
            return a.sessionState()
        }
        settle(releasing: [url])
        let b = makeController()
        let live = try XCTUnwrap(b.open(url: url))
        append("Y\n", to: live)
        let saved = try persist([b.sessionState(), closedA])

        let reopened = makeController()
        reopened.restore(saved[1])
        XCTAssertEqual(live.string as String, "disk\nY\n")
        XCTAssertTrue(live.isDirty)
        XCTAssertEqual(try document(reopened) { $0.url == nil }.string as String, "disk\nX\n")
    }

    func testOlderBackupOfASharedBufferIsSkippedAndANewerOneWins() throws {
        let url = try file("shared.txt", "disk\n")
        let saved = try withWindows(2) { cs in
            let doc = try XCTUnwrap(cs[0].open(url: url))
            XCTAssertTrue(cs[1].open(url: url) === doc)
            append("X\n", to: doc)
            let closedA = cs[0].sessionState()
            append("Y\n", to: doc)
            return try persist([cs[1].sessionState(), closedA])
        }
        settle(releasing: [url])

        // Open window first (the real order): the stale snapshot is skipped, not copied.
        try withWindows(0, restoring: saved) { restored in
            let first = try document(restored[0]) { $0.url == url }
            XCTAssertEqual(first.string as String, "disk\nX\nY\n")
            XCTAssertTrue(try document(restored[1]) { $0.url == url } === first)
            XCTAssertFalse(restored[1].allOpenDocuments().contains { $0.url == nil })
        }
        settle(releasing: [url])

        // The older snapshot restored first: the newer backup of the same buffer replaces it.
        try withWindows(0, restoring: [saved[1], saved[0]]) { restored in
            XCTAssertEqual(try document(restored[0]) { $0.url == url }.string as String, "disk\nX\nY\n")
            XCTAssertFalse(restored.contains { $0.allOpenDocuments().contains { $0.url == nil } })
        }
    }

    func testSavedTabSupersedesAnOlderBackupOfTheSameBuffer() throws {
        let url = try file("saved.txt", "disk\n")
        let saved = try withWindows(2) { cs in
            let doc = try XCTUnwrap(cs[0].open(url: url))
            _ = cs[1].open(url: url)
            append("X\n", to: doc)
            let closedA = cs[0].sessionState()
            append("Y\n", to: doc)
            try doc.save()
            return try persist([cs[1].sessionState(), closedA])
        }
        settle(releasing: [url])

        let restored = relaunch(saved)
        let reopened = try document(restored[1]) { $0.url == url }
        XCTAssertEqual(reopened.string as String, "disk\nX\nY\n")
        XCTAssertFalse(reopened.isDirty, "A backup older than the saved file must not come back as unsaved text")
    }

    func testLegacyBackupsWithoutSourcesNeverReplaceRestoredEdits() throws {
        let url = try file("legacy.txt", "disk\n")
        try FileManager.default.createDirectory(at: store.bufferDirectory, withIntermediateDirectories: true)
        func tab(_ buffer: String, _ text: String) throws -> TabSession {
            try text.write(to: store.bufferDirectory.appendingPathComponent(buffer), atomically: true, encoding: .utf8)
            return TabSession(path: url.path, untitledName: nil, buffer: buffer, selection: 0, selectionLength: 0,
                              scrollX: 0, scrollY: 0, language: nil, encoding: "UTF-8", lineEnding: "LF")
        }
        func window(_ t: TabSession) -> WindowSession {
            WindowSession(frame: "", folder: nil, sidebarVisible: false, sidebarWidth: 240, layout: "single",
                          groups: [GroupSession(tabs: [t], selected: 0)], activeGroup: 0, fullScreen: false)
        }
        let restored = relaunch([window(try tab("old-b.txt", "disk\nY\n")), window(try tab("old-a.txt", "disk\nX\n"))])
        XCTAssertEqual(try document(restored[0]) { $0.url == url }.string as String, "disk\nY\n")
        XCTAssertEqual(try document(restored[1]) { $0.url == nil }.string as String, "disk\nX\n")
        let name = "\(UUID().uuidString)-42.txt"
        XCTAssertEqual(SessionStore.backupSource(ofBufferNamed: name)?.version, 42)
        XCTAssertNil(SessionStore.backupSource(ofBufferNamed: "old-a.txt"))
    }

    // MARK: 2. Reopen with Encoding asks before discarding edits

    func testReopenWithEncodingAsksBeforeDiscardingUnsavedEdits() throws {
        let url = try file("latin.txt", try XCTUnwrap(TextEncoding.windows1252.encode("Café\n")))
        let c = makeController()
        let doc = try XCTUnwrap(c.open(url: url))
        append("unsaved\n", to: doc)
        let window = try XCTUnwrap(c.window)

        c.reopenWithEncoding(menuItem(TextEncoding.latin1.rawValue))
        XCTAssertEqual(doc.string as String, "Café\nunsaved\n", "Nothing may be discarded before the user answers")
        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(doc.string as String, "Café\nunsaved\n")
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.encoding, .windows1252)

        c.reopenWithEncoding(menuItem(TextEncoding.latin1.rawValue))
        let confirm = try XCTUnwrap(window.attachedSheet)
        window.endSheet(confirm, returnCode: .alertFirstButtonReturn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(doc.string as String, "Café\n")
        XCTAssertEqual(doc.encoding, .latin1)
        XCTAssertFalse(doc.isDirty)

        c.reopenWithEncoding(menuItem(TextEncoding.windows1252.rawValue))
        XCTAssertNil(window.attachedSheet, "A clean document reopens without asking")
        XCTAssertEqual(doc.encoding, .windows1252)
    }

    // MARK: 3. A backup of a file that changed on disk since doesn't silently replace it

    func testRestoredBackupOfAFileChangedWhileClosedAsksBeforeSaving() throws {
        let changed = try file("a.swift", "let a = 1\n")
        let unchanged = try file("b.swift", "let b = 1\n")
        let saved = try withWindow { c in
            append("// mine\n", to: try XCTUnwrap(c.open(url: changed)))
            append("// mine\n", to: try XCTUnwrap(c.open(url: unchanged)))
            return try persist([c.sessionState()])
        }
        XCTAssertNotNil(saved[0].groups[0].tabs.first?.diskStamp)
        settle(releasing: [changed, unchanged])

        try Data("let a = 2 // pulled\n".utf8).write(to: changed)
        let restored = relaunch(saved)[0]
        let doc = try document(restored) { $0.url == changed }
        XCTAssertEqual(doc.string as String, "let a = 1\n// mine\n")
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.checkDiskStatus(), .modified, "The change made while Tovri was closed must be noticed")
        XCTAssertThrowsError(try doc.save()) { error in
            guard case DocumentError.modifiedOnDisk = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try read(changed), "let a = 2 // pulled\n")
        restored.save(doc, interactive: false)
        XCTAssertEqual(try read(changed), "let a = 2 // pulled\n", "Automatic saves must skip it")

        let other = try document(restored) { $0.url == unchanged }
        XCTAssertEqual(other.checkDiskStatus(), .unchanged)
        try other.save()
        XCTAssertEqual(try read(unchanged), "let b = 1\n// mine\n")
    }

    func testOldSessionTabsWithoutAStampStillDecode() throws {
        let json = #"{"path":"/tmp/x.txt","selection":0,"selectionLength":0,"scrollX":0,"scrollY":0,"buffer":"b.txt"}"#
        let tab = try JSONDecoder().decode(TabSession.self, from: Data(json.utf8))
        XCTAssertNil(tab.diskStamp)
        XCTAssertNil(tab.documentID)
        XCTAssertNil(tab.encodingDetected)
    }

    // MARK: 4. A file deleted and recreated doesn't leave a clean document unsaved

    func testFileThatComesBackLeavesAnUneditedDocumentClean() throws {
        let url = try file("branch.txt", "on main\n")
        let edited = try file("edited.txt", "on main\n")
        let c = makeController()
        let doc = try XCTUnwrap(c.open(url: url))
        let dirty = try XCTUnwrap(c.open(url: edited))
        append("work\n", to: dirty)
        for u in [url, edited] { try FileManager.default.removeItem(at: u) }
        c.handleDiskChange(doc)
        c.handleDiskChange(dirty)
        XCTAssertTrue(doc.isDirty, "A deleted file's text must count as unsaved")

        try Data("on main\n".utf8).write(to: url)
        try Data("on main\n".utf8).write(to: edited)
        c.handleDiskChange(doc)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(doc.string as String, "on main\n")
        XCTAssertNil(c.window?.attachedSheet, "An unedited file that came back must not ask about unsaved changes")
        XCTAssertEqual(doc.checkDiskStatus(), .unchanged)

        c.handleDiskChange(dirty)
        XCTAssertTrue(dirty.isDirty, "Real edits stay unsaved")
        XCTAssertEqual(dirty.string as String, "on main\nwork\n")
        if let sheet = c.window?.attachedSheet { c.window?.endSheet(sheet) }

        // Back with different contents: the clean buffer follows the file.
        try FileManager.default.removeItem(at: url)
        c.handleDiskChange(doc)
        try Data("on branch\n".utf8).write(to: url)
        c.handleDiskChange(doc)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(doc.string as String, "on branch\n")
    }

    func testEditedThenUndoneWhileDeletedIsCleanOnceTheFileReturns() throws {
        let url = try file("undo.txt", "text\n")
        let doc = try Document(contentsOf: url)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(doc.checkDiskStatus(), .deleted)
        doc.markDeletedOnDisk()
        editor.textView.setSelectedRange(NSRange(location: doc.length, length: 0))
        editor.textView.insertText("x", replacementRange: editor.textView.selectedRange())
        doc.undoManager.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(doc.isDirty)
        try Data("text\n".utf8).write(to: url)
        XCTAssertEqual(doc.checkDiskStatus(), .modified)
        XCTAssertFalse(doc.isDirty)
    }

    // MARK: 5. A removed BOM isn't added back, and converted files are detected again

    func testRemovedByteOrderMarkIsNotAddedBackOnSave() throws {
        let url = try file("bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("marked\n".utf8))
        let doc = try Document(contentsOf: url)
        XCTAssertEqual(doc.encoding, .utf8BOM)
        try Data("unmarked\n".utf8).write(to: url)
        try doc.reload()
        XCTAssertEqual(doc.encoding, .utf8)
        append("more\n", to: doc)
        try doc.save()
        XCTAssertEqual(try Data(contentsOf: url), Data("unmarked\nmore\n".utf8))

        let explicit = TextEncoding.decode(Data("plain".utf8), preferred: .utf8BOM)
        XCTAssertEqual(explicit.encoding, .utf8)
        XCTAssertEqual(explicit.text, "plain")
    }

    func testUTF16FileConvertedToUTF8IsDecodedAsUTF8() throws {
        let url = try file("wide.txt", try XCTUnwrap(TextEncoding.utf16LE.encode("wide ✓\n")))
        let doc = try Document(contentsOf: url, encoding: .utf16LE)
        XCTAssertEqual(doc.encoding, .utf16LE)
        try Data("narrow ✓\n".utf8).write(to: url)
        try doc.reload()
        XCTAssertEqual(doc.encoding, .utf8)
        XCTAssertEqual(doc.string as String, "narrow ✓\n")

        // UTF-16 without a BOM is still read as UTF-16 when that is what was chosen.
        let bomless = Data("hi\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        XCTAssertEqual(TextEncoding.decode(bomless, preferred: .utf16LE).text, "hi\n")
        XCTAssertEqual(TextEncoding.decode(Data([0xFE, 0xFF, 0x00, 0x61]), preferred: .utf16LE).encoding, .utf16BE)
        XCTAssertEqual(TextEncoding.decode(Data(), preferred: .utf16LE).encoding, .utf16LE)
    }

    func testDetectedSingleByteFileConvertedToUTF8IsDetectedAgain() throws {
        let url = try file("legacy.txt", try XCTUnwrap(TextEncoding.windows1252.encode("Café – 5€\n")))
        let doc = try Document(contentsOf: url)
        XCTAssertEqual(doc.encoding, .windows1252)
        XCTAssertTrue(doc.encodingWasDetected)
        try Data("Café – 5€\n".utf8).write(to: url)
        try doc.reload()
        XCTAssertEqual(doc.encoding, .utf8)
        XCTAssertEqual(doc.string as String, "Café – 5€\n", "UTF-8 bytes must not be read as Windows 1252")
        try doc.save()
        XCTAssertEqual(try read(url), "Café – 5€\n")
    }

    func testChosenEncodingsAreStillPreferredOnReload() throws {
        let sjis = try file("sjis.txt", try XCTUnwrap(TextEncoding.shiftJIS.encode("こんにちは\n")))
        let doc = try Document(contentsOf: sjis, encoding: .shiftJIS)
        XCTAssertFalse(doc.encodingWasDetected)
        try doc.reload()
        XCTAssertEqual(doc.encoding, .shiftJIS)
        XCTAssertEqual(doc.string as String, "こんにちは\n")

        let latin = try file("latin.txt", "Caf\u{C3}\u{A9}\n")
        let chosen = try Document(contentsOf: latin)
        XCTAssertEqual(chosen.encoding, .utf8)
        try chosen.reload(encoding: .latin1)
        XCTAssertEqual(chosen.encoding, .latin1)
        try chosen.reload()
        XCTAssertEqual(chosen.encoding, .latin1, "An encoding the user picked survives automatic reloads")
    }

    func testRestoreDetectsTheEncodingAgainForFilesConvertedWhileClosed() throws {
        let url = try file("legacy.txt", try XCTUnwrap(TextEncoding.windows1252.encode("Café\n")))
        let saved = try withWindow { c in
            XCTAssertEqual(c.open(url: url)?.encoding, .windows1252)
            return try persist([c.sessionState()])
        }
        XCTAssertEqual(saved[0].groups[0].tabs[0].encodingDetected, true)
        settle(releasing: [url])
        try Data("Café\n".utf8).write(to: url)
        let doc = try document(relaunch(saved)[0]) { $0.url == url }
        XCTAssertEqual(doc.encoding, .utf8)
        XCTAssertEqual(doc.string as String, "Café\n")
    }

    // MARK: 6. Save As and moves follow the new folder's EditorConfig

    func testSaveAsAndMovesFollowTheNewFoldersEditorConfig() throws {
        setDefaults([Settings.Key.detectIndentation: true])
        _ = try file("tabs/.editorconfig", "root = true\n[*]\nindent_style = tab\ntab_width = 8\n")
        _ = try file("spaces/.editorconfig", "root = true\n[*]\nindent_style = space\nindent_size = 2\ntrim_trailing_whitespace = true\n")
        let url = try file("tabs/code.txt", "line\n")
        let doc = try Document(contentsOf: url)
        XCTAssertTrue(doc.indentUsesTabs)
        XCTAssertEqual(doc.indentWidth, 8)

        try doc.save(to: directory.appendingPathComponent("spaces/code.txt"))
        XCTAssertFalse(doc.indentUsesTabs)
        XCTAssertEqual(doc.indentWidth, 2)
        XCTAssertEqual(doc.saveCleanups().trimTrailingWhitespace, true)

        let moved = directory.appendingPathComponent("tabs/moved.txt")
        try FileManager.default.moveItem(at: directory.appendingPathComponent("spaces/code.txt"), to: moved)
        doc.fileDidMove(to: moved)
        XCTAssertTrue(doc.indentUsesTabs)
        XCTAssertEqual(doc.indentWidth, 8)
        XCTAssertNil(doc.editorConfig.trimTrailingWhitespace)

        doc.setIndentation(tabs: false, width: 3)
        try doc.save(to: directory.appendingPathComponent("spaces/chosen.txt"))
        XCTAssertFalse(doc.indentUsesTabs)
        XCTAssertEqual(doc.indentWidth, 3, "Indentation the user chose is kept")
        XCTAssertEqual(doc.saveCleanups().trimTrailingWhitespace, true)
    }

    func testEditorConfigAtTheFileSystemRootMatches() {
        XCTAssertTrue(EditorConfig.globMatches("*.txt", directory: "/", path: "/tmp/notes.txt"))
        XCTAssertTrue(EditorConfig.globMatches("/tmp/*.txt", directory: "/", path: "/tmp/notes.txt"))
        XCTAssertTrue(EditorConfig.globMatches("*.txt", directory: "/tmp", path: "/tmp/notes.txt"))
        XCTAssertFalse(EditorConfig.globMatches("*.txt", directory: "/tm", path: "/tmp/notes.txt"))
    }

    // MARK: 7. Reading without mapping the file

    func testFilesAreReadCompletelyWithoutMapping() throws {
        for size in [0, 1, 65_535, 65_536, 300_001] {
            let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 % 251) })
            let url = try file("read-\(size).bin", bytes)
            XCTAssertEqual(try Document.readFile(url), bytes, "\(size) bytes")
        }
        XCTAssertThrowsError(try Document.readFile(directory.appendingPathComponent("missing.txt"))) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoSuchFile)
        }
    }

    // MARK: 8. Changing the line ending is an unsaved, undoable edit

    func testChangingTheLineEndingMarksTheDocumentUnsavedInsteadOfSaving() throws {
        let url = try file("unix.txt", "a\nb\n")
        let c = makeController()
        let doc = try XCTUnwrap(c.open(url: url))
        c.setLineEnding(menuItem(LineEnding.crlf.rawValue))
        XCTAssertEqual(doc.lineEnding, .crlf)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(try read(url), "a\nb\n", "The file must not be written until the user saves")

        doc.undoManager.undo()
        XCTAssertEqual(doc.lineEnding, .lf)
        XCTAssertFalse(doc.isDirty)
        doc.undoManager.redo()
        XCTAssertEqual(doc.lineEnding, .crlf)
        XCTAssertTrue(doc.isDirty)

        try doc.save()
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try read(url), "a\r\nb\r\n")
    }

    func testUnsavedLineEndingChangeSurvivesHotExit() throws {
        let url = try file("dos.txt", "a\r\nb\r\n")
        let saved = try withWindow { c in
            let doc = try XCTUnwrap(c.open(url: url))
            doc.setLineEnding(.lf)
            XCTAssertTrue(doc.isDirty)
            return try persist([c.sessionState()])
        }
        settle(releasing: [url])

        let restored = try document(relaunch(saved)[0]) { $0.url == url }
        XCTAssertEqual(restored.lineEnding, .lf)
        XCTAssertTrue(restored.isDirty)
        try restored.save()
        XCTAssertEqual(try read(url), "a\nb\n")
    }

    // MARK: Disk stamps, hard links and file flags

    func testSameSizeReplacementWithTheSameTimestampIsDetected() throws {
        let url = try file("same.txt", "aaaa\n")
        let doc = try Document(contentsOf: url)
        var info = stat()
        XCTAssertEqual(stat(url.path, &info), 0)
        let temp = try file(".same.tmp", "bbbb\n")
        var times = [info.st_atimespec, info.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, temp.path, &times, 0), 0)
        XCTAssertEqual(rename(temp.path, url.path), 0)
        XCTAssertEqual(doc.checkDiskStatus(), .modified)
        append("mine\n", to: doc)
        XCTAssertThrowsError(try doc.save())
        XCTAssertEqual(try read(url), "bbbb\n")
    }

    func testSavingAHardLinkedFileUpdatesEveryLink() throws {
        let url = try file("linked.txt", "shared\n")
        let other = directory.appendingPathComponent("other-link.txt")
        XCTAssertEqual(link(url.path, other.path), 0)
        var before = stat()
        XCTAssertEqual(stat(url.path, &before), 0)
        let doc = try Document(contentsOf: url)
        append("edited\n", to: doc)
        try doc.save()
        XCTAssertEqual(try read(other), "shared\nedited\n")
        var after = stat()
        XCTAssertEqual(stat(url.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_nlink, 2)
        XCTAssertEqual(doc.checkDiskStatus(), .unchanged)
        // Shorter text must not leave the old tail behind.
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: doc.length), with: "x")
        try doc.save()
        XCTAssertEqual(try read(other), "x")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["linked.txt", "other-link.txt"])
    }

    func testSaveKeepsTheHiddenFlag() throws {
        let url = try file("hidden.txt", "secret\n")
        XCTAssertEqual(chflags(url.path, UInt32(UF_HIDDEN)), 0)
        let doc = try Document(contentsOf: url)
        append("more\n", to: doc)
        try doc.save()
        var info = stat()
        XCTAssertEqual(stat(url.path, &info), 0)
        XCTAssertNotEqual(info.st_flags & UInt32(UF_HIDDEN), 0)
        XCTAssertEqual(try read(url), "secret\nmore\n")
    }

    // MARK: Periodic backups of large buffers

    func testLargeBuffersAreBackedUpBeforeQuitButNotOnEveryPass() throws {
        let doc = Document()
        doc.restoreBuffer(String(repeating: "large buffer line\n", count: 4_000_000 / 18 + 1_000))
        XCTAssertGreaterThan(doc.length, 4_000_000)
        let first = try XCTUnwrap(store.bufferName(for: doc), "A large buffer must get a backup before quitting")
        XCTAssertEqual(store.bufferName(for: doc), first, "A second tab of the same document shares the queued backup")
        append("more\n", to: doc)
        XCTAssertNil(store.bufferName(for: doc), "The next version waits for the slower interval")
    }

    // MARK: Save cleanups without an editor

    func testSaveAllAppliesTheSameCleanupsAsSavingInTheEditor() throws {
        setDefaults([Settings.Key.trimTrailingWhitespace: true, Settings.Key.ensureNewlineAtEOF: true])
        let source = "one  \ntwo\t\nthree"
        let shownURL = try file("shown.txt", source)
        let hiddenURL = try file("hidden.txt", source)
        let c = makeController()
        let hidden = try Document(contentsOf: hiddenURL)
        DocumentRegistry.shared.register(hidden)
        let tab = c.activeGroup.add(hidden, select: false)
        let shown = try XCTUnwrap(c.open(url: shownURL))
        XCTAssertNil(tab.editor, "The background tab must have no editor for this test")
        append(" ", to: shown)
        append(" ", to: hidden)

        c.saveAllDocuments(nil)
        XCTAssertEqual(try read(shownURL), "one\ntwo\nthree\n")
        XCTAssertEqual(try read(hiddenURL), try read(shownURL))
        XCTAssertFalse(hidden.isDirty)

        hidden.undoManager.undo()
        XCTAssertEqual(hidden.string as String, source + " ", "The cleanups are one undoable change")
    }
}
