import AppKit
import XCTest
@testable import Tovri

/// Hot exit must bring back every unsaved buffer exactly as it was, in the format it will be saved
/// in, and must never discard backups it cannot account for.
final class SessionRestoreTests: XCTestCase {
    private var directory: URL!
    private var oldDirectory: URL!
    private var oldBufferDirectory: URL!
    private var oldProvider: (() -> [WindowSession])?
    private var oldArguments: [String: Any] = [:]
    private var store: SessionStore { SessionStore.shared }

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("TovriRestore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        oldDirectory = store.directory
        oldBufferDirectory = store.bufferDirectory
        oldProvider = store.stateProvider
        store.directory = directory.appendingPathComponent("Support", isDirectory: true)
        store.bufferDirectory = store.directory.appendingPathComponent("Buffers", isDirectory: true)
        store.stateProvider = nil
        oldArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments
        arguments[Settings.Key.hotExit] = true
        arguments[Settings.Key.restoreSession] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    override func tearDownWithError() throws {
        // Drain queued session writes so nothing lands in the real store after it is restored.
        store.stateProvider = { [] }
        _ = store.saveNow(synchronously: true)
        store.stateProvider = oldProvider
        store.directory = oldDirectory
        store.bufferDirectory = oldBufferDirectory
        UserDefaults.standard.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain)
        try FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, _ bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func append(_ text: String, to doc: Document) {
        doc.textStorage.replaceCharacters(in: NSRange(location: doc.length, length: 0), with: text)
    }

    private func close(_ controller: MainWindowController) {
        if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
        for group in controller.groups { for tab in group.tabs { tab.close() } }
        controller.teardown()
        controller.window?.delegate = nil
        controller.window?.close()
    }

    /// Runs `before` in one window, quits with hot exit, then restores into a fresh window.
    private func quitAndRelaunch(asynchronousSaveFirst: Bool = false,
                                 before: (MainWindowController) throws -> Void,
                                 betweenLaunches: () throws -> Void = {},
                                 after: (MainWindowController) throws -> Void) throws {
        try autoreleasepool {
            let first = MainWindowController()
            defer { close(first) }
            try before(first)
            store.stateProvider = { [weak first] in first.map { [$0.sessionState()] } ?? [] }
            if asynchronousSaveFirst { store.saveNow(synchronously: false) }
            try store.saveNow(synchronously: true).get()
            store.stateProvider = nil
        }
        // Let deferred editor work that still references the closed window's documents finish.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try betweenLaunches()
        let session = try XCTUnwrap(store.load()?.windows.first)
        let second = MainWindowController()
        defer { close(second) }
        second.restore(session)
        try after(second)
    }

    private func document(in controller: MainWindowController, where match: (Document) -> Bool) throws -> Document {
        try XCTUnwrap(controller.allOpenDocuments().first(where: match))
    }

    func testHotExitRestoresEveryKindOfUnsavedDocument() throws {
        let cp1252URL = try file("latin.txt", try XCTUnwrap(TextEncoding.windows1252.encode("Café\r\n")))
        let utf16URL = try file("wide.txt", try XCTUnwrap(TextEncoding.utf16LE.encode("wide\r\n")))
        let goneURL = try file("gone.txt", Data("gone text\n".utf8))
        let newURL = directory.appendingPathComponent("planned/new.swift")
        var untitledName = ""
        var sjisName = ""

        try quitAndRelaunch(before: { c in
            let untitled = Document()
            c.activeGroup.add(untitled)
            append("untitled work\n", to: untitled)
            untitledName = untitled.displayName

            let sjis = Document()
            sjis.encoding = .shiftJIS
            sjis.lineEnding = .crlf
            c.activeGroup.add(sjis)
            append("日本語\nテキスト\n", to: sjis)
            sjisName = sjis.displayName

            for (url, text) in [(cp1252URL, "Ünïcode\n"), (utf16URL, "🌏\n"), (goneURL, "rescued\n")] {
                let doc = try XCTUnwrap(c.open(url: url))
                append(text, to: doc)
            }
            append("brand new\n", to: c.openNewFile(at: newURL))
        }, betweenLaunches: {
            try FileManager.default.removeItem(at: goneURL)
            for url in [cp1252URL, utf16URL, goneURL, newURL] {
                XCTAssertNil(DocumentRegistry.shared.existing(for: url), "The first window's documents must be gone")
            }
        }, after: { c in
            XCTAssertEqual(c.allOpenDocuments().count, 6)
            XCTAssertTrue(c.allOpenDocuments().allSatisfy { $0.isDirty })

            let untitled = try document(in: c) { $0.displayName == untitledName }
            XCTAssertNil(untitled.url)
            XCTAssertEqual(untitled.string as String, "untitled work\n")

            let sjis = try document(in: c) { $0.displayName == sjisName }
            XCTAssertEqual(sjis.encoding, .shiftJIS)
            XCTAssertEqual(sjis.lineEnding, .crlf)
            XCTAssertEqual(sjis.string as String, "日本語\nテキスト\n")
            let sjisURL = directory.appendingPathComponent("sjis.txt")
            try sjis.save(to: sjisURL)
            XCTAssertEqual(try Data(contentsOf: sjisURL), TextEncoding.shiftJIS.encode("日本語\r\nテキスト\r\n"))

            let latin = try document(in: c) { $0.url == cp1252URL }
            XCTAssertEqual(latin.encoding, .windows1252)
            XCTAssertEqual(latin.lineEnding, .crlf)
            XCTAssertEqual(latin.string as String, "Café\nÜnïcode\n")
            try latin.save()
            XCTAssertEqual(try Data(contentsOf: cp1252URL), TextEncoding.windows1252.encode("Café\r\nÜnïcode\r\n"))

            let wide = try document(in: c) { $0.url == utf16URL }
            XCTAssertEqual(wide.encoding, .utf16LE)
            try wide.save()
            XCTAssertEqual(try Data(contentsOf: utf16URL), TextEncoding.utf16LE.encode("wide\r\n🌏\r\n"))

            let gone = try document(in: c) { $0.url == goneURL }
            XCTAssertEqual(gone.string as String, "gone text\nrescued\n")
            XCTAssertTrue(gone.isNewFile)

            let planned = try document(in: c) { $0.url == newURL }
            XCTAssertTrue(planned.isNewFile)
            XCTAssertEqual(planned.string as String, "brand new\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
        })
    }

    func testRestoreKeepsTheDiskFormatOfFilesChangedWhileTheAppWasClosed() throws {
        let dosURL = try file("dos.txt", Data("one\r\ntwo\r\n".utf8))
        let utf8URL = try file("utf8.txt", Data("Café\n".utf8))
        try quitAndRelaunch(before: { c in
            XCTAssertEqual(c.open(url: dosURL)?.lineEnding, .crlf)
            XCTAssertEqual(c.open(url: utf8URL)?.encoding, .utf8)
        }, betweenLaunches: {
            try Data("one\ntwo\n".utf8).write(to: dosURL)
            try XCTUnwrap(TextEncoding.windows1252.encode("Café\n")).write(to: utf8URL)
        }, after: { c in
            let dos = try document(in: c) { $0.url == dosURL }
            XCTAssertEqual(dos.lineEnding, .lf)
            append("three\n", to: dos)
            try dos.save()
            XCTAssertEqual(try String(contentsOf: dosURL, encoding: .utf8), "one\ntwo\nthree\n")

            let latin = try document(in: c) { $0.url == utf8URL }
            XCTAssertEqual(latin.encoding, .windows1252)
            XCTAssertEqual(latin.string as String, "Café\n")
            XCTAssertFalse(latin.isDirty)
        })
    }

    func testBuffersBeyondTheLargeThresholdAreSavedOnQuit() throws {
        let line = "large buffer line\n"
        let count = 4_000_000 / line.utf16.count + 10_000
        let largeURL = try file("large.txt", Data(String(repeating: "disk line\r\n", count: 400_000).utf8))
        var untitledName = ""
        try quitAndRelaunch(asynchronousSaveFirst: true, before: { c in
            let untitled = Document()
            c.activeGroup.add(untitled)
            append(String(repeating: line, count: count), to: untitled)
            XCTAssertGreaterThan(untitled.length, 4_000_000)
            untitledName = untitled.displayName
            let large = try XCTUnwrap(c.open(url: largeURL))
            append(String(repeating: line, count: 100_000), to: large)
            XCTAssertGreaterThan(large.length, 4_000_000)
        }, after: { c in
            let untitled = try document(in: c) { $0.displayName == untitledName }
            XCTAssertEqual(untitled.length, line.utf16.count * count)
            XCTAssertTrue(untitled.isDirty)
            let large = try document(in: c) { $0.url == largeURL }
            XCTAssertEqual(large.lineEnding, .crlf)
            XCTAssertTrue(large.isDirty)
            XCTAssertEqual(large.string as String,
                           String(repeating: "disk line\n", count: 400_000) + String(repeating: line, count: 100_000))
        })
    }

    func testMissingBufferFilesRestoreWithoutCrashingOrLosingTheFile() throws {
        let url = try file("backed.txt", Data("on disk\n".utf8))
        var untitledName = ""
        try quitAndRelaunch(before: { c in
            let untitled = Document()
            c.activeGroup.add(untitled)
            append("lost backup\n", to: untitled)
            untitledName = untitled.displayName
            append("edit\n", to: try XCTUnwrap(c.open(url: url)))
        }, betweenLaunches: {
            for name in try FileManager.default.contentsOfDirectory(atPath: store.bufferDirectory.path) {
                try FileManager.default.removeItem(at: store.bufferDirectory.appendingPathComponent(name))
            }
        }, after: { c in
            let backed = try document(in: c) { $0.url == url }
            XCTAssertEqual(backed.string as String, "on disk\n")
            XCTAssertFalse(backed.isDirty)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "on disk\n")
            XCTAssertNotNil(c.allOpenDocuments().first { $0.displayName == untitledName })
            store.stateProvider = { [c.sessionState()] }
            XCTAssertNoThrow(try store.saveNow(synchronously: true).get())
        })
    }
}

/// Uses separate store instances to model one launch writing backups and the next reading them.
final class SessionManifestRecoveryTests: XCTestCase {
    private var directory: URL!
    private var oldArguments: [String: Any] = [:]

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("TovriManifest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        oldArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments
        arguments[Settings.Key.hotExit] = true
        arguments[Settings.Key.restoreSession] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain)
        try FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> SessionStore {
        let store = SessionStore()
        store.directory = directory
        store.bufferDirectory = directory.appendingPathComponent("Buffers")
        return store
    }

