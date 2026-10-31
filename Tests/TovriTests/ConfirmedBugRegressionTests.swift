import AppKit
import XCTest
@testable import Tovri

final class ConfirmedBugRegressionTests: XCTestCase {
    func testSidebarNewFileCreationIsExclusiveAndCreatesNestedDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let existingURL = directory.appendingPathComponent("already-there.txt")
        let originalBytes = Data([0x00, 0xff, 0x0d, 0x0a, 0x41])
        try originalBytes.write(to: existingURL)
        XCTAssertThrowsError(try SidebarView.createNewFile(at: existingURL))
        XCTAssertEqual(try Data(contentsOf: existingURL), originalBytes)

        let nestedURL = directory.appendingPathComponent("one/two/created.txt")
        try SidebarView.createNewFile(at: nestedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
        XCTAssertEqual(try Data(contentsOf: nestedURL), Data())
    }

    func testSaveAsRemovesOldRegistryPathAndKeepsOriginalFileOpenable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("original.txt")
        let newURL = directory.appendingPathComponent("renamed.txt")
        try Data("original contents\n".utf8).write(to: oldURL)

        let registry = DocumentRegistry.shared
        let renamed = try registry.open(oldURL)
        registry.register(renamed) // Match the UI path that registers opened documents.
        renamed.textStorage.replaceCharacters(in: NSRange(location: 0, length: renamed.length), with: "renamed contents\n")
        try renamed.save(to: newURL)

        let reopenedOriginal = try registry.open(oldURL)
        let reopenedRenamed = try registry.open(newURL)
        XCTAssertFalse(reopenedOriginal === renamed)
        XCTAssertTrue(reopenedRenamed === renamed)
        XCTAssertEqual(reopenedOriginal.string as String, "original contents\n")
        XCTAssertEqual(reopenedRenamed.string as String, "renamed contents\n")
        XCTAssertEqual(try String(contentsOf: oldURL, encoding: .utf8), "original contents\n")
    }

    func testRestoreUsesSavedShiftJISEncodingToDecodeFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try withIsolatedSessionStore(directory: directory) {
            let url = directory.appendingPathComponent("japanese.txt")
            let expected = "こんにちは世界\n"
            try XCTUnwrap(TextEncoding.shiftJIS.encode(expected)).write(to: url)
            let savedTab = TabSession(path: url.path, untitledName: nil, buffer: nil,
                                      selection: 0, selectionLength: 0, scrollX: 0, scrollY: 0,
                                      language: nil, encoding: TextEncoding.shiftJIS.rawValue,
                                      lineEnding: LineEnding.lf.rawValue)
            let session = WindowSession(frame: "", folder: nil, sidebarVisible: true,
                                        sidebarWidth: 240, layout: "single",
                                        groups: [GroupSession(tabs: [savedTab], selected: 0)],
                                        activeGroup: 0, fullScreen: false)
            withController { controller in
                controller.restore(session)
                XCTAssertEqual(controller.activeDocument?.encoding, .shiftJIS)
                XCTAssertEqual(controller.activeDocument?.string as String?, expected)
            }
        }
    }

    func testOpenTextNormalizesWindowsAndClassicEndingsAndSavesSingleCRs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, source, expectedInternal, ending, expectedSaved) in [
            ("windows.txt", "first\r\nsecond\r\n", "first\nsecond\n", LineEnding.crlf, "first\r\nsecond\r\n"),
            ("classic.txt", "first\rsecond\r", "first\nsecond\n", LineEnding.cr, "first\rsecond\r"),
        ] {
            try withController { controller in
                let doc = controller.openText(source)
                XCTAssertEqual(doc.string as String, expectedInternal)
                XCTAssertEqual(doc.lineEnding, ending)
                XCTAssertTrue(doc.isDirty)
                try doc.save(to: directory.appendingPathComponent(name))
            }
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8), expectedSaved)
        }
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

    private func withIsolatedSessionStore<T>(directory: URL, _ body: () throws -> T) rethrows -> T {
        let store = SessionStore.shared
        let oldDirectory = store.directory
        let oldBufferDirectory = store.bufferDirectory
        let oldProvider = store.stateProvider
        store.directory = directory
        store.bufferDirectory = directory.appendingPathComponent("Buffers", isDirectory: true)
        try? FileManager.default.createDirectory(at: store.bufferDirectory, withIntermediateDirectories: true)
        store.stateProvider = nil
        defer {
            store.directory = oldDirectory
            store.bufferDirectory = oldBufferDirectory
            store.stateProvider = oldProvider
        }
        return try body()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("TovriRegression-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
