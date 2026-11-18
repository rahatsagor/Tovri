import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Tovri

final class DeepAuditRegressionTests: XCTestCase {
    private func makeTempDir(_ prefix: String = "tovri-audit-") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
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

    func testMovingTabAcrossSplitsAndCollapsingPreservesLiveEditorAndUndo() throws {
        let dir = try makeTempDir("tovri-splits-")
        let url = dir.appendingPathComponent("note.txt")
        try "hello world\nsecond line\n".write(to: url, atomically: true, encoding: .utf8)

        try withController { controller in
            let doc = try XCTUnwrap(controller.open(url: url))
            let originalEditor = try XCTUnwrap(controller.activeEditor)
            originalEditor.textView.setSelectedRange(NSRange(location: 5, length: 0))
            originalEditor.textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
            XCTAssertTrue(doc.undoManager.canUndo)
            XCTAssertEqual(doc.editorCount, 1)

            controller.moveTabToNextGroup(nil)
            XCTAssertEqual(controller.groups.count, 2)
            XCTAssertTrue(controller.activeEditor === originalEditor, "Moving a tab between splits must keep the live EditorView")
            XCTAssertEqual(doc.editorCount, 1)
            XCTAssertEqual(originalEditor.textView.selectedRange(), NSRange(location: 6, length: 0))
            XCTAssertTrue(doc.undoManager.canUndo)

            controller.layoutSingle(nil)
            XCTAssertEqual(controller.groups.count, 1)
            XCTAssertTrue(controller.activeEditor === originalEditor, "Collapsing a split layout must keep the live EditorView")
            XCTAssertEqual(doc.editorCount, 1)

            // Duplicating the same document into a split and collapsing must close the duplicate tab cleanly.
            controller.splitTabRight(nil)
            XCTAssertEqual(controller.groups.count, 2)
            XCTAssertEqual(doc.editorCount, 2)
            controller.layoutSingle(nil)
            XCTAssertEqual(doc.editorCount, 1)

            doc.undoManager.undo()
            XCTAssertEqual(doc.string as String, "hello world\nsecond line\n")
        }
    }

    func testClosingOneWindowSkipsPromptWhenDirtyDocumentIsLazyInAnotherWindow() throws {
        let dir = try makeTempDir("tovri-shared-win-")
        let url = dir.appendingPathComponent("shared.txt")
        let otherURL = dir.appendingPathComponent("other.txt")
        try "initial\n".write(to: url, atomically: true, encoding: .utf8)
        try "other\n".write(to: otherURL, atomically: true, encoding: .utf8)

        _ = NSApplication.shared
        let previousDelegate = NSApp.delegate
        let app = AppDelegate()
        NSApp.delegate = app
        defer {
            for c in app.controllers {
                c.teardown()
                c.window?.delegate = nil
                c.window?.close()
            }
            NSApp.delegate = previousDelegate
        }

        let w1 = app.newWindow()
        let shared = try XCTUnwrap(w1.open(url: url))

        // Open `other.txt` first in w2 so `shared` sits in an unselected lazy tab (`tab.editor == nil`).
        let w2 = app.newWindow()
        _ = try XCTUnwrap(w2.open(url: otherURL))
        w2.activeGroup.add(shared, select: false)
        XCTAssertNil(w2.activeGroup.tabs.last?.editor)

        w1.activeEditor?.textView.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(shared.isDirty)
        XCTAssertTrue(w1.dirtyDocumentsNeedingCloseConfirmation.isEmpty)
        XCTAssertTrue(w1.windowShouldClose(try XCTUnwrap(w1.window)))
        XCTAssertTrue(shared.isDirty, "Unsaved edits must remain intact while another window holds the document")
    }