    private func bind(_ store: SessionStore, _ docs: [Document]) {
        store.stateProvider = { [weak store] in
            let tabs = docs.map { doc in
                TabSession(path: nil, untitledName: doc.displayName, buffer: store?.bufferName(for: doc),
                           selection: 0, selectionLength: 0, scrollX: 0, scrollY: 0,
                           language: nil, encoding: doc.encoding.rawValue, lineEnding: doc.lineEnding.rawValue)
            }
            return [WindowSession(frame: "", folder: nil, sidebarVisible: false, sidebarWidth: 240,
                                  layout: "single", groups: [GroupSession(tabs: tabs, selected: 0)],
                                  activeGroup: 0, fullScreen: false)]
        }
    }

    private func buffers(_ store: SessionStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.bufferDirectory.path).sorted()
    }

    private func writePreviousLaunch() throws -> (SessionStore, [String]) {
        let previous = makeStore()
        let doc = Document()
        doc.restoreBuffer("work from the previous launch")
        bind(previous, [doc])
        try previous.saveNow(synchronously: true).get()
        let names = try buffers(previous)
        XCTAssertEqual(names.count, 1)
        return (previous, names)
    }

    func testUnreadableManifestNeverDeletesTheBackupsItReferenced() throws {
        let (_, names) = try writePreviousLaunch()
        let manifest = try Data(contentsOf: makeStore().sessionFile)
        let corruptions: [String: Data] = [
            "truncated": manifest.prefix(manifest.count / 2),
            "empty": Data(),
            "garbage": Data([0xFF, 0x00, 0x7B, 0x22]),
            "unexpected shape": Data(#"{"version":2,"windows":{"main":true}}"#.utf8),
        ]
        for (name, bytes) in corruptions {
            try bytes.write(to: makeStore().sessionFile)
            let next = makeStore()
            XCTAssertNil(next.load(), name)
            let fresh = Document()
            fresh.restoreBuffer("new launch work \(name)")
            bind(next, [fresh])
            try next.saveNow(synchronously: true).get()
            let remaining = try buffers(next)
            for old in names { XCTAssertTrue(remaining.contains(old), "\(name): \(old) was deleted") }
            XCTAssertEqual(try String(contentsOf: next.bufferDirectory.appendingPathComponent(names[0]), encoding: .utf8),
                           "work from the previous launch")
        }
    }

    func testBackupsFromALoadedSessionAreCollectedOnceNoLongerNeeded() throws {
        let (_, names) = try writePreviousLaunch()
        let stray = makeStore().bufferDirectory.appendingPathComponent("not-ours.txt")
        try Data("someone else's file".utf8).write(to: stray)

        let next = makeStore()
        let loaded = try XCTUnwrap(next.load())
        XCTAssertEqual(loaded.windows.first?.groups.first?.tabs.first?.buffer, names[0])
        let doc = Document()
        doc.restoreBuffer("replacement")
        bind(next, [doc])
        try next.saveNow(synchronously: true).get()
        let remaining = try buffers(next)
        XCTAssertFalse(remaining.contains(names[0]), "A buffer the loaded session owned should be collected")
        XCTAssertTrue(remaining.contains("not-ours.txt"))
        XCTAssertEqual(remaining.count, 2)
    }
}
