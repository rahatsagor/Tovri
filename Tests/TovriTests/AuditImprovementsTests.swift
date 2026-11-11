import AppKit
import WebKit
import XCTest
@testable import Tovri

final class AuditImprovementsTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tovri-audit-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

    // MARK: - 1. Large-file hot-exit throttling

    func testLargeBufferAsyncSessionSavesKeepPreviousBackupDuringThrottleWindow() throws {
        _ = NSApplication.shared
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore()
        store.directory = dir
        store.bufferDirectory = dir.appendingPathComponent("Buffers")
        defer { store.stateProvider = nil }

        let oldArgs = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var args = oldArgs
        args[Settings.Key.hotExit] = true
        args[Settings.Key.restoreSession] = true
        UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(oldArgs, forName: UserDefaults.argumentDomain) }

        let initial = String(repeating: "0123456789abcdef\n", count: 250_000) // ~4.25M UTF-16 units
        let doc = Document()
        doc.restoreBuffer(initial)

        store.stateProvider = { [weak store] in
            let buf = store?.bufferName(for: doc)
            var tab = TabSession(path: nil, untitledName: doc.displayName, buffer: buf,
                                 selection: 0, selectionLength: 0, scrollX: 0, scrollY: 0,
                                 language: nil, encoding: doc.encoding.rawValue, lineEnding: doc.lineEnding.rawValue)
            tab.documentID = doc.backupSource.id.uuidString
            tab.editVersion = buf.flatMap(SessionStore.backupSource(ofBufferNamed:))?.version ?? doc.backupSource.version
            return [WindowSession(frame: "", folder: nil, sidebarVisible: false, sidebarWidth: 240,
                                  layout: "single", groups: [GroupSession(tabs: [tab], selected: 0)],
                                  activeGroup: 0, fullScreen: false)]
        }

        // First async save while Pass 1 may still be in flight, followed immediately by an edit and second async save.
        store.saveNow(synchronously: false)
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edit-while-in-flight\n")
        store.saveNow(synchronously: false)

        // Drain the serial session queue via a synchronous barrier check, then do another throttled async save.
        try store.saveNow(synchronously: true).get()
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "throttled-edit\n")
        store.saveNow(synchronously: false)

        // Wait briefly for the async pass to commit on disk.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let throttledSession = try XCTUnwrap(store.load())
        let throttledTab = try XCTUnwrap(throttledSession.windows.first?.groups.first?.tabs.first)
        let throttledName = try XCTUnwrap(throttledTab.buffer, "Throttled async save dropped the large buffer backup")
        let throttledURL = store.bufferDirectory.appendingPathComponent(throttledName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: throttledURL.path), "Previous large buffer file was garbage-collected")
        XCTAssertEqual(throttledTab.editVersion, SessionStore.backupSource(ofBufferNamed: throttledName)?.version)

        // Exiting synchronously writes the very latest text.
        try store.saveNow(synchronously: true).get()
        let finalName = try XCTUnwrap(store.load()?.windows.first?.groups.first?.tabs.first?.buffer)
        let finalText = try String(contentsOf: store.bufferDirectory.appendingPathComponent(finalName), encoding: .utf8)
        XCTAssertTrue(finalText.hasPrefix("throttled-edit\nedit-while-in-flight\n"))
    }

    // MARK: - 2. Invisibles with folds and inline-diff gaps

    func testShowInvisiblesSkipsFoldedBlocksAndAlignsWithInlineDiffGaps() {
        _ = NSApplication.shared
        let doc = Document(text: "func demo() {\n    let x = 1\n\tlet y = 2\n}\n", name: "Test.swift",
                           language: LanguageRegistry.shared.language(id: "swift") ?? LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editor.layoutManager.showInvisibles = true
        editor.layoutSubtreeIfNeeded()
        editor.layoutManager.ensureLayout(for: editor.textContainer)

        editor.fold(line: 0)
        editor.layoutManager.ensureLayout(for: editor.textContainer)
        let fold = editor.folds[0]
        // Placeholder newline and every hidden character inside the fold must not draw invisibles.
        for idx in fold.location..<NSMaxRange(fold) {
            XCTAssertNil(editor.layoutManager.invisibleDrawPosition(forCharacterAt: idx))
        }
        // Visible space on line 0 ("func ") and closing line still have valid draw positions.
        XCTAssertNotNil(editor.layoutManager.invisibleDrawPosition(forCharacterAt: 4))
        XCTAssertNotNil(editor.layoutManager.invisibleDrawPosition(forCharacterAt: NSMaxRange(fold) + 1))

        editor.unfoldAll()
        editor.layoutManager.ensureLayout(for: editor.textContainer)
        let line1Space = doc.lines.start(of: 1)
        let beforeGapY = editor.layoutManager.invisibleDrawPosition(forCharacterAt: line1Space)?.y ?? 0
        var gaps = TovriLayoutManager.Gaps()
        gaps.above[1] = 2
        editor.layoutManager.setGaps(gaps, lines: doc.lines)
        editor.layoutManager.ensureLayout(for: editor.textContainer)
        let afterGapY = editor.layoutManager.invisibleDrawPosition(forCharacterAt: line1Space)?.y ?? 0
        XCTAssertEqual(afterGapY - beforeGapY, editor.layoutManager.lineHeight * 2, accuracy: 0.5)
    }

    // MARK: - 3. Gutter without line numbers

    func testHiddenLineNumbersSelectLinesInsteadOfFoldingAndKeepGitHunkHits() {
        _ = NSApplication.shared
        let doc = Document(text: "block {\n    changed\n}\n", name: "Gutter.swift", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editor.gutter.showsNumbers = false
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
        editor.layoutManager.ensureLayout(for: editor.textContainer)

        XCTAssertEqual(editor.gutter.frame.width, 18)
        let line0Y = editor.textView.caretRect(at: 0).midY
        // Clicking anywhere in the 18pt gutter when line numbers are hidden selects the line rather than folding.
        XCTAssertEqual(editor.gutter.hitAction(at: NSPoint(x: 10, y: line0Y)), .selectLine(0))

        // Comparing against a base still exposes Git/diff hunk clicks at x < 14 when line numbers are hidden.
        let exp = expectation(description: "base diff")
        editor.compare(withBase: "block {\n    original\n}\n", label: "saved", source: .saved) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
        let line1Y = editor.textView.caretRect(at: doc.lines.start(of: 1)).midY
        if case .change(let hunk)? = editor.gutter.hitAction(at: NSPoint(x: 6, y: line1Y)) {
            XCTAssertEqual(hunk.newStart, 1)
        } else {
            XCTFail("Expected change hunk hit at x=6 when line numbers are hidden")
        }

        // Turning line numbers back on restores the fold column on the right edge.
        editor.gutter.showsNumbers = true
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.gutter.hitAction(at: NSPoint(x: editor.gutter.bounds.width - 6, y: line0Y)), .fold(0))
    }

    // MARK: - 4 & 5 & 16b. Markdown rendering and preview code copy

    func testMarkdownRawHTMLContainersStayOpenAcrossBlankLines() {
        _ = NSApplication.shared
        var renderer = MarkdownRenderer(colors: [:])
        let md = """
        <div align="center">

        # Centered Heading

        </div>

        <details>
        <summary><strong>Troubleshooting</strong></summary>
        <br />

        Run `tovri .` in Terminal.

        </details>
        """
        let html = renderer.render(md)
        XCTAssertFalse(html.contains("class=\"html\""), html)
        XCTAssertTrue(html.contains("<div data-line=\"0\" align=\"center\">"), html)
        XCTAssertTrue(html.contains("<details data-line=\"6\">"), html)

        final class DummyScheme: NSObject, WKURLSchemeHandler {
            func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {}
            func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
        }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(DummyScheme(), forURLScheme: MarkdownPreviewView.scheme)
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: config)
        final class NavigationObserver: NSObject, WKNavigationDelegate {
            let loaded: XCTestExpectation
            init(loaded: XCTestExpectation) { self.loaded = loaded }
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
        }
        let loaded = expectation(description: "webkit navigation")
        let observer = NavigationObserver(loaded: loaded)
        wv.navigationDelegate = observer
        withExtendedLifetime(observer) {
            wv.loadHTMLString("<!doctype html><html><body><div id=\"content\">\(html)</div></body></html>",
                              baseURL: URL(string: "\(MarkdownPreviewView.scheme)://page/index.html")!)
            wait(for: [loaded], timeout: 10)
        }
        let exp = expectation(description: "webkit parse")
        wv.evaluateJavaScript("[document.querySelector('details')?.textContent.includes('Terminal') ?? false, document.querySelector('div[align=center] h1')?.textContent ?? '']") { result, error in
            XCTAssertNil(error)
            let pair = result as? [Any]
            XCTAssertEqual(pair?.first as? Bool, true, "Markdown body inside <details> was closed prematurely: \(html)")
            XCTAssertEqual(pair?.last as? String, "Centered Heading")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testMarkdownTablesInterruptParagraphsAndTabIndentedListsKeepContinuations() {
        var renderer = MarkdownRenderer(colors: [:])
        let tableAfterPara = """
        Intro line:
        | Key | Value |
        | --- | ----- |
        | a   | 1     |
        """
        let tableHTML = renderer.render(tableAfterPara)
        XCTAssertTrue(tableHTML.contains("<p data-line=\"0\">Intro line:</p>\n<table data-line=\"1\">"), tableHTML)

        let tabList = "-\tFirst line\n\tSecond line\n\n\t\tlet code = 1\n"
        let listHTML = renderer.render(tabList)
        XCTAssertTrue(listHTML.contains("<p>First line\nSecond line</p>"), listHTML)
        XCTAssertTrue(listHTML.contains("<pre><code>let code = 1</code></pre>"), listHTML)
    }

    func testMarkdownPreviewCopyWritesToPasteboard() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        MarkdownPreviewView.copyCodeText("echo 'copied from preview'", to: pb)
        XCTAssertEqual(pb.string(forType: .string), "echo 'copied from preview'")
    }

    // MARK: - 6. CLI install location check

    func testCommandLineInstallAllowsPermanentVolumesAndBlocksTranslocation() throws {
        let translocated = URL(fileURLWithPath: "/private/var/folders/xx/yy/T/AppTranslocation/1234/d/Tovri.app/Contents/Resources/tovri")
        XCTAssertTrue(Integration.isTemporaryOrDiskImageLocation(translocated))

        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let localLauncher = dir.appendingPathComponent("Tovri.app/Contents/Resources/tovri")
        try FileManager.default.createDirectory(at: localLauncher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: localLauncher)
        XCTAssertFalse(Integration.isTemporaryOrDiskImageLocation(localLauncher))

        // Package root itself (even when located on a permanent `/Volumes/...` APFS drive) is allowed.
        let repoFile = URL(fileURLWithPath: #filePath)
        XCTAssertFalse(Integration.isTemporaryOrDiskImageLocation(repoFile))
    }

    // MARK: - 7. Sidebar recursive refresh

    func testSidebarRecursiveRefreshUpdatesDeepExpandedFolders() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deep = dir.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: deep.appendingPathComponent("first.txt"))

        let sidebar = SidebarView()
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.setRoot(dir)
        sidebar.reveal(deep.appendingPathComponent("first.txt"))

        try Data("two".utf8).write(to: deep.appendingPathComponent("second.txt"))
        sidebar.refreshTree()

        let a = try XCTUnwrap(sidebar.root?.children?.first { $0.name == "a" })
        let b = try XCTUnwrap(a.children?.first { $0.name == "b" })
        let c = try XCTUnwrap(b.children?.first { $0.name == "c" })
        XCTAssertEqual(c.children?.map(\.name), ["first.txt", "second.txt"])
    }

    // MARK: - 8 & 9 & 13. Format JSON selection, Smart Home, and Fold hit-testing

    func testFormatAndMinifyJSONPreserveBaseIndentationOnFullLineSelection() {
        _ = NSApplication.shared
        let initial = "const payload =\n    {\"b\":1,\"a\":[2,3]}\n"
        let doc = Document(text: initial, name: "snippet.js", language: LanguageRegistry.shared.plain)
        doc.setIndentation(tabs: false, width: 2)
        let editor = EditorView(document: doc)
        defer { editor.close() }

        let line1 = doc.lines.fullRange(of: 1, textLength: doc.length)
        editor.textView.setAllSelections([line1], scroll: false)
        editor.textView.formatJSON(nil)
        let expectedFormatted = """
        const payload =
            {
              "b": 1,
              "a": [
                2,
                3
              ]
            }

        """
        XCTAssertEqual(doc.string as String, expectedFormatted)

        let indentedBlock = NSRange(location: line1.location, length: doc.length - line1.location)
        editor.textView.setAllSelections([indentedBlock], scroll: false)
        editor.textView.minifyJSON(nil)
        XCTAssertEqual(doc.string as String, initial)
    }

    func testSmartHomeWithShiftHonorsLeftToRightSelectionAnchor() {
        _ = NSApplication.shared
        let doc = Document(text: "    hello world\n", name: "Home.txt", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        editor.layoutSubtreeIfNeeded()

        let tv = editor.textView
        tv.setAllSelections([NSRange(location: 6, length: 0)], scroll: false)
        tv.moveRightAndModifySelection(nil)
        tv.moveRightAndModifySelection(nil)
        tv.moveRightAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 6, length: 3)) // "llo"

        tv.moveToLeftEndOfLineAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 2)) // "he", anchored at 6

        tv.moveToLeftEndOfLineAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 0, length: 6)) // "    he", anchored at 6

        tv.moveToLeftEndOfLineAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 2)) // back to "he"
    }

    func testFoldPlaceholderHitTestingOnThousandsOfFoldsStaysFast() {
        _ = NSApplication.shared
        var chunk = ""
        chunk.reserveCapacity(3000 * 24)
        for i in 0..<3000 { chunk += "block\(i) {\n    body\n}\n" }
        let doc = Document(text: chunk, name: "Huge.swift", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editor.layoutSubtreeIfNeeded()
        editor.foldAll()
        XCTAssertEqual(editor.folds.count, 3000)

        editor.scrollLineToTop(doc.lines.count - 6)
        let lastFold = editor.folds[editor.folds.count - 1]
        let rect = editor.textView.foldPlaceholderRect(lastFold)
        let t0 = CACurrentMediaTime()
        let hit = editor.textView.foldPlaceholder(at: NSPoint(x: rect.midX, y: rect.midY))
        let elapsedMs = (CACurrentMediaTime() - t0) * 1000
        XCTAssertEqual(hit, lastFold)
        XCTAssertLessThan(elapsedMs, 25, "Fold placeholder hit-testing took \(elapsedMs) ms")
    }

    // MARK: - 10 & 14. Git cat-file blob safety, batch unstage, and filter cache invalidation

    func testGitHeadAndCommitContentsRejectTreesAndOversizedBlobs() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        func sh(_ cmd: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            p.currentDirectoryURL = dir
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }

        try sh("""
        git init -q . && git config user.email t@example.com && git config user.name t
        mkdir item && echo nested > item/sub.txt
        dd if=/dev/zero bs=1024 count=8 2>/dev/null | tr '\\0' 'a' > big.txt
        git add -A && git -c core.hooksPath=/dev/null commit -qm init
        rm -rf item && echo 'now a file' > item
        """)

        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("item")))

        let treeExp = expectation(description: "tree rejected")
        repo.headContents(of: dir.appendingPathComponent("item")) { data in
            XCTAssertNil(data, "Directory tree at HEAD must not be returned as file bytes")
            treeExp.fulfill()
        }

        let cappedExp = expectation(description: "oversized blob rejected")
        repo.headContents(of: dir.appendingPathComponent("big.txt"), maxBytes: 1024) { data in
            XCTAssertNil(data, "Blob exceeding maxBytes must return nil")
            cappedExp.fulfill()
        }

        let normalExp = expectation(description: "normal blob read")
        repo.headContents(of: dir.appendingPathComponent("big.txt"), maxBytes: 20_000) { data in
            XCTAssertEqual(data?.count, 8192)
            normalExp.fulfill()
        }
        wait(for: [treeExp, cappedExp, normalExp], timeout: 10)
    }

    func testGitUnstageBatchesPlainFilesAndFilterCacheRefreshesOnConfigChange() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let savedEnv = GitRepository.userEnvironment
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        GitRepository.userEnvironment = ["HOME": home.path]
        defer { GitRepository.userEnvironment = savedEnv }

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        func sh(_ cmd: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            p.currentDirectoryURL = repoDir
            p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }

        try sh("git init -q . && git config user.email t@example.com && git config user.name t")
        try "old\n".write(to: repoDir.appendingPathComponent("renamed-from.txt"), atomically: true, encoding: .utf8)
        try sh("git add -A && git -c core.hooksPath=/dev/null commit -qm init")
        try sh("git mv renamed-from.txt renamed-to.txt")
        for i in 0..<20 {
            try "file \(i)\n".write(to: repoDir.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }
        try sh("git add -A")

        let repo = try XCTUnwrap(GitRepository.find(for: repoDir.appendingPathComponent("f0.txt")))
        // Warm filter cache when no filters exist.
        XCTAssertEqual(repo.filteredPaths(["f0.txt"]), [])

        var stagedList: [GitRepository.ChangedFile] = []
        let listExp = expectation(description: "changeList")
        repo.changeList { stagedList = $0.filter(\.staged); listExp.fulfill() }
        wait(for: [listExp], timeout: 10)
        XCTAssertEqual(stagedList.count, 21)

        let unstaged = repo.unstage(stagedList)
        XCTAssertTrue(unstaged.failed.isEmpty)
        XCTAssertEqual(unstaged.done.count, 21)

        // Adding a filter to .git/config invalidates the filter cache immediately.
        try "*.bin filter=custom\n".write(to: repoDir.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try sh("git config filter.custom.clean cat")
        XCTAssertEqual(repo.filteredPaths(["asset.bin", "f0.txt"]), ["asset.bin"])
    }

    // MARK: - 11. Tab bar accessibility clipping and overflow button

    func testTabBarAccessibilityClipsOffStripTabsAndExposesOverflowButton() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...10 {
            try "let v = \(i)\n".write(to: dir.appendingPathComponent("very-long-tab-name-\(i).swift"), atomically: true, encoding: .utf8)
        }
        withController { c in
            c.window?.setContentSize(NSSize(width: 680, height: 480))
            for i in 1...10 { _ = c.open(url: dir.appendingPathComponent("very-long-tab-name-\(i).swift")) }
            c.rootView.layoutSubtreeIfNeeded()

            let bar = c.activeGroup.tabBar
            XCTAssertTrue(bar.isOverflowing)
            let stripScreen = NSAccessibility.screenRect(fromView: bar, rect: bar.stripRect)
            for tab in (bar.accessibilityTabs() as? [NSAccessibilityElement] ?? []) {
                let frame = tab.accessibilityFrame()
                guard frame != .zero else { continue }
                XCTAssertGreaterThanOrEqual(frame.minX, stripScreen.minX - 0.5)
                XCTAssertLessThanOrEqual(frame.maxX, stripScreen.maxX + 0.5)
            }

            let ob = try! XCTUnwrap(bar.overflowButtonRect)
            let obScreen = NSAccessibility.screenRect(fromView: bar, rect: ob)
            let hit = bar.accessibilityHitTest(NSPoint(x: obScreen.midX, y: obScreen.midY)) as? NSAccessibilityElement
            XCTAssertEqual(hit?.accessibilityLabel(), "All tabs")
            XCTAssertEqual(hit?.accessibilityRole(), .popUpButton)
        }
    }

    // MARK: - 12. RecentFiles directory preservation

    func testRecentFilesAvailableItemsPreservesDirectoryFlag() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let subFolder = URL(fileURLWithPath: dir.appendingPathComponent("sub").path, isDirectory: true)
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("note.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        let saved = UserDefaults.standard.stringArray(forKey: "recentItems")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "recentItems") }
            else { UserDefaults.standard.removeObject(forKey: "recentItems") }
        }
        RecentFiles.shared.clear()
        RecentFiles.shared.add(file)
        RecentFiles.shared.add(subFolder)

        let items = RecentFiles.shared.availableItems()
        XCTAssertEqual(items.first(where: { $0.path == subFolder.path })?.hasDirectoryPath, true)
        XCTAssertEqual(items.first(where: { $0.path == file.path })?.hasDirectoryPath, false)
    }

    // MARK: - 15. Reopen Closed Window

    func testClosedWindowWithUnsavedChangesCanBeReopenedWhileAnotherWindowIsOpen() throws {
        _ = NSApplication.shared
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldBuffers = SessionStore.shared.bufferDirectory
        let oldDir = SessionStore.shared.directory
        SessionStore.shared.directory = dir
        SessionStore.shared.bufferDirectory = dir.appendingPathComponent("Buffers")
        try FileManager.default.createDirectory(at: SessionStore.shared.bufferDirectory, withIntermediateDirectories: true)
        defer {
            SessionStore.shared.directory = oldDir
            SessionStore.shared.bufferDirectory = oldBuffers
        }

        let bufName = "\(UUID().uuidString)-1.txt"
        try "stashed unsaved text".write(to: SessionStore.shared.bufferDirectory.appendingPathComponent(bufName), atomically: true, encoding: .utf8)

        let app = AppDelegate()
        defer {
            for c in app.controllers {
                for g in c.groups { for t in g.tabs { t.close() } }
                c.window?.delegate = nil
                c.window?.close()
            }
        }
        let item = NSMenuItem(title: "Reopen Closed Window", action: #selector(AppDelegate.reopenClosedWindow(_:)), keyEquivalent: "")
        XCTAssertFalse(app.validateMenuItem(item))

        let tab = TabSession(path: nil, untitledName: "Draft", buffer: bufName, selection: 0, selectionLength: 0,
                             scrollX: 0, scrollY: 0, language: nil, encoding: TextEncoding.utf8.rawValue, lineEnding: LineEnding.lf.rawValue)
        let closedSession = WindowSession(frame: "", folder: nil, sidebarVisible: false, sidebarWidth: 240,
                                          layout: "single", groups: [GroupSession(tabs: [tab], selected: 0)],
                                          activeGroup: 0, fullScreen: false)
        app.recordClosedWindow(closedSession)
        _ = app.newWindow()
        XCTAssertEqual(app.controllers.count, 1)
        XCTAssertTrue(app.validateMenuItem(item))

        let reopened = try XCTUnwrap(app.reopenClosedWindow(nil))
        XCTAssertEqual(app.controllers.count, 2)
        XCTAssertEqual(reopened.activeDocument?.string as String?, "stashed unsaved text")
        XCTAssertFalse(app.validateMenuItem(item))
    }

    // MARK: - 16a, 16c, 16d. Find in Files, Key Bindings, and CLI

    func testFindInFilesEscapesRegexSelectionAndUsesOpenDocumentLanguage() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "echo $item + $item_two;\n".write(to: dir.appendingPathComponent("snippet.txt"), atomically: true, encoding: .utf8)

        try withController { c in
            let doc = try XCTUnwrap(c.open(url: dir.appendingPathComponent("snippet.txt")))
            let js = try XCTUnwrap(LanguageRegistry.shared.language(id: "javascript"))
            doc.setLanguage(js)

            let st = FindState.shared
            let prevQuery = st.query
            let prevRegex = st.regex
            defer {
                st.query = prevQuery
                st.regex = prevRegex
            }
            st.regex = true
            c.activeEditor?.select(NSRange(location: 5, length: 5)) // "$item"
            let panel = FindInFilesPanel(controller: c)
            panel.show(folder: dir)
            XCTAssertEqual(panel.findField.stringValue, "\\$item")
            panel.close()

            UserDefaults.standard.set(false, forKey: Settings.Key.gitEnabled)
            defer { UserDefaults.standard.removeObject(forKey: Settings.Key.gitEnabled) }
            let inputs = c.openSearchInputs(under: dir)
            XCTAssertTrue(inputs.languages["snippet.txt"] === js)
            var opts = FileSearcher.Options(query: "item", regex: false, caseSensitive: true, wholeWord: true,
                                            root: dir, include: [], exclude: [])
            opts.languages = inputs.languages
            let res = try XCTUnwrap(FileSearcher().run(opts))
            // In JavaScript `$` is an identifier character, so `$item` is NOT a whole-word match for `item`.
            XCTAssertEqual(res.matches, 0)
        }
    }

    func testHiddenAlternateShortcutsYieldToCustomKeyBindingsAndMergeInHelp() {
        let recent = NSMenu(title: "Open Recent")
        let menu = MainMenu.build(recentMenu: recent)
        let saved = UserDefaults.standard.dictionary(forKey: KeyBindings.storeKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: KeyBindings.storeKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyBindings.storeKey) }
            if let main = NSApp.mainMenu { KeyBindings.shared.install(on: main); KeyBindings.shared.reloadFromDefaults() }
        }

        let helpText = MainWindowController.keyboardShortcutsText(for: menu)
        let nextTabLines = helpText.split(separator: "\n").filter { $0.contains("- Next Tab ") }
        let biggerLines = helpText.split(separator: "\n").filter { $0.contains("- Bigger ") }
        XCTAssertEqual(nextTabLines.count, 1, "\(nextTabLines)")
        XCTAssertTrue(nextTabLines.first?.contains("⇧⌘]") == true, "\(nextTabLines)")
        XCTAssertEqual(biggerLines.count, 1, "\(biggerLines)")

        KeyBindings.shared.install(on: menu)
        let targetCommand = KeyBindings.shared.commands.first { $0.title == "Fold" }!
        let shiftCmdLeftBracket = KeyShortcut(key: "[", modifiers: [.command, .shift])
        KeyBindings.shared.set(shiftCmdLeftBracket, for: targetCommand.id)

        let gotoMenu = menu.item(withTitle: "Goto")!.submenu!
        let hiddenPrev = gotoMenu.items.first {
            $0.isHidden && $0.title == "Previous Tab" && $0.allowsKeyEquivalentWhenHidden
                && ($0.keyEquivalent == "[" || $0.keyEquivalent.isEmpty)
        }
        XCTAssertEqual(hiddenPrev?.keyEquivalent, "", "Hidden alternate shortcut did not yield to custom binding")

        KeyBindings.shared.reset(targetCommand.id)
        XCTAssertEqual(hiddenPrev?.keyEquivalent, "[")
    }

    func testCLICombinedShortFlagsAndStdinDecoding() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/tovri")

        let help = Process()
        help.executableURL = URL(fileURLWithPath: "/bin/bash")
        help.arguments = [script.path, "-nwh"]
        let out = Pipe()
        help.standardOutput = out
        try help.run()
        let helpData = out.fileHandleForReading.readDataToEndOfFile()
        help.waitUntilExit()
        XCTAssertEqual(help.terminationStatus, 0)
        XCTAssertTrue(String(decoding: helpData, as: UTF8.self).contains("Usage: tovri"))

        let bad = Process()
        bad.executableURL = URL(fileURLWithPath: "/bin/bash")
        bad.arguments = [script.path, "-nx"]
        bad.standardOutput = FileHandle.nullDevice
        bad.standardError = FileHandle.nullDevice
        try bad.run()
        bad.waitUntilExit()
        XCTAssertEqual(bad.terminationStatus, 2)

        // UTF-16LE with BOM and Windows-1252 decode cleanly for piped stdin.
        let utf16Bytes = try XCTUnwrap(TextEncoding.utf16LE.encode("héllo\n"))
        let decodedUTF16 = AppDelegate.decodeStandardInput(utf16Bytes)
        XCTAssertEqual(decodedUTF16.text, "héllo\n")
        XCTAssertEqual(decodedUTF16.encoding, .utf16LE)

        let cp1252Bytes = Data([0x80, 0x20, 0x31, 0x30]) // "€ 10" in Windows-1252
        let decoded1252 = AppDelegate.decodeStandardInput(cp1252Bytes)
        XCTAssertEqual(decoded1252.text, "€ 10")
        XCTAssertEqual(decoded1252.encoding, .windows1252)
    }

    // MARK: - Review verification regressions

    func testShiftRightKeepsAnchorAfterSmartHomeReversesSelection() {
        _ = NSApplication.shared
        let doc = Document(text: "    hello world\n", name: "anchor.txt", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        editor.layoutSubtreeIfNeeded()
        let tv = editor.textView

        // Extend right from 6 to 9, reverse left to 4 with Smart Home, then Shift-Right must move head 4 -> 5.
        tv.setAllSelections([NSRange(location: 6, length: 0)], scroll: false)
        for _ in 0..<3 { tv.moveRightAndModifySelection(nil) }
        tv.moveToLeftEndOfLineAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 2))
        tv.moveRightAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 1))
        tv.moveRightAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 6, length: 0))
        tv.moveRightAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 6, length: 1))

        // Extend left inside indentation (anchor 2 -> head 0), reverse right to 4 with Smart Home, then Shift-Left moves head 4 -> 3.
        tv.setAllSelections([NSRange(location: 2, length: 0)], scroll: false)
        tv.moveLeftAndModifySelection(nil)
        tv.moveLeftAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 0, length: 2))
        tv.moveToLeftEndOfLineAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 2, length: 2))
        tv.moveLeftAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 2, length: 1))
    }

    func testCappedProcessReadsEveryChunk() {
        let data = GitRepository.runProcess(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "printf first; /bin/sleep 0.1; printf second"],
            environment: [:], timeout: 3, maxOutputBytes: 1024
        )
        XCTAssertEqual(data, Data("firstsecond".utf8))
    }

    func testFilterCacheInvalidatesIncludedConfigBeforeRunningStatus() throws {
        let git = try XCTUnwrap(GitRepository.executable)
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let savedEnv = GitRepository.userEnvironment
        GitRepository.userEnvironment = ["HOME": dir.path]
        defer { GitRepository.userEnvironment = savedEnv }

        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", dir.path] + args
            p.environment = ["HOME": dir.path, "PATH": "/usr/bin:/bin"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }

        try run(["init", "-q"])
        try "a.txt filter=late\n".write(to: dir.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "before\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["add", "-A"])
        try run(["-c", "core.hooksPath=/dev/null", "-c", "user.name=test", "-c", "user.email=t@example.com", "commit", "-qm", "init"])
        let include = dir.appendingPathComponent(".git/included-config")
        try "".write(to: include, atomically: true, encoding: .utf8)
        try run(["config", "include.path", include.path])
        try "after!\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("a.txt")))
        XCTAssertEqual(repo.filteredPaths(["a.txt"]), [])
        let configStamp = DiskStamp(dir.appendingPathComponent(".git/config"))
        let marker = dir.appendingPathComponent("filter-ran")
        try "[filter \"late\"]\n\tclean = /usr/bin/touch '\(marker.path)'; cat\n\trequired = true\n"
            .write(to: include, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiskStamp(dir.appendingPathComponent(".git/config")), configStamp)
        XCTAssertEqual(repo.filteredPaths(["a.txt"]), ["a.txt"], "Included config changes must immediately invalidate the cached filter list")

        let done = expectation(description: "status")
        repo.status { status in
            XCTAssertEqual(status["a.txt"], .modified)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Status executed a filter added through an included config")
    }

    func testClearingVisibleShortcutAlsoClearsHiddenAlternates() throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.dictionary(forKey: KeyBindings.storeKey)
        let originalMenu = NSApp.mainMenu
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: KeyBindings.storeKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyBindings.storeKey) }
            if let originalMenu { KeyBindings.shared.install(on: originalMenu) }
            KeyBindings.shared.reloadFromDefaults()
        }
        UserDefaults.standard.removeObject(forKey: KeyBindings.storeKey)
        let menu = MainMenu.build(recentMenu: NSMenu(title: "Open Recent"))
        KeyBindings.shared.install(on: menu)
        KeyBindings.shared.reloadFromDefaults()

        let next = try XCTUnwrap(KeyBindings.shared.commands.first { $0.title == "Next Tab" })
        KeyBindings.shared.set(nil, for: next.id)
        let hidden = try XCTUnwrap(menu.item(withTitle: "Goto")?.submenu).items.filter { $0.isHidden && $0.title == "Next Tab" }
        XCTAssertEqual(hidden.count, 2)
        XCTAssertTrue(hidden.allSatisfy { $0.keyEquivalent.isEmpty }, "Cleared Next Tab still has hidden keys: \(hidden.map(\.keyEquivalent))")

        KeyBindings.shared.reset(next.id)
        XCTAssertEqual(Set(hidden.map(\.keyEquivalent)), ["]", "\t"])
    }

    func testPreviewScrollReportsInnerParagraphInsteadOfEnclosingContainer() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        preview.loadShell(theme: ThemeManager.shared.active, fontSize: 13)
        var renderer = MarkdownRenderer(colors: [:])
        let md = "<div>\n\n" + (0..<60).map { "Paragraph \($0) with enough body text to occupy a row." }.joined(separator: "\n\n") + "\n\n</div>"
        preview.setBody(renderer.render(md), baseDirectory: nil)
        let web = try XCTUnwrap(preview.subviews.compactMap { $0 as? WKWebView }.first)

        func evaluate(_ script: String) throws -> Any? {
            let done = expectation(description: "script")
            var value: Any?
            var failure: Error?
            web.evaluateJavaScript(script) { result, error in
                value = result
                failure = error
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            if let failure { throw failure }
            return value
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if ((try? evaluate("document.querySelectorAll('#content p').length")) as? Int ?? 0) == 60 { break }
        }
        XCTAssertEqual(try evaluate("document.querySelectorAll('#content p').length") as? Int, 60)
        _ = try evaluate("window.scrollTo(0, document.querySelector('#content p[data-line=\"62\"]').getBoundingClientRect().top + window.scrollY - 16)")
        let settle = expectation(description: "scroll settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 3)
        XCTAssertGreaterThan(try evaluate("window.scrollY") as? Double ?? 0, 300)
        XCTAssertEqual(try evaluate("+tovriLineElements().find(el => el.getBoundingClientRect().bottom > 8).dataset.line") as? Int, 62)
        XCTAssertEqual(preview.topLine, 62, "Scrolling inside a raw HTML container reports its opening line instead of the visible paragraph")
    }

    func testRecentFilesColdCacheNeverProbesDiskOnMainThread() {
        let testKey = "recentItems.coldTest.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: testKey) }
        UserDefaults.standard.set(["/tmp/one.txt", "/tmp/two-dir", "/tmp/missing.txt"], forKey: testKey)

        let probeLock = NSLock()
        var mainThreadProbes = 0
        var backgroundProbes = 0

        let recents = RecentFiles(defaultsKey: testKey) { path in
            probeLock.lock()
            if Thread.isMainThread { mainThreadProbes += 1 } else { backgroundProbes += 1 }
            probeLock.unlock()
            if path == "/tmp/missing.txt" { return nil }
            return URL(fileURLWithPath: path, isDirectory: path.hasSuffix("-dir"))
        }

        let updated = expectation(description: "background recent files update")
        let coldResult = recents.availableItems {
            updated.fulfill()
        }
        XCTAssertTrue(coldResult.isEmpty, "Cold cache must return immediately without blocking main thread on disk")
        probeLock.lock()
        XCTAssertEqual(mainThreadProbes, 0, "Cold cache probed filesystem on the main thread")
        probeLock.unlock()

        wait(for: [updated], timeout: 5)
        let warmResult = recents.availableItems()
        XCTAssertEqual(warmResult.map(\.path), ["/tmp/one.txt", "/tmp/two-dir"])
        XCTAssertEqual(warmResult.map(\.hasDirectoryPath), [false, true])
        probeLock.lock()
        XCTAssertEqual(mainThreadProbes, 0)
        XCTAssertGreaterThanOrEqual(backgroundProbes, 3)
        probeLock.unlock()
    }

    func testClosedDetailsRemainsAScrollAnchor() throws {
        _ = NSApplication.shared
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        preview.loadShell(theme: ThemeManager.shared.active, fontSize: 13)
        var renderer = MarkdownRenderer(colors: [:])
        preview.setBody(renderer.render("<details>\n<summary>Summary</summary>\n\nInside paragraph\n\n</details>\n\nAfter"), baseDirectory: nil)
        let web = try XCTUnwrap(preview.subviews.compactMap { $0 as? WKWebView }.first)

        func evaluate(_ script: String) throws -> Any? {
            let done = expectation(description: "script")
            var value: Any?
            var failure: Error?
            web.evaluateJavaScript(script) { result, error in
                value = result
                failure = error
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            if let failure { throw failure }
            return value
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if (try? evaluate("!!document.querySelector('details')")) as? Bool == true { break }
        }
        XCTAssertEqual(try evaluate("document.querySelector('details').open") as? Bool, false)
        let closed = try XCTUnwrap(try evaluate("tovriLineElements().map(el => el.tagName + ':' + el.dataset.line).join(',')") as? String)
        XCTAssertTrue(closed.contains("DETAILS:0"), "Collapsed details must remain a leaf scroll anchor: \(closed)")
        XCTAssertFalse(closed.contains("P:3"), "Hidden details content must not be a visible scroll anchor: \(closed)")
        _ = try evaluate("document.querySelector('details').open = true")
        let open = try XCTUnwrap(try evaluate("tovriLineElements().map(el => el.tagName + ':' + el.dataset.line).join(',')") as? String)
        XCTAssertTrue(open.contains("P:3"), open)
    }

    func testShiftDownKeepsOriginalColumnAcrossShortLine() {
        _ = NSApplication.shared
        let doc = Document(text: "abcdefghijklmnop\nx\nabcdefghijklmnop\n", name: "column.txt", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        editor.layoutSubtreeIfNeeded()
        let tv = editor.textView

        tv.setAllSelections([NSRange(location: 12, length: 0)], scroll: false)
        tv.moveDownAndModifySelection(nil)
        XCTAssertEqual(NSMaxRange(tv.selectedRange()), 18, "The first move reaches the short line's end")
        tv.moveDownAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 12, length: 19), "The second Shift-Down must restore column 12 on the next long line")

        tv.moveUpAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 12, length: 6))
        tv.moveUpAndModifySelection(nil)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 12, length: 0))
    }

    func testRecentFilesDropsDeletedItemAfterBackgroundProbe() throws {
        let key = "recentItems.followup.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-recent-\(UUID().uuidString).txt")
        try "text".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let recents = RecentFiles(defaultsKey: key)
        recents.add(file)
        try FileManager.default.removeItem(at: file)
        let updated = expectation(description: "existence check completed")
        _ = recents.availableItems { updated.fulfill() }
        wait(for: [updated], timeout: 5)
        XCTAssertTrue(recents.availableItems().isEmpty, "An item confirmed missing by the background probe must leave the available recent files")
    }

    func testFilterCacheTracksTheEffectiveSystemConfig() throws {
        let git = try XCTUnwrap(GitRepository.executable)
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let systemConfig = dir.appendingPathComponent("isolated-system-config")
        try "".write(to: systemConfig, atomically: true, encoding: .utf8)
        let savedEnv = GitRepository.userEnvironment
        GitRepository.userEnvironment = ["HOME": dir.path, "GIT_CONFIG_SYSTEM": systemConfig.path]
        defer { GitRepository.userEnvironment = savedEnv }

        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", dir.path] + args
            p.environment = ["HOME": dir.path, "GIT_CONFIG_SYSTEM": systemConfig.path, "PATH": "/usr/bin:/bin"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }

        try run(["init", "-q"])
        try "a.txt filter=late\n".write(to: dir.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "before\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["add", "-A"])
        try run(["-c", "core.hooksPath=/dev/null", "-c", "user.name=test", "-c", "user.email=t@example.com", "commit", "-qm", "init"])
        try "after!\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("a.txt")))
        XCTAssertEqual(repo.filteredPaths(["a.txt"]), [])
        let marker = dir.appendingPathComponent("filter-ran")
        try "[filter \"late\"]\n\tclean = /usr/bin/touch '\(marker.path)'; cat\n\trequired = true\n"
            .write(to: systemConfig, atomically: true, encoding: .utf8)
        XCTAssertEqual(repo.filteredPaths(["a.txt"]), ["a.txt"], "The cache must track the effective system config, regardless of its install prefix")

        let done = expectation(description: "status")
        repo.status { status in
            XCTAssertEqual(status["a.txt"], .modified)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Status must not execute a filter introduced through the effective system config")
    }
}
