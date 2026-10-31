import AppKit
import XCTest
@testable import Tovri

final class SessionPersistenceTests: XCTestCase {
    private var directory: URL!
    private var store: SessionStore!
    private var oldArguments: [String: Any] = [:]

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("TovriSession-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore()
        store.directory = directory
        store.bufferDirectory = directory.appendingPathComponent("Buffers")
        oldArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments
        arguments[Settings.Key.hotExit] = true
        arguments[Settings.Key.restoreSession] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    override func tearDownWithError() throws {
        store.stateProvider = nil
        store = nil
        UserDefaults.standard.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain)
        try FileManager.default.removeItem(at: directory)
    }

    private func bind(_ doc: Document) {
        let store = self.store!
        store.stateProvider = { [weak store] in
            let tab = TabSession(path: nil, untitledName: doc.displayName, buffer: store?.bufferName(for: doc),
                                 selection: 0, selectionLength: 0, scrollX: 0, scrollY: 0,
                                 language: nil, encoding: doc.encoding.rawValue, lineEnding: doc.lineEnding.rawValue)
            return [WindowSession(frame: "", folder: nil, sidebarVisible: false, sidebarWidth: 240,
                                  layout: "single", groups: [GroupSession(tabs: [tab], selected: 0)],
                                  activeGroup: 0, fullScreen: false)]
        }
    }

    private func savedBuffer() throws -> URL {
        let name = try XCTUnwrap(store.load()?.windows.first?.groups.first?.tabs.first?.buffer)
        return store.bufferDirectory.appendingPathComponent(name)
    }

    func testFailedBufferWriteIsReportedAndRetriedWithoutAnotherEdit() throws {
        let doc = Document()
        doc.restoreBuffer("unsaved work")
        bind(doc)
        try Data("blocks directory creation".utf8).write(to: store.bufferDirectory)

        XCTAssertThrowsError(try store.saveNow(synchronously: true).get())
        XCTAssertNil(store.load(), "A manifest must not reference a failed backup")

        try FileManager.default.removeItem(at: store.bufferDirectory)
        try store.saveNow(synchronously: true).get()
        XCTAssertEqual(try String(contentsOf: savedBuffer(), encoding: .utf8), "unsaved work")
    }

    func testFailedBufferReplacementPreservesPreviousSessionUntilRetrySucceeds() throws {
        let doc = Document()
        doc.restoreBuffer("previous backup")
        bind(doc)
        try store.saveNow(synchronously: true).get()
        let previousManifest = try Data(contentsOf: store.sessionFile)
        let previousBuffer = try savedBuffer()

        doc.restoreBuffer("latest unsaved work")
        let nextName = try XCTUnwrap(store.bufferName(for: doc))
        let blocked = store.bufferDirectory.appendingPathComponent(nextName)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data([1]).write(to: blocked.appendingPathComponent("keep-directory-nonempty"))
        XCTAssertThrowsError(try store.saveNow(synchronously: true).get())
        XCTAssertEqual(try Data(contentsOf: store.sessionFile), previousManifest)
        XCTAssertEqual(try String(contentsOf: previousBuffer, encoding: .utf8), "previous backup")

        try FileManager.default.removeItem(at: blocked)
        try store.saveNow(synchronously: true).get()
        XCTAssertEqual(try String(contentsOf: savedBuffer(), encoding: .utf8), "latest unsaved work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousBuffer.path))
    }

    func testManifestFailureDoesNotOverwriteOrDeleteThePreviousBuffer() throws {
        let doc = Document()
        doc.restoreBuffer("recoverable version")
        bind(doc)
        try store.saveNow(synchronously: true).get()
        let previousManifestURL = store.sessionFile
        let previousManifest = try Data(contentsOf: previousManifestURL)
        let previousBuffer = try savedBuffer()

        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocked)
        store.directory = blocked // Keep buffer storage writable but make manifest publication fail.
        doc.restoreBuffer("new version")
        XCTAssertThrowsError(try store.saveNow(synchronously: true).get())
        XCTAssertEqual(try Data(contentsOf: previousManifestURL), previousManifest)
        XCTAssertEqual(try String(contentsOf: previousBuffer, encoding: .utf8), "recoverable version")

        store.directory = directory
        try store.saveNow(synchronously: true).get()
        XCTAssertEqual(try String(contentsOf: savedBuffer(), encoding: .utf8), "new version")
    }

    func testSynchronousExitSaveFollowsQueuedSnapshotsAndKeepsTheLatestText() throws {
        let doc = Document()
        bind(doc)
        doc.restoreBuffer("first")
        store.saveNow(synchronously: false)
        doc.restoreBuffer("second")
        store.saveNow(synchronously: false)
        doc.restoreBuffer("last")
        try store.saveNow(synchronously: true).get()
        XCTAssertEqual(try String(contentsOf: savedBuffer(), encoding: .utf8), "last")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.bufferDirectory.path).count, 1)
    }

    func testSynchronousExitSaveIncludesLargeUnsavedBuffers() throws {
        let doc = Document()
        doc.restoreBuffer(String(repeating: "large buffer\n", count: 334_000))
        bind(doc)
        try store.saveNow(synchronously: true).get()
        XCTAssertEqual(try String(contentsOf: savedBuffer(), encoding: .utf8), doc.string as String)
    }

    func testClosedWindowSnapshotCannotCommitWithAMissingBuffer() throws {
        let doc = Document()
        doc.restoreBuffer("closed-window work")
        bind(doc)
        try store.saveNow(synchronously: true).get()
        let saved = try XCTUnwrap(store.load())
        let manifest = try Data(contentsOf: store.sessionFile)
        try FileManager.default.removeItem(at: savedBuffer())
        store.stateProvider = { saved.windows }
        XCTAssertThrowsError(try store.saveNow(synchronously: true).get())
        XCTAssertEqual(try Data(contentsOf: store.sessionFile), manifest)
    }
}
