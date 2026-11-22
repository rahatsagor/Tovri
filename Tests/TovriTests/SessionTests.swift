import AppKit
import XCTest
@testable import Tovri

final class SessionTests: XCTestCase {
    func testQuitAsksOnceForADirtyDocumentSharedByTwoWindows() {
        withController { first in
            withController { second in
                let shared = Document()
                shared.restoreBuffer("unsaved changes")
                first.activeGroup.add(shared)
                second.activeGroup.add(shared)
                let clean = Document()
                second.activeGroup.add(clean)

                let targets = AppDelegate.quitConfirmationTargets(in: [first, second])
                XCTAssertEqual(shared.editorCount, 2)
                XCTAssertEqual(targets.count, 1)
                XCTAssertTrue(targets.first?.document === shared)
                XCTAssertTrue(targets.first?.controller === first)

                var otherWindowKeepsEdits = false
                first.confirmCloseAll { otherWindowKeepsEdits = $0 }
                XCTAssertTrue(otherWindowKeepsEdits, "Closing only one window should keep using the shared buffer")
            }
        }
    }

    private func withController(_ body: (MainWindowController) throws -> Void) rethrows {
        _ = NSApplication.shared
        let controller = MainWindowController()
        defer {
            controller.teardown()
            controller.window?.delegate = nil
            controller.window?.close()
        }
        try body(controller)
    }

    private func closedWindow(folder: String?, buffer: String?) -> WindowSession {
        let tab = TabSession(path: "/tmp/a.txt", untitledName: nil, buffer: buffer, selection: 0, selectionLength: 0,
                             scrollX: 0, scrollY: 0, language: nil, encoding: nil, lineEnding: nil)
        return WindowSession(frame: "", folder: folder, sidebarVisible: true, sidebarWidth: 240, layout: "single",
                             groups: [GroupSession(tabs: [tab], selected: 0)], activeGroup: 0, fullScreen: false)
    }

    func testClosedWindowsWithUnsavedChangesAreNeverForgotten() {
        let clean = closedWindow(folder: "/tmp/clean", buffer: nil)
        let unsaved = closedWindow(folder: "/tmp/unsaved", buffer: "buffer-1")
        let later = closedWindow(folder: "/tmp/later", buffer: nil)
        XCTAssertFalse(clean.hasUnsavedChanges)
        XCTAssertTrue(unsaved.hasUnsavedChanges)

        // Closing another window, even an empty one, keeps the closed window's unsaved buffers.
        var closed = AppDelegate.remembering([], closing: unsaved)
        closed = AppDelegate.remembering(closed, closing: clean)
        closed = AppDelegate.remembering(closed, closing: later)
        XCTAssertEqual(closed.map(\.folder), ["/tmp/unsaved", "/tmp/later"])

        let open = closedWindow(folder: nil, buffer: nil)
        XCTAssertTrue(AppDelegate.sessionWindows(open: [], closed: []).isEmpty)
        XCTAssertEqual(AppDelegate.sessionWindows(open: [], closed: closed).map(\.folder), ["/tmp/unsaved", "/tmp/later"])
        XCTAssertEqual(AppDelegate.sessionWindows(open: [open], closed: [clean]).map(\.folder), [nil])
        XCTAssertEqual(AppDelegate.sessionWindows(open: [open], closed: closed).map(\.folder), [nil, "/tmp/unsaved"])
    }

