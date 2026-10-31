import AppKit
import XCTest
@testable import Tovri

final class SessionExitTests: XCTestCase {
    private func withBlockedSession(_ body: (AppDelegate, MainWindowController, URL) throws -> Void) throws {
        let application = NSApplication.shared
        let store = SessionStore.shared
        let oldDelegate = application.delegate
        let oldDirectory = store.directory
        let oldBuffers = store.bufferDirectory
        let oldProvider = store.stateProvider
        let defaults = UserDefaults.standard
        let oldArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("TovriExit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var arguments = oldArguments
        arguments[Settings.Key.hotExit] = true
        arguments[Settings.Key.restoreSession] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        store.directory = directory
        store.bufferDirectory = directory.appendingPathComponent("BlockedBuffers")
        try Data([1]).write(to: store.bufferDirectory)

        let app = AppDelegate()
        application.delegate = app
        let controller = app.newWindow()
        controller.window?.orderOut(nil)
        controller.activeDocument?.restoreBuffer("unsaved exit regression fixture")
        store.stateProvider = { [weak controller] in controller.map { [$0.sessionState()] } ?? [] }
        defer {
            if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
            // Drain queued writes before removing the fixture or restoring the shared store.
            _ = store.saveNow(synchronously: true)
            controller.teardown()
            controller.window?.delegate = nil
            controller.window?.close()
            application.delegate = oldDelegate
            store.directory = oldDirectory
            store.bufferDirectory = oldBuffers
            store.stateProvider = oldProvider
            defaults.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(app, controller, store.bufferDirectory)
    }

    func testHotExitCancelsTerminationWhenTheBackupFails() throws {
        try withBlockedSession { app, controller, blocked in
            XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
            XCTAssertFalse(app.isTerminating)
            XCTAssertEqual(controller.activeDocument?.string as String?, "unsaved exit regression fixture")
            XCTAssertTrue(controller.activeDocument?.isDirty == true)
            if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }

            try FileManager.default.removeItem(at: blocked)
            XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateNow)
            XCTAssertTrue(app.isTerminating)
        }
    }

    func testLastWindowStaysOpenUntilItsBackupSucceeds() throws {
        try withBlockedSession { app, controller, blocked in
            let window = try XCTUnwrap(controller.window)
            XCTAssertTrue(app.closingKeepsUnsavedChanges(controller))
            XCTAssertFalse(controller.windowShouldClose(window))
            XCTAssertEqual(controller.activeDocument?.editorCount, 1)
            if let sheet = window.attachedSheet { window.endSheet(sheet) }

            try FileManager.default.removeItem(at: blocked)
            XCTAssertTrue(controller.windowShouldClose(window))
            let tab = try XCTUnwrap(SessionStore.shared.load()?.windows.first?.groups.first?.tabs.first)
            let name = try XCTUnwrap(tab.buffer)
            let file = SessionStore.shared.bufferDirectory.appendingPathComponent(name)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unsaved exit regression fixture")
        }
    }
}