    func testFileSearcherPatternsBraceDirectoryGlobsAndSymlinkDeduplication() throws {
        XCTAssertEqual(
            FileSearcher.patterns("My Dir/*.md, *.{ts,tsx}, ./src/*"),
            ["My Dir/*.md", "*.ts", "*.tsx", "src/*"]
        )
        XCTAssertEqual(
            FileSearcher.patterns("*.swift   tests/*.swift"),
            ["*.swift", "tests/*.swift"]
        )

        UserDefaults.standard.set(false, forKey: Settings.Key.gitEnabled)
        defer { UserDefaults.standard.removeObject(forKey: Settings.Key.gitEnabled) }

        let dir = try makeTempDir("tovri-search-patterns-")
        let logs = dir.appendingPathComponent("logs")
        let nestedLogs = dir.appendingPathComponent("sub/logs")
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

        let target = src.appendingPathComponent("main.ts")
        try "const needle = 1\n".write(to: target, atomically: true, encoding: .utf8)
        try "const needle = 2\n".write(to: logs.appendingPathComponent("run.ts"), atomically: true, encoding: .utf8)
        try "const needle = 3\n".write(to: nestedLogs.appendingPathComponent("inner.ts"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("alias.ts"), withDestinationURL: target)

        let options = FileSearcher.Options(
            query: "needle",
            regex: false,
            caseSensitive: false,
            wholeWord: false,
            root: dir,
            include: FileSearcher.patterns("src/*.{ts,tsx}"),
            exclude: FileSearcher.patterns("logs/")
        )
        let result = try XCTUnwrap(FileSearcher().run(options))
        XCTAssertEqual(result.files, 1, "Symlink to the same file should be reported only once")
        XCTAssertEqual(result.matches, 1)
    }

    func testReplaceInFilesNormalizesCarriageReturnsForDocumentsAndCRLFOnDisk() throws {
        UserDefaults.standard.set(false, forKey: Settings.Key.gitEnabled)
        defer { UserDefaults.standard.removeObject(forKey: Settings.Key.gitEnabled) }

        let dir = try makeTempDir("tovri-replace-crlf-")
        let diskFile = dir.appendingPathComponent("disk.txt")
        let openFile = dir.appendingPathComponent("open.txt")
        try Data("alpha one\r\n".utf8).write(to: diskFile)
        try Data("alpha two\n".utf8).write(to: openFile)

        let doc = try DocumentRegistry.shared.open(openFile)
        let options = FileSearcher.Options(query: "alpha", regex: false, caseSensitive: false, wholeWord: false, root: dir, include: [], exclude: [])
        let openInputs = ReplaceInFiles.openFiles(under: dir, in: [doc])
        let plan = try XCTUnwrap(ReplaceInFiles.plan(options, replacement: "beta\r\ngamma", open: openInputs))

        let batch = ReplaceBatch()
        _ = ReplaceInFiles.applyInEditors(plan, batch: batch)
        _ = ReplaceInFiles.applyOnDisk(plan, batch: batch)

        XCTAssertEqual(doc.string as String, "beta\ngamma two\n", "Open Document buffers must stay LF-normalized")
        XCTAssertFalse((doc.string as String).contains("\r"))

        let diskBytes = try Data(contentsOf: diskFile)
        XCTAssertEqual(String(decoding: diskBytes, as: UTF8.self), "beta\r\ngamma one\r\n")
    }

    func testSidebarRejectsTraversalNamesAndDetectsAncestorSymlinkLoops() throws {
        XCTAssertFalse(SidebarView.isValidEntryName(""))
        XCTAssertFalse(SidebarView.isValidEntryName("."))
        XCTAssertFalse(SidebarView.isValidEntryName(".."))
        XCTAssertFalse(SidebarView.isValidEntryName("sub/file.txt"))
        XCTAssertFalse(SidebarView.isValidEntryName("../escape.txt"))
        XCTAssertFalse(SidebarView.isValidEntryName("bad\0name"))
        XCTAssertTrue(SidebarView.isValidEntryName("valid.swift"))

        let dir = try makeTempDir("tovri-loop-")
        let nested = dir.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("cycle"), withDestinationURL: dir)

        let root = FileNode(url: dir, isDirectory: true, parent: nil)
        root.loadChildren()
        let a = try XCTUnwrap(root.children?.first { $0.name == "a" })
        a.loadChildren()
        let b = try XCTUnwrap(a.children?.first { $0.name == "b" })
        b.loadChildren()
        let cycle = try XCTUnwrap(b.children?.first { $0.name == "cycle" })

        XCTAssertTrue(cycle.isLink)
        XCTAssertTrue(cycle.isLoop)
        XCTAssertFalse(cycle.isExpandable)
    }