    func testLaunchingToOpenAFileSkipsAWindowClosedBeforeQuitting() {
        var closedClean = closedWindow(folder: "/tmp/project", buffer: nil)
        closedClean.closed = true
        var closedUnsaved = closedWindow(folder: "/tmp/project", buffer: "buffer-1")
        closedUnsaved.closed = true
        let open = closedWindow(folder: "/tmp/project", buffer: nil)
        XCTAssertTrue(AppDelegate.skipsAtLaunch(closedClean, openingFiles: true))
        XCTAssertFalse(AppDelegate.skipsAtLaunch(closedClean, openingFiles: false))
        XCTAssertFalse(AppDelegate.skipsAtLaunch(closedUnsaved, openingFiles: true))
        XCTAssertFalse(AppDelegate.skipsAtLaunch(open, openingFiles: true))

        let decoded = try? JSONDecoder().decode(WindowSession.self, from: JSONEncoder().encode(closedClean))
        XCTAssertEqual(decoded?.closed, true)
        let old = Data(#"{"frame":"","sidebarVisible":true,"sidebarWidth":240,"layout":"single","groups":[],"activeGroup":0,"fullScreen":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WindowSession.self, from: old).closed, "0.2.0 sessions still load")
    }

    func testSessionKeepsSelectedTabAfterOmittingEmptyUntitledTabs() {
        withController { controller in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let group = controller.activeGroup
            group.add(Document())
            group.add(Document(newFileAt: root.appendingPathComponent("first.txt")))
            group.add(Document(newFileAt: root.appendingPathComponent("second.txt")), select: false)
            let state = controller.sessionState()
            XCTAssertEqual(state.groups[0].tabs.count, 2)
            XCTAssertEqual(state.groups[0].selected, 0)
            XCTAssertEqual(state.groups[0].tabs[0].path, root.appendingPathComponent("first.txt").path)
        }
    }

    func testUnopenedTabKeepsItsPendingSelectionLength() {
        withController { controller in
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            let tab = controller.activeGroup.add(Document(newFileAt: path), select: false)
            tab.pendingSelection = NSRange(location: 4, length: 7)
            let state = controller.sessionState().groups[0].tabs[0]
            XCTAssertEqual(state.selection, 4)
            XCTAssertEqual(state.selectionLength, 7)
        }
    }

    func testSessionRestoresNewFilePathAndChosenEncoding() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift")
        var tab = TabSession(path: path.path, untitledName: nil, buffer: nil, selection: 0, selectionLength: 0,
                             scrollX: 0, scrollY: 500, language: nil, encoding: TextEncoding.utf16LE.rawValue,
                             lineEnding: LineEnding.crlf.rawValue)
        tab.isNewFile = true
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(TabSession.self, from: data)
        withController { controller in
            let window = WindowSession(frame: "", folder: nil, sidebarVisible: true, sidebarWidth: 240,
                                       layout: "single", groups: [GroupSession(tabs: [decoded], selected: 0)],
                                       activeGroup: 0, fullScreen: false)
            controller.restore(window)
            controller.rootView.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.activeDocument?.url, path)
            XCTAssertEqual(controller.activeDocument?.isNewFile, true)
            XCTAssertEqual(controller.activeDocument?.encoding, .utf16LE)
            XCTAssertEqual(controller.activeDocument?.lineEnding, .crlf)
            XCTAssertEqual(controller.activeEditor?.scrollPosition.y, 0)
        }
    }

    // MARK: Reopen Closed Window

    /// Without unsaved buffers a closed window is remembered by the files it showed: untitled and
    /// not-yet-saved tabs are left out, and no hot-exit buffer is written for a dirty file.
    func testSessionWithoutUnsavedKeepsOnlyRealFiles() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "on disk\n".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try withController { controller in
            let fileDoc = try XCTUnwrap(controller.open(url: fileURL))
            fileDoc.textStorage.replaceCharacters(in: NSRange(location: fileDoc.length, length: 0), with: "edit\n")
            let untitled = Document()
            untitled.restoreBuffer("unsaved text\n")
            controller.activeGroup.add(untitled)
            _ = controller.openNewFile(at: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift"))

            let state = controller.sessionState(includeUnsaved: false)
            let tabs = state.groups.flatMap(\.tabs)
            XCTAssertEqual(tabs.count, 1)
            XCTAssertEqual(tabs[0].path, fileURL.path)
            XCTAssertNil(tabs[0].buffer)
        }
    }

    /// Makes `NSApp.delegate` a fresh AppDelegate, the way SessionExitTests does, and closes every
    /// window it opened afterwards.
    private func withAppDelegate(_ body: (AppDelegate) throws -> Void) throws {
        let application = NSApplication.shared
        let oldDelegate = application.delegate
        let app = AppDelegate()
        application.delegate = app
        defer {
            for controller in app.controllers {
                if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
                for group in controller.groups { for tab in group.tabs { tab.close() } }
                controller.teardown()
                controller.window?.delegate = nil
                controller.window?.close()
            }
            application.delegate = oldDelegate
        }
        try body(app)
    }

    /// Closing one of several windows records it even with hot exit off, so Reopen Closed Window
    /// brings back the files it showed.
    func testClosingOneOfTwoWindowsRecordsItForReopen() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "contents\n".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try withAppDelegate { app in
            let d = AppRuntime.defaults
            let oldHotExit = d.object(forKey: Settings.Key.hotExit)
            d.set(false, forKey: Settings.Key.hotExit)
            Settings.shared.reloadFromDefaults()
            defer {
                if let oldHotExit { d.set(oldHotExit, forKey: Settings.Key.hotExit) } else { d.removeObject(forKey: Settings.Key.hotExit) }
                Settings.shared.reloadFromDefaults()
            }
            let first = app.newWindow()
            _ = first.open(url: fileURL)
            _ = app.newWindow()

            XCTAssertTrue(first.windowShouldClose(try XCTUnwrap(first.window)))
            XCTAssertTrue(app.canReopenClosedWindow)
            first.window?.close()

            let reopened = try XCTUnwrap(app.reopenClosedWindow(nil))
            XCTAssertEqual(reopened.activeDocument?.url, fileURL)
        }
    }

    /// A window with nothing but an empty untitled tab has nothing worth reopening.
    func testClosingAnEmptyWindowRecordsNothing() throws {
        try withAppDelegate { app in
            let d = AppRuntime.defaults
            let oldHotExit = d.object(forKey: Settings.Key.hotExit)
            d.set(false, forKey: Settings.Key.hotExit)
            Settings.shared.reloadFromDefaults()
            defer {
                if let oldHotExit { d.set(oldHotExit, forKey: Settings.Key.hotExit) } else { d.removeObject(forKey: Settings.Key.hotExit) }
                Settings.shared.reloadFromDefaults()
            }
            let controller = app.newWindow()
            XCTAssertTrue(controller.isEmptyWindow)
            XCTAssertTrue(controller.windowShouldClose(try XCTUnwrap(controller.window)))
            XCTAssertFalse(app.canReopenClosedWindow)
            controller.window?.close()
        }
    }

    /// A pending Save with Encoding describes the next write, not the bytes on disk: neither the
    /// retained document's reload nor the closed window's snapshot may decode with it.
    func testReopenClosedWindowIgnoresDiscardedSaveEncoding() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let text = "caf\u{00E9}\n"
        try Data(text.utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try withAppDelegate { app in
            _ = app.newWindow() // Another window prevents hot exit from skipping the prompt.
            try autoreleasepool {
                let first = app.newWindow()
                let doc = try XCTUnwrap(first.open(url: fileURL))
                XCTAssertTrue(doc.encodingWasDetected)
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.representedObject = TextEncoding.windows1252.rawValue
                first.setEncoding(item)
                XCTAssertTrue(doc.isDirty)
                let window = try XCTUnwrap(first.window)
                XCTAssertFalse(first.windowShouldClose(window))
                window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertThirdButtonReturn)
                let deadline = Date().addingTimeInterval(3)
                while (app.controllers.contains { $0 === first } || doc.isDirty) && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                XCTAssertTrue(app.canReopenClosedWindow)
                XCTAssertFalse(doc.isDirty)
                XCTAssertEqual(doc.string as String, text)
                XCTAssertTrue(doc.encodingWasDetected)
            }
            let deadline = Date().addingTimeInterval(3)
            while DocumentRegistry.shared.existing(for: fileURL) != nil && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertNil(DocumentRegistry.shared.existing(for: fileURL), "Reopen must read from the closed window snapshot")
            let reopened = try XCTUnwrap(app.reopenClosedWindow(nil))
            let doc = try XCTUnwrap(reopened.activeDocument)
            XCTAssertEqual(doc.string as String, text)
            XCTAssertEqual(doc.encoding, .utf8)
            XCTAssertTrue(doc.encodingWasDetected)
            XCTAssertFalse(doc.isDirty)
            XCTAssertEqual(try Data(contentsOf: fileURL), Data(text.utf8))
        }
    }
}
