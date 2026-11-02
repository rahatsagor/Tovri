import AppKit
import XCTest
@testable import Tovri

final class WindowRegressionTests: XCTestCase {
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

    private func makeFolder(_ files: [String: String] = [:]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-window-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func drain(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func type(_ s: String, in controller: MainWindowController) throws {
        let tv = try XCTUnwrap(controller.activeEditor?.textView)
        tv.insertText(s, replacementRange: tv.selectedRange())
    }

    // MARK: Don't Save

    func testDiscardedEditsDoNotComeBackAfterThePaletteWasUsed() throws {
        let dir = try makeFolder(["a.swift": "func one() {}\nfunc two() {}\n"])
        let url = dir.appendingPathComponent("a.swift")
        try withController { c in
            weak var closed: Document?
            try autoreleasepool {
                let doc = try XCTUnwrap(c.open(url: url))
                closed = doc
                try type("let edit = 1\n", in: c)
                XCTAssertTrue(doc.isDirty)
                c.gotoSymbol(nil)
                c.showSyntaxPicker(nil)
                c.gotoSymbolInProject(nil)
                c.closeTabCommand(nil)
                XCTAssertFalse(c.rootView.subviews.contains { $0 is PaletteBackdrop }, "the palette is still open")
                let g = c.activeGroup
                g.removeTab(at: try XCTUnwrap(g.index(of: doc)))
            }
            drain()
            XCTAssertNil(closed, "a closed palette kept the closed document, and its discarded edits, alive")
            let reopened = try XCTUnwrap(c.open(url: url))
            XCTAssertFalse(reopened.isDirty)
            XCTAssertEqual(reopened.string as String, "func one() {}\nfunc two() {}\n")
        }
    }

    func testDontSaveRevertsADocumentSomethingElseStillHolds() throws {
        let dir = try makeFolder(["a.txt": "on disk\n"])
        let url = dir.appendingPathComponent("a.txt")
        try withController { c in
            let doc = try XCTUnwrap(c.open(url: url))
            try type("unsaved ", in: c)
            XCTAssertTrue(doc.isDirty)
            c.closeTab(in: c.activeGroup, at: 0)
            let sheet = try XCTUnwrap(c.window?.attachedSheet, "no save question was shown")
            c.window?.endSheet(sheet, returnCode: .alertThirdButtonReturn)
            drain()
            XCTAssertTrue(c.activeGroup.tabs.isEmpty)
            XCTAssertFalse(doc.isDirty, "Don’t Save left the edits in a document that can be reopened")
            XCTAssertEqual(doc.string as String, "on disk\n")
            c.reopenClosedTab(nil)
            XCTAssertEqual(c.activeDocument?.string as String?, "on disk\n")
        }
    }

    func testDiscardingAnUntitledDocumentEmptiesIt() {
        _ = NSApplication.shared
        let doc = Document()
        doc.restoreBuffer("draft")
        XCTAssertTrue(doc.isDirty)
        MainWindowController.discardChanges(of: doc)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(doc.length, 0)
    }

    // MARK: Layout

    func testMergingGroupsSelectsATabAndKeepsItsScrollPosition() throws {
        let text = (1...400).map { "line \($0)" }.joined(separator: "\n")
        let dir = try makeFolder(["a.txt": text])
        try withController { c in
            c.window?.setContentSize(NSSize(width: 1000, height: 600))
            _ = c.open(url: dir.appendingPathComponent("a.txt"))
            c.layoutColumns2(nil)
            c.moveTabToNextGroup(nil)
            c.rootView.layoutSubtreeIfNeeded()
            XCTAssertTrue(c.groups[0].tabs.isEmpty)
            let editor = try XCTUnwrap(c.groups[1].activeEditor)
            editor.scrollPosition = CGPoint(x: 0, y: 900)
            let scrolled = editor.scrollPosition
            // The empty left group is active, as after clicking it.
            c.activate(group: c.groups[0])
            c.layoutSingle(nil)
            c.rootView.layoutSubtreeIfNeeded()
            XCTAssertEqual(c.groups.count, 1)
            XCTAssertEqual(c.groups[0].selectedIndex, 0, "tabs shown with no editor")
            let merged = try XCTUnwrap(c.activeEditor)
            XCTAssertEqual(merged.scrollPosition.y, scrolled.y, accuracy: 1)
        }
    }

    // MARK: Sidebar

    func testContextMenuActsOnItsRowNotALaterSelection() throws {
        let dir = try makeFolder(["a.txt": "a", "b.txt": "b"])
        withController { c in
            c.setFolder(dir)
            let sidebar = c.sidebar
            sidebar.outline.reloadData()
            guard let a = sidebar.root?.children?.first(where: { $0.name == "a.txt" }),
                  let b = sidebar.root?.children?.first(where: { $0.name == "b.txt" }) else { return XCTFail("tree not loaded") }
            let menu = sidebar.outline.menuProvider?(sidebar.outline.row(forItem: a))
            XCTAssertTrue(sidebar.selectedNode === a)
            sidebar.outline.selectRowIndexes(IndexSet(integer: sidebar.outline.row(forItem: b)), byExtendingSelection: false)
            XCTAssertTrue(sidebar.selectedNode === b, "⌘⌫ would not act on the selected row")
            let trash = menu?.items.first { $0.title == "Move to Trash" }
            XCTAssertTrue(trash?.representedObject as? FileNode === a)
        }
    }

    func testAFolderOpenedThroughASymlinkUsesItsRealPath() throws {
        let real = try makeFolder(["a.txt": "a"])
        let link = real.deletingLastPathComponent().appendingPathComponent("tovri-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }
        withController { c in
            c.setFolder(URL(fileURLWithPath: link.path))
            XCTAssertEqual(c.folderURL?.path, real.realPathURL.path)
            XCTAssertEqual(c.sidebar.root?.children?.map(\.name), ["a.txt"])
        }
        XCTAssertEqual(ProjectIndex.enumerate(root: link, excludes: [], limit: 100), ["a.txt"])
    }

    func testSymlinkedFoldersExpandButNeverLoop() throws {
        let outside = try makeFolder(["inner.txt": "x"])
        let root = try makeFolder(["file.txt": "y"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let node = FileNode(url: root.realPathURL, isDirectory: true, parent: nil)
        node.loadChildren()
        let linked = try XCTUnwrap(node.children?.first { $0.name == "linked" })
        let loop = try XCTUnwrap(node.children?.first { $0.name == "loop" })
        XCTAssertTrue(linked.isDirectory && linked.isExpandable)
        XCTAssertTrue(loop.isDirectory)
        XCTAssertFalse(loop.isExpandable, "a link to its own parent could be expanded forever")
        linked.loadChildren()
        XCTAssertEqual(linked.children?.map(\.url.path), [root.realPathURL.appendingPathComponent("linked/inner.txt").path])
        XCTAssertEqual(ProjectIndex.enumerate(root: root, excludes: [], limit: 100), ["file.txt"])
    }

    // MARK: History

    func testJumpingBackToAClosedFileKeepsForwardHistory() throws {
        let dir = try makeFolder(["a.txt": "a", "b.txt": "b", "c.txt": "c"])
        let (a, b, cc) = (dir.appendingPathComponent("a.txt"), dir.appendingPathComponent("b.txt"), dir.appendingPathComponent("c.txt"))
        try withController { c in
            weak var first: Document?
            try autoreleasepool {
                first = try XCTUnwrap(c.open(url: a))
                _ = c.open(url: b)
                _ = c.open(url: cc)
                let g = c.activeGroup
                g.removeTab(at: try XCTUnwrap(g.tabs.firstIndex { $0.document.url == a }))
            }
            drain()
            XCTAssertNil(first, "the closed document is still alive, so this doesn't test reopening it")
            c.jumpBack(nil)
            XCTAssertEqual(c.activeDocument?.url?.lastPathComponent, "b.txt")
            c.jumpBack(nil)
            XCTAssertEqual(c.activeDocument?.url?.lastPathComponent, "a.txt")
            c.jumpForward(nil)
            XCTAssertEqual(c.activeDocument?.url?.lastPathComponent, "b.txt")
            c.jumpForward(nil)
            XCTAssertEqual(c.activeDocument?.url?.lastPathComponent, "c.txt")
        }
    }

    // MARK: Palette

    func testOpeningAnotherPaletteEndsAThemePreview() {
        withController { c in
            let tm = ThemeManager.shared
            let other = tm.themes.first { $0 !== tm.current }!
            c.showThemePicker(nil)
            tm.preview(other)
            XCTAssertTrue(tm.active === other)
            c.gotoAnything(nil)
            XCTAssertTrue(tm.active === tm.current, "the previewed theme stayed on")
            c.closeTabCommand(nil)
        }
    }

    // MARK: Closing tabs

    func testCancelStopsCloseAllTabsInEveryGroup() throws {
        let dir = try makeFolder(["a.txt": "a", "b.txt": "b", "c.txt": "c"])
        try withController { c in
            let a = try XCTUnwrap(c.open(url: dir.appendingPathComponent("a.txt")))
            try type("1", in: c)
            c.moveTabToNextGroup(nil)
            c.activate(group: c.groups[0])
            let b = try XCTUnwrap(c.open(url: dir.appendingPathComponent("b.txt")))
            try type("2", in: c)
            // A clean tab in front, so showing the tab that's asked about can be checked.
            _ = c.open(url: dir.appendingPathComponent("c.txt"))
            XCTAssertTrue(a.isDirty && b.isDirty)
            XCTAssertEqual(c.groups.map(\.tabs.count), [2, 1])
            c.closeAllTabs(nil)
            let sheet = try XCTUnwrap(c.window?.attachedSheet)
            XCTAssertTrue(c.activeDocument === b, "the question was asked about a tab in the background")
            c.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            drain()
            XCTAssertNil(c.window?.attachedSheet, "another group asked after Cancel")
            XCTAssertEqual(c.groups.map(\.tabs.count), [2, 1])
            XCTAssertTrue(a.isDirty && b.isDirty)
        }
    }

    func testMenuItemsThatCantDoAnythingAreDisabled() throws {
        let dir = try makeFolder(["a.txt": "a"])
        let url = dir.appendingPathComponent("a.txt")
        try withController { c in
            func enabled(_ action: Selector) -> Bool { c.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }
            XCTAssertFalse(enabled(#selector(MainWindowController.printActiveDocument(_:))))
            XCTAssertFalse(enabled(#selector(MainWindowController.selectNextTabCommand(_:))))
            XCTAssertFalse(enabled(#selector(MainWindowController.jumpBack(_:))))
            XCTAssertFalse(enabled(#selector(MainWindowController.jumpForward(_:))))
            _ = try XCTUnwrap(c.open(url: url))
            XCTAssertTrue(enabled(#selector(MainWindowController.printActiveDocument(_:))))
            XCTAssertFalse(enabled(#selector(MainWindowController.closeTabsToRight(_:))))
            c.closeTabCommand(nil)
            XCTAssertTrue(enabled(#selector(MainWindowController.reopenClosedTab(_:))))
            try FileManager.default.removeItem(at: url)
            XCTAssertFalse(enabled(#selector(MainWindowController.reopenClosedTab(_:))), "nothing left to reopen")
        }
    }

    func testOpeningAFolderLeavesTheSidebarSettingAlone() throws {
        let dir = try makeFolder()
        let d = UserDefaults.standard
        let previous = d.object(forKey: Settings.Key.sidebarVisible)
        defer { d.set(previous, forKey: Settings.Key.sidebarVisible) }
        d.set(false, forKey: Settings.Key.sidebarVisible)
        withController { c in
            c.setFolder(dir)
            XCTAssertFalse(Settings.shared.sidebarVisible)
        }
    }

    // MARK: Tabs

    func testAFastTabDragLandsWhereTheMouseIs() throws {
        let dir = try makeFolder(["a.txt": "a", "b.txt": "b", "c.txt": "c", "d.txt": "d"])
        try withController { c in
            c.window?.setContentSize(NSSize(width: 1200, height: 600))
            for n in ["a", "b", "c", "d"] { _ = c.open(url: dir.appendingPathComponent("\(n).txt")) }
            c.rootView.layoutSubtreeIfNeeded()
            let g = c.activeGroup
            let bar = g.tabBar
            XCTAssertEqual(g.tabs.first?.document.url?.lastPathComponent, "a.txt")
            func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: bar.convert(NSPoint(x: x, y: 20), to: nil), modifierFlags: [], timestamp: 0,
                                   windowNumber: c.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let start = bar.leadingInset + 30
            bar.mouseDown(with: event(.leftMouseDown, start))
            bar.mouseDragged(with: event(.leftMouseDragged, start + 700))
            bar.mouseUp(with: event(.leftMouseUp, start + 700))
            XCTAssertEqual(g.tabs.last?.document.url?.lastPathComponent, "a.txt", "\(g.tabs.map { $0.document.displayName })")
        }
    }

    // MARK: Excludes, search and matching

    func testExcludesWithASlashMatchPaths() throws {
        let list = ExcludeList(["node_modules", "vendor/bundle", "/build"])
        XCTAssertTrue(list.names.contains("node_modules"))
        XCTAssertTrue(list.excludes(relativePath: "vendor/bundle"))
        XCTAssertTrue(list.excludes(relativePath: "vendor/bundle/ruby/x.rb"))
        XCTAssertTrue(list.excludes(relativePath: "app/vendor/bundle/x.rb"))
        XCTAssertFalse(list.excludes(relativePath: "vendor/bundler.rb"))
        XCTAssertFalse(list.excludes(relativePath: "myvendor/bundle/x.rb"))
        XCTAssertTrue(list.excludes(relativePath: "build/out.o"))
        XCTAssertFalse(list.excludes(relativePath: "src/build/out.o"))

        let dir = try makeFolder(["vendor/bundle/a.rb": "needle", "app/vendor/bundle/b.rb": "needle", "vendor/keep.rb": "needle", "bundle/c.rb": "needle"])
        XCTAssertEqual(Set(ProjectIndex.enumerate(root: dir, excludes: ["vendor/bundle"], limit: 100)), ["vendor/keep.rb", "bundle/c.rb"])
    }

    func testFindInFilesStopsAtALimitAndSaysSo() throws {
        let many = String(repeating: "e\n", count: 6000)
        let dir = try makeFolder(["a.txt": many, "b.txt": many, "c.txt": many])
        UserDefaults.standard.set(false, forKey: Settings.Key.gitEnabled)
        defer { UserDefaults.standard.removeObject(forKey: Settings.Key.gitEnabled) }
        let o = FileSearcher.Options(query: "e", regex: false, caseSensitive: false, wholeWord: false, root: dir, include: [], exclude: [])
        let r = try XCTUnwrap(FileSearcher().run(o))
        XCTAssertTrue(r.limited)
        XCTAssertEqual(r.files, 2)
        XCTAssertEqual(r.text.components(separatedBy: ".txt:\n").count - 1, 2)
        XCTAssertTrue(FileSearcher.report(r, for: o, elapsed: 0.1).contains("Showing the first"))
    }

    func testFindInFilesSearchesUnsavedText() throws {
        let dir = try makeFolder(["a.txt": "nothing here\n", "b.txt": "needle on disk\n"])
        UserDefaults.standard.set(false, forKey: Settings.Key.gitEnabled)
        defer { UserDefaults.standard.removeObject(forKey: Settings.Key.gitEnabled) }
        var o = FileSearcher.Options(query: "needle", regex: false, caseSensitive: false, wholeWord: false, root: dir, include: [], exclude: [])
        o.unsaved = ["a.txt": "first\nneedle typed\n", "b.txt": "removed\n"]
        let r = try XCTUnwrap(FileSearcher().run(o))
        XCTAssertEqual(r.files, 1)
        XCTAssertTrue(r.text.contains("a.txt:\n     2: needle typed"), r.text)
        XCTAssertFalse(r.text.contains("b.txt"))
    }

    func testOpeningFindInFilesLeavesTheFindQueryUntilItRuns() throws {
        let dir = try makeFolder(["a.txt": "alpha beta\n"])
        try withController { c in
            _ = try XCTUnwrap(c.open(url: dir.appendingPathComponent("a.txt")))
            let st = FindState.shared
            let previous = st.query
            defer { st.query = previous }
            st.query = "earlier"
            c.activeEditor?.select(NSRange(location: 0, length: 5))
            let panel = FindInFilesPanel(controller: c)
            panel.show(folder: dir)
            XCTAssertEqual(panel.findField.stringValue, "alpha")
            panel.close()
            XCTAssertEqual(st.query, "earlier", "Esc changed the find query")
        }
    }

    func testFuzzyMatchingIgnoresCaseAndAccentsBeyondASCII() {
        XCTAssertEqual(Fuzzy.prepare("AbC d"), Array("abcd".utf16))
        XCTAssertNotNil(Fuzzy.match(Fuzzy.prepare("é"), Array("É.txt".utf16)))
        XCTAssertNotNil(Fuzzy.match(Fuzzy.prepare("ÉTÉ"), Array("été.md".utf16)))
        XCTAssertNotNil(Fuzzy.match(Fuzzy.prepare("cafe"), Array("Café.swift".utf16)))
        XCTAssertNotNil(Fuzzy.match(Fuzzy.prepare("café"), Array("Cafe\u{301}.swift".utf16)), "a decomposed name didn't match")
        XCTAssertNotNil(Fuzzy.match(Fuzzy.prepare("Cafe\u{301}"), Array("café".utf16)), "a decomposed query didn't match")
        XCTAssertNotNil(Fuzzy.match(Fuzzy.prepare("ПРИВЕТ"), Array("привет.txt".utf16)))
        XCTAssertNil(Fuzzy.match(Fuzzy.prepare("x"), Array("é".utf16)))
    }
}
