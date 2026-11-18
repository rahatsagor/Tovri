import AppKit
import XCTest
@testable import Tovri

final class TestIsolationObserver: NSObject, XCTestObservation {
    static let shared = TestIsolationObserver()
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        XCTestObservationCenter.shared.addTestObserver(shared)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        resetSharedTestState()
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        resetSharedTestState()
    }

    private func resetSharedTestState() {
        AppRuntime.defaults.removePersistentDomain(forName: AppRuntime.testSuiteName)
        Settings.shared.reloadFromDefaults()
        KeyBindings.shared.reloadFromDefaults()
        ThemeManager.shared.clearPreviews()
        ThemeManager.shared.reloadCustomThemes()
        RecentFiles.shared.clear()
        EditorTextView.pasteboard = AppRuntime.pasteboard
        MainWindowController.comparisonPasteboard = AppRuntime.pasteboard
        AppRuntime.pasteboard.clearContents()
        AutoSave.shared.save = nil
        AutoSave.shared.delayOverride = nil
        WaitRegistry.shared.releaseAll()
        FindState.shared.query = ""
        FindState.shared.replacement = ""
        FindState.shared.regex = false
        FindState.shared.caseSensitive = false
        FindState.shared.wholeWord = false
    }
}

final class TestIsolationVerificationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestIsolationObserver.install()
    }

    func testTestRuntimeNeverTouchesLiveDefaultsSupportOrGeneralPasteboard() throws {
        TestIsolationObserver.install()
        XCTAssertTrue(AppRuntime.isRunningTests)
        XCTAssertTrue(AppRuntime.defaults !== UserDefaults.standard)
        XCTAssertTrue(AppRuntime.pasteboard !== NSPasteboard.general)
        XCTAssertTrue(AppRuntime.supportDirectory.path.hasPrefix("/tmp/"))
        XCTAssertFalse(SessionStore.shared.directory.path.contains("/Library/Application Support/Tovri"))
        XCTAssertFalse(CustomThemeStore.shared.directory.path.contains("/Library/Application Support/Tovri"))
        XCTAssertFalse(LocalHistory.shared.directory.path.contains("/Library/Application Support/Tovri"))

        let liveSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tovri", isDirectory: true)
        let beforeSessionExists = FileManager.default.fileExists(atPath: liveSupport.appendingPathComponent("Session.json").path)
        let beforeChangeCount = NSPasteboard.general.changeCount
        let liveBundleKey = "testIsolationSentinel-\(UUID().uuidString)"
        XCTAssertNil(UserDefaults.standard.object(forKey: liveBundleKey))

        // Exercise Settings, KeyBindings, RecentFiles, CustomThemeStore, SessionStore, WaitRegistry, and EditorTextView copy.
        AppRuntime.defaults.set("Nord", forKey: Settings.Key.theme)
        AppRuntime.defaults.set(true, forKey: liveBundleKey)
        XCTAssertNil(UserDefaults.standard.object(forKey: liveBundleKey), "AppRuntime.defaults must stay isolated from UserDefaults.standard")

        let doc = Document(text: "copy-secret-line\n", name: "Isolation", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.textView.setAllSelections([NSRange(location: 0, length: 4)], scroll: false)
        editor.textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.changeCount, beforeChangeCount, "NSPasteboard.general must not change during tests")
        XCTAssertEqual(AppRuntime.pasteboard.string(forType: .string), "copy")

        let customTheme = ThemeDefinition(name: "IsolationTestTheme", dark: true, background: "#111111", foreground: "#EEEEEE", accent: "#FF00FF")
        try CustomThemeStore.shared.save(customTheme)
        defer { try? CustomThemeStore.shared.delete(named: customTheme.name) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveSupport.appendingPathComponent("Themes/IsolationTestTheme.json").path))

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-iso-\(UUID().uuidString).txt")
        try "x\n".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        RecentFiles.shared.add(tempFile)
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: "recentItems")?.first(where: { $0 == tempFile.path }),
                     "RecentFiles must not write test files into UserDefaults.standard")

        doc.restoreBuffer("unsaved-isolation-buffer")
        SessionStore.shared.stateProvider = {
            let tab = TabSession(path: nil, untitledName: doc.displayName, buffer: SessionStore.shared.bufferName(for: doc),
                                 selection: 0, selectionLength: 0, scrollX: 0, scrollY: 0,
                                 language: nil, encoding: doc.encoding.rawValue, lineEnding: doc.lineEnding.rawValue)
            return [WindowSession(frame: "", folder: nil, sidebarVisible: false, sidebarWidth: 240,
                                  layout: "single", groups: [GroupSession(tabs: [tab], selected: 0)],
                                  activeGroup: 0, fullScreen: false)]
        }
        defer { SessionStore.shared.stateProvider = nil }
        try SessionStore.shared.saveNow(synchronously: true).get()
        if !beforeSessionExists {
            XCTAssertFalse(FileManager.default.fileExists(atPath: liveSupport.appendingPathComponent("Session.json").path))
        }
        let waitID = UUID().uuidString
        WaitRegistry.shared.register(waitID, for: doc)
        WaitRegistry.shared.release(waitID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveSupport.appendingPathComponent("Wait/\(waitID)").path))
    }
}