    func testDefaultEditorContentTypesExcludeMediaStreamsAndHonorSourceUTIs() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL) as? [String: Any])
        let types = Integration.defaultEditorContentTypes(from: plist)

        XCTAssertFalse(types.contains { $0.identifier == "public.mpeg-2-transport-stream" })
        XCTAssertFalse(types.contains { $0.conforms(to: .audiovisualContent) || $0.conforms(to: .image) || $0.conforms(to: .pdf) || $0.conforms(to: .archive) })
        if UTType("app.tovri.typescript") != nil {
            XCTAssertTrue(types.contains { $0.identifier == "app.tovri.typescript" })
        }
    }

    func testKeyBindingsUseStableIdentifierAcrossDynamicMenuTitleChanges() throws {
        _ = NSApplication.shared
        let recent = NSMenu(title: "Open Recent")
        let menu = MainMenu.build(recentMenu: recent)
        let saved = UserDefaults.standard.dictionary(forKey: KeyBindings.storeKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: KeyBindings.storeKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyBindings.storeKey) }
            if let main = NSApp.mainMenu {
                KeyBindings.shared.install(on: main)
                KeyBindings.shared.reloadFromDefaults()
            }
        }

        KeyBindings.shared.install(on: menu)
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)

        // 1. Dynamic title changes (e.g. Enter/Exit Full Screen) preserve overrides under View/Enter Full Screen.
        let fullScreenItem = try XCTUnwrap(viewMenu.items.first { $0.action == #selector(NSWindow.toggleFullScreen(_:)) })
        let customFullScreen = KeyShortcut(key: "u", modifiers: [.command, .control])
        KeyBindings.shared.set(customFullScreen, for: "View/Enter Full Screen")
        fullScreenItem.title = "Exit Full Screen"
        KeyBindings.shared.reloadFromDefaults()
        XCTAssertEqual(fullScreenItem.keyEquivalent, "u")
        XCTAssertEqual(fullScreenItem.keyEquivalentModifierMask, [.command, .control])
        KeyBindings.shared.reset("View/Enter Full Screen")

        // 2. Shared-selector items (e.g. Tab 1 vs Tab 2) retain unique command IDs.
        let tabIDs = KeyBindings.shared.commands.filter { $0.path == "Goto › Select Tab" }.map(\.id)
        XCTAssertEqual(Set(tabIDs).count, tabIDs.count)
        XCTAssertTrue(tabIDs.contains("Goto › Select Tab/Tab 1"))
    }

    func testPaletteQueryParsingNFCIndexMatchingAndPreviewRestore() throws {
        let q1 = PaletteController.parseFileQuery("Sources/App/Main.swift:42:7")
        XCTAssertEqual(q1.query, "Sources/App/Main.swift")
        XCTAssertEqual(q1.line, 42)
        XCTAssertEqual(q1.column, 7)
        XCTAssertNil(q1.symbol)

        let q2 = PaletteController.parseFileQuery("Main.swift:15:")
        XCTAssertEqual(q2.query, "Main.swift")
        XCTAssertEqual(q2.line, 15)
        XCTAssertNil(q2.column)

        let q3 = PaletteController.parseFileQuery("Main.swift@setup")
        XCTAssertEqual(q3.query, "Main.swift")
        XCTAssertEqual(q3.symbol, "setup")

        // NFD filename must match NFC accented search queries.
        let dir = try makeTempDir("tovri-nfc-")
        try "x\n".write(to: dir.appendingPathComponent("Cafe\u{0301}.swift"), atomically: true, encoding: .utf8)
        let index = ProjectIndex(root: dir)
        let deadline = Date().addingTimeInterval(5)
        while index.isBuilding && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(index.isBuilding)
        let entry = try XCTUnwrap(index.entries.first)
        XCTAssertNotNil(Fuzzy.match(Fuzzy.prepare("é"), entry.units, basenameStart: entry.basenameStart))
        XCTAssertNotNil(Fuzzy.match(Fuzzy.prepare("café"), entry.units, basenameStart: entry.basenameStart))

        // Leaving :line preview mode back to file filtering must restore the original selection.
        let sample = dir.appendingPathComponent("sample.txt")
        try "line 1\nline 2\nline 3\nline 4\n".write(to: sample, atomically: true, encoding: .utf8)
        try withController { controller in
            _ = try XCTUnwrap(controller.open(url: sample))
            let tv = try XCTUnwrap(controller.activeEditor?.textView)
            let initialSelection = NSRange(location: 2, length: 0)
            tv.setAllSelections([initialSelection], scroll: false)

            controller.palette.show(mode: .files)
            controller.palette.field.stringValue = ":3"
            controller.palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            XCTAssertNotEqual(tv.selectedRange(), initialSelection)

            controller.palette.field.stringValue = "sample"
            controller.palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            XCTAssertEqual(tv.selectedRange(), initialSelection)
            controller.palette.close(cancelled: true)
        }
    }

    func testCLIGotoFlagParsesMissingPathLineAndColumn() throws {
        let binDir = try makeTempDir("tovri-cli-mock-")
        let captured = binDir.appendingPathComponent("captured.txt")
        let openMock = binDir.appendingPathComponent("open")
        let script = """
        #!/bin/sh
        for arg in "$@"; do
          case "$arg" in
            tovri://open\\?req=*)
              hex="${arg#tovri://open?req=}"
              req=$(printf '%s' "$hex" | xxd -r -p)
              if [ -f "$req" ]; then
                cat "$req" > "$TEST_CAPTURED_REQ"
                rm -f "$req"
              fi
              ;;
          esac
        done
        """
        try script.write(to: openMock, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openMock.path)

        let cli = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/tovri")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [cli.path, "-g", "future_file.swift:42:7"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = binDir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["TEST_CAPTURED_REQ"] = captured.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()

        XCTAssertEqual(p.terminationStatus, 0)
        let query = try String(contentsOf: captured, encoding: .utf8)
        XCTAssertTrue(query.contains("&line=42"), query)
        XCTAssertTrue(query.contains("&col=7"), query)
    }
}
