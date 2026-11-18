import AppKit
import CryptoKit
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import Tovri

/// Deterministic regression suite covering every scenario identified in the initial audit.
final class OriginalAuditScenariosTests: XCTestCase {
    private var tempDirs: [URL] = []

    override class func setUp() {
        super.setUp()
        TestIsolationObserver.install()
    }

    override func tearDown() {
        AutoSave.shared.save = nil
        AutoSave.shared.delayOverride = nil
        AppRuntime.defaults.removePersistentDomain(forName: AppRuntime.testSuiteName)
        Settings.shared.reloadFromDefaults()
        ThemeManager.shared.clearPreviews()
        WaitRegistry.shared.releaseAll()
        for url in tempDirs { try? FileManager.default.removeItem(at: url) }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir(_ prefix: String = "tovri-audit-") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func withController(_ body: (MainWindowController) throws -> Void) rethrows {
        _ = NSApplication.shared
        let c = MainWindowController()
        defer {
            for g in c.groups { for t in g.tabs { t.close() } }
            c.teardown()
            c.window?.delegate = nil
            c.window?.close()
        }
        try body(c)
    }

    @discardableResult
    private func shell(_ command: String, in dir: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private let gitCommit = "git -c user.email=t@example.com -c user.name=t -c core.hooksPath=/dev/null commit -qm"

    // MARK: 1.1 Read-only auto-paired brackets at EOF

    func testReadOnlyDocumentIgnoresAutoPairedBracketAndTypeOverAtEOF() {
        _ = NSApplication.shared
        let doc = Document(text: "abc", name: "ReadOnly.swift", language: LanguageRegistry.shared.language(id: "swift") ?? LanguageRegistry.shared.plain)
        doc.isReadOnly = true
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        editor.layoutSubtreeIfNeeded()

        editor.textView.setAllSelections([NSRange(location: doc.length, length: 0)], scroll: false)
        editor.textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(doc.string as String, "abc")
        XCTAssertFalse(doc.isDirty)
    }

    // MARK: 1.2 Gutter click on empty doc, EOF trailing empty line, and folded block

    func testGutterClickOnEmptyBufferEOFLinesAndFoldedBlock() {
        _ = NSApplication.shared
        let empty = Document(text: "", name: "Empty.txt", language: LanguageRegistry.shared.plain)
        let e1 = EditorView(document: empty)
        defer { e1.close() }
        e1.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        e1.layoutSubtreeIfNeeded()
        XCTAssertEqual(e1.gutter.hitAction(at: NSPoint(x: 10, y: 50)), .selectLine(0))

        let trailing = Document(text: "alpha\n", name: "Trail.txt", language: LanguageRegistry.shared.plain)
        let e2 = EditorView(document: trailing)
        defer { e2.close() }
        e2.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        e2.layoutSubtreeIfNeeded()
        let line1Top = GutterView.top(ofLine: 1, in: e2.textView)
        let clickY = e2.gutter.convert(NSPoint(x: 20, y: line1Top + e2.textView.textContainerOrigin.y + 4), from: e2.textView).y
        XCTAssertEqual(GutterView.line(at: NSPoint(x: 20, y: clickY), in: e2.textView, from: e2.gutter), 1)

        let swift = LanguageRegistry.shared.language(id: "swift") ?? LanguageRegistry.shared.plain
        let foldable = Document(text: "func f() {\n    let a = 1\n    let b = 2\n}\nlet after = 3\n", name: "Fold.swift", language: swift)
        let e3 = EditorView(document: foldable)
        defer { e3.close() }
        e3.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        e3.layoutSubtreeIfNeeded()
        e3.fold(line: 0)
        XCTAssertEqual(e3.folds.count, 1)
        let block = e3.textView.visualLineBlock(NSRange(location: 0, length: 0))
        XCTAssertEqual(block, NSRange(location: 0, length: foldable.lines.start(of: 4)))
    }

    // MARK: 1.3 Hot-Exit large-buffer 4-pass throttle

    func testLargeBufferSessionFourPassThrottleSequence() throws {
        let dir = try makeTempDir("tovri-4pass-")
        let store = SessionStore()
        store.directory = dir
        store.bufferDirectory = dir.appendingPathComponent("Buffers")
        defer { store.stateProvider = nil }

        let d = AppRuntime.defaults
        d.set(true, forKey: Settings.Key.hotExit)
        d.set(true, forKey: Settings.Key.restoreSession)
        Settings.shared.reloadFromDefaults()

        let doc = Document()
        doc.restoreBuffer(String(repeating: "0123456789abcdef\n", count: 250_000))
        store.stateProvider = { [weak store] in
            let buf = store?.bufferName(for: doc)
            let tab = TabSession(path: nil, untitledName: doc.displayName, buffer: buf,
                                 selection: 0, selectionLength: 0, scrollX: 0, scrollY: 0,
                                 language: nil, encoding: doc.encoding.rawValue, lineEnding: doc.lineEnding.rawValue)
            return [WindowSession(frame: "", folder: nil, sidebarVisible: false, sidebarWidth: 240,
                                  layout: "single", groups: [GroupSession(tabs: [tab], selected: 0)],
                                  activeGroup: 0, fullScreen: false)]
        }

        // Pass 1: initial write succeeds.
        try store.saveNow(synchronously: true).get()
        let pass1Name = try XCTUnwrap(store.load()?.windows.first?.groups.first?.tabs.first?.buffer)

        // Pass 2 & Pass 3: async in-flight edit + immediate throttled edit keep backup file valid.
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "pass2\n")
        store.saveNow(synchronously: false)
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "pass3\n")
        store.saveNow(synchronously: false)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        let pass3Name = try XCTUnwrap(store.load()?.windows.first?.groups.first?.tabs.first?.buffer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.bufferDirectory.appendingPathComponent(pass3Name).path))
        XCTAssertFalse(pass1Name.isEmpty)

        // Pass 4: final synchronous flush captures pass3 + pass2 edits.
        try store.saveNow(synchronously: true).get()
        let pass4Name = try XCTUnwrap(store.load()?.windows.first?.groups.first?.tabs.first?.buffer)
        let saved = try String(contentsOf: store.bufferDirectory.appendingPathComponent(pass4Name), encoding: .utf8)
        XCTAssertTrue(saved.hasPrefix("pass3\npass2\n"))
    }

    // MARK: 1.4 tovri --wait, Hot-Exit interaction & empty stdin release

    func testWaitRegistryBlocksHotExitAndEmptyStdinReleasesMarkerAndLauncherFailsWhenTovriMissing() throws {
        let dir = try makeTempDir("tovri-wait-")
        let app = AppDelegate()
        let c = MainWindowController()
        c.newTab(nil)
        let waitedDoc = try XCTUnwrap(c.activeDocument)
        waitedDoc.restoreBuffer("commit message\n")
        let waitID = UUID().uuidString
        WaitRegistry.shared.register(waitID, for: waitedDoc)
        XCTAssertTrue(WaitRegistry.shared.isWaiting(on: waitedDoc))

        // Hot exit must NOT silently swallow a waited dirty document on single-window close.
        let d = AppRuntime.defaults
        d.set(true, forKey: Settings.Key.hotExit)
        Settings.shared.reloadFromDefaults()
        let mirrorApp = AppDelegate()
        let c2 = mirrorApp.newWindow()
        defer {
            c2.teardown(); c2.window?.delegate = nil; c2.window?.close()
            c.teardown(); c.window?.delegate = nil; c.window?.close()
            _ = app
        }
        let d2 = c2.activeDocument!
        d2.restoreBuffer("waited unsaved")
        WaitRegistry.shared.register(UUID().uuidString, for: d2)
        XCTAssertFalse(mirrorApp.closingKeepsUnsavedChanges(c2))

        // Empty stdin waiter closes cleanly when tab closes / document releases.
        let markerDir = AppRuntime.supportDirectory.appendingPathComponent("Wait", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        let id2 = UUID().uuidString
        let marker2 = markerDir.appendingPathComponent(id2)
        try Data().write(to: marker2)
        autoreleasepool {
            let stdinDoc = Document()
            WaitRegistry.shared.register(id2, for: stdinDoc)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker2.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker2.path), "Empty stdin doc deallocation must release wait marker")

        // Real scripts/tovri -w with fake PATH (no Tovri running -> pgrep fails) exits 1 after timeout and cleans up markers.
        let fakeHome = dir.appendingPathComponent("home")
        let fakeBin = dir.appendingPathComponent("bin")
        let fakeTmp = dir.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTmp, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 1\n".write(to: fakeBin.appendingPathComponent("pgrep"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: fakeBin.appendingPathComponent("open"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBin.appendingPathComponent("pgrep").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBin.appendingPathComponent("open").path)

        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/tovri")
        let target = dir.appendingPathComponent("commit-edit.txt")
        try "initial".write(to: target, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path, "-w", target.path]
        proc.environment = ["HOME": fakeHome.path, "TMPDIR": fakeTmp.path, "PATH": "\(fakeBin.path):/usr/bin:/bin"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 1, "tovri -w must fail with exit 1 if Tovri never consumes/releases the wait marker")
        let leftWait = (try? FileManager.default.contentsOfDirectory(atPath: fakeHome.appendingPathComponent("Library/Application Support/Tovri/Wait").path)) ?? []
        XCTAssertTrue(leftWait.isEmpty, "Failed wait must clean up wait marker files")
    }

    // MARK: 1.5 Write-in-place space check overflow safety

    func testWriteInPlaceSpaceCheckHandlesUInt64OverflowSafely() {
        XCTAssertTrue(Document.fitsAvailableSpace(neededBytes: 4096, availableBlocks: UInt64.max / 2 + 1, blockSize: 4096))
        XCTAssertFalse(Document.fitsAvailableSpace(neededBytes: 4097, availableBlocks: 1, blockSize: 4096))
        XCTAssertTrue(Document.fitsAvailableSpace(neededBytes: 0, availableBlocks: 0, blockSize: 0))
    }

    // MARK: 1.6 focusLost and AutoSave safety guards

    func testFocusLostAndAutoSaveSkipDeletedNewAndComposingDocuments() throws {
        let dir = try makeTempDir("tovri-autosave-")
        let url = dir.appendingPathComponent("existing.txt")
        try "initial\n".write(to: url, atomically: true, encoding: .utf8)

        let d = AppRuntime.defaults
        d.set(true, forKey: Settings.Key.saveOnFocusLost)
        Settings.shared.reloadFromDefaults()

        try withController { c in
            let existing = try XCTUnwrap(c.open(url: url))
            let tv = try XCTUnwrap(c.activeEditor?.textView)
            let newDoc = c.openNewFile(at: dir.appendingPathComponent("never-created.txt"))
            let deleted = try XCTUnwrap(c.open(url: {
                let u = dir.appendingPathComponent("deleted.txt")
                try "gone\n".write(to: u, atomically: true, encoding: .utf8)
                return u
            }()))
            try FileManager.default.removeItem(at: dir.appendingPathComponent("deleted.txt"))
            deleted.markDeletedOnDisk()

            // Mark text on `existing` inside a key window to simulate active IME composition.
            c.window?.makeKeyAndOrderFront(nil)
            c.window?.makeFirstResponder(tv)
            tv.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(tv.hasMarkedText())
            XCTAssertTrue(AutoSave.isComposing(existing))
            XCTAssertFalse(AutoSave.canSave(newDoc))
            XCTAssertFalse(AutoSave.canSave(deleted))
            tv.unmarkText()
            XCTAssertFalse(AutoSave.isComposing(existing))
            XCTAssertTrue(AutoSave.canSave(existing))
        }
    }

    // MARK: 2.1 Git 2.54+ hooks neutralization

    func testHookSettingsAndParseConfigOverridesNeutralizeGitHooksAndRejectNonUTF8() {
        let sample = Data("file:/tmp/repo/.git/config\u{0}hook.post-commit.command\n/tmp/evil.sh\u{0}file:/tmp/repo/.git/config\u{0}filter.lfs.clean\ngit-lfs\u{0}".utf8)
        let parsed = GitRepository.parseConfigOverrides(sample, home: "/tmp")
        XCTAssertEqual(parsed?.hooks, ["post-commit"])
        XCTAssertEqual(parsed?.filters, ["lfs"])

        let settings = GitRepository.hookSettings(names: parsed?.hooks ?? [])
        XCTAssertEqual(settings.map { "\($0.key)=\($0.value)" }, [
            "hook.post-commit.enabled=false",
            "hook.post-commit.event=",
            "hook.post-commit.command=",
        ])

        var invalid = Data("file:/tmp/repo/.git/config\u{0}hook.".utf8)
        invalid.append(contentsOf: [0xff, 0xfe])
        invalid.append(contentsOf: ".command\n/evil\u{0}".utf8)
        XCTAssertNil(GitRepository.parseConfigOverrides(invalid, home: "/tmp"))
    }

    // MARK: 2.2 & 2.4d Markdown preview click security, template sanitizer, untitled base & budget delta

    func testMarkdownPreviewBlocksUntrustedCopySanitizesMetadataUsesUntitledBaseAndPositiveDeltaBudget() throws {
        _ = NSApplication.shared
        XCTAssertEqual(MarkdownPreviewView.baseHref(for: nil), "tovri-preview://untitled/")

        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 500, height: 350))
        preview.loadShell(theme: ThemeManager.shared.active, fontSize: 13)
        let rawHTML = "<base href=\"https://evil.example/\"><meta http-equiv=\"refresh\" content=\"0;url=https://evil.example\"><link rel=\"dns-prefetch\" href=\"//evil.example\"><button class=\"code-copy\" id=\"fake-btn\">Copy</button><pre><code>real</code></pre>"
        preview.setBody(rawHTML, baseDirectory: nil)
        let web = try XCTUnwrap(preview.subviews.compactMap { $0 as? WKWebView }.first)

        func eval(_ js: String) throws -> Any? {
            let done = expectation(description: js)
            var out: Any?
            web.evaluateJavaScript(js) { v, _ in out = v; done.fulfill() }
            wait(for: [done], timeout: 5)
            return out
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if (try? eval("document.querySelectorAll('#content pre button.code-copy').length")) as? Int == 1 { break }
        }
        XCTAssertEqual(try eval("document.querySelectorAll('#content base, #content meta, #content link').length") as? Int, 0)

        let pbBefore = AppRuntime.pasteboard.changeCount
        _ = try eval("document.getElementById('fake-btn').click(); document.querySelector('#content pre button.code-copy').click()")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(AppRuntime.pasteboard.changeCount, pbBefore, "Untrusted programmatic .click() must never copy to pasteboard")

        // Positive delta accounting for shrinking/growing reloads without cumulative budget exhaustion.
        let budget = PreviewResourceBudget()
        let key = "tovri-preview://file/clip.mp4"
        let mb = 1024 * 1024
        XCTAssertTrue(budget.admit(key, size: 100 * mb))
        XCTAssertEqual(budget.total, 100 * mb)
        for _ in 0..<10 { XCTAssertTrue(budget.admit(key, size: 100 * mb)) }
        XCTAssertEqual(budget.total, 100 * mb)
        XCTAssertTrue(budget.admit(key, size: 120 * mb))
        XCTAssertEqual(budget.total, 120 * mb)
    }

    // MARK: 2.3 CodeLexer exponential backtracking guard

    func testCodeLexerUnclosedInterpolationHasNoExponentialBacktracking() {
        let pathological = "\"" + String(repeating: "${", count: 80) + " tail\n"
        let utf16 = Array(pathological.utf16)
        let t0 = CACurrentMediaTime()
        for id in ["javascript", "typescript", "swift", "markdown"] {
            guard let lexer = LanguageRegistry.shared.language(id: id)?.lexer else { continue }
            utf16.withUnsafeBufferPointer { buf in
                _ = lexer.lex(buf, state: 0) { _, _, _ in }
            }
        }
        let elapsedMs = (CACurrentMediaTime() - t0) * 1000
        XCTAssertLessThan(elapsedMs, 150, "Unclosed interpolation scan took \(elapsedMs) ms")
    }

    // MARK: 2.4a Blocking FIFO guards

    func testFIFONamedPipesDoNotBlockEditorConfigDocumentQuickLookOrGit() throws {
        let dir = try makeTempDir("tovri-fifo-")
        let ecFifo = dir.appendingPathComponent(".editorconfig")
        let textFifo = dir.appendingPathComponent("pipe.txt")
        let keyFifo = dir.appendingPathComponent("secret.key")
        let gitFifo = dir.appendingPathComponent(".git")
        for p in [ecFifo, textFifo, keyFifo] { XCTAssertEqual(mkfifo(p.path, 0o600), 0) }

        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(sub.appendingPathComponent(".git").path, 0o600), 0)
        _ = gitFifo

        let start = Date()
        _ = EditorConfig.properties(for: dir.appendingPathComponent("a.swift"))
        XCTAssertThrowsError(try Document(contentsOf: textFifo))
        XCTAssertFalse(MainWindowController.prefersQuickLook(keyFifo))
        XCTAssertNil(GitRepository.find(for: sub.appendingPathComponent("a.swift")))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    // MARK: 2.4c Git filter stage/discard edge cases

    func testGitStageRefusesRecreatedDeletedFilteredFileAndDiscardChecksCachedAttributes() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let dir = try makeTempDir("tovri-filter-edge-")
        let marker = dir.appendingPathComponent("ran")
        let filter = dir.appendingPathComponent("f.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\ncat\n".write(to: filter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: filter.path)

        XCTAssertEqual(try shell("""
        git init -q . && git config user.email t@example.com && git config user.name t
        git config filter.custom.clean '\(filter.path)'
        git config filter.custom.smudge '\(filter.path)'
        printf 'asset.bin filter=custom\\n' > .gitattributes
        printf 'v1\\n' > asset.bin
        git add -A && \(gitCommit) init
        git rm --cached -q asset.bin
        """, in: dir), 0)

        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("asset.bin")))
        try? FileManager.default.removeItem(at: marker)
        let stageRes = repo.stage([GitRepository.ChangedFile(path: "asset.bin", status: .deleted)])
        XCTAssertTrue(stageRes.refused.contains { $0.path == "asset.bin" && $0.reason == .filtered })

        // Restore clean working tree, delete .gitattributes in worktree, edit asset.bin -> discard must still see cached filter=custom.
        XCTAssertEqual(try shell("git reset -q HEAD -- asset.bin && rm .gitattributes && printf 'v2\\n' > asset.bin", in: dir), 0)
        try? FileManager.default.removeItem(at: marker)
        let discardRes = repo.discard([GitRepository.ChangedFile(path: "asset.bin", status: .modified)], trash: { _ in })
        XCTAssertTrue(discardRes.refused.contains { $0.path == "asset.bin" && $0.reason == .filtered })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: 3.2 Split views sharing document clamp transient ranges

    func testSplitViewsSharingDocumentClampTransientRangesAndRedrawSafelyWhenShrunk() {
        _ = NSApplication.shared
        let doc = Document(text: "func alpha() { let alpha = 1 }\n", name: "Split.swift",
                           language: LanguageRegistry.shared.language(id: "swift") ?? LanguageRegistry.shared.plain)
        let e1 = EditorView(document: doc)
        let e2 = EditorView(document: doc)
        defer { e1.close(); e2.close() }
        e1.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        e2.frame = NSRect(x: 0, y: 0, width: 500, height: 300)

        e2.textView.setAllSelections([NSRange(location: 5, length: 5)], scroll: false) // "alpha"
        e2.textView.updateOccurrences()
        e2.textView.setAllSelections([NSRange(location: 13, length: 0)], scroll: false) // '('
        e2.textView.updateBracketMatch()
        e2.textView.extraSelections = [NSRange(location: 20, length: 5)]

        doc.textStorage.replaceCharacters(in: NSRange(location: 4, length: doc.length - 4), with: "")
        XCTAssertNil(e2.textView.bracketPair)
        XCTAssertTrue(e2.textView.occurrenceRanges.isEmpty)
        XCTAssertTrue(e2.textView.extraSelections.allSatisfy { NSMaxRange($0) <= doc.length })
        e2.display()
    }

    // MARK: 3.3 Broken folds recover non-zero line height

    func testEditingInsideFoldClearsNullGlyphsAndProducesVisibleLineHeight() {
        _ = NSApplication.shared
        let swift = LanguageRegistry.shared.language(id: "swift") ?? LanguageRegistry.shared.plain
        let doc = Document(text: "func test() {\n    let inside = 1\n}\n", name: "F.swift", language: swift)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        editor.layoutSubtreeIfNeeded()

        editor.fold(line: 0)
        XCTAssertEqual(editor.folds.count, 1)
        let insideLine1 = doc.lines.start(of: 1) + 4
        doc.textStorage.replaceCharacters(in: NSRange(location: insideLine1, length: 0), with: "x")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        editor.layoutManager.ensureLayout(for: editor.textContainer)
        XCTAssertTrue(editor.folds.isEmpty)

        let line1Start = doc.lines.start(of: 1)
        let g = editor.layoutManager.glyphIndexForCharacter(at: line1Start)
        let rect = editor.layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        XCTAssertGreaterThan(rect.height, 0, "Unfolded line must not keep zero-height .null glyph layout")
    }

    // MARK: 3.4 Coalesced multi-edit preserves intermediate Bookmarks & undo

    func testBookmarksSurviveMultiEditOnIntermediateLinesAndUndoRedo() {
        _ = NSApplication.shared
        let text = (0..<60).map { "line \($0)\n" }.joined()
        let doc = Document(text: text, name: "BM.txt", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        doc.bookmarks.set([25], lineCount: doc.lines.count)

        let line50Start = doc.lines.start(of: 50)
        editor.textView.performEdits([
            TextEdit(NSRange(location: 0, length: 0), "inserted-a\ninserted-b\n"),
            TextEdit(NSRange(location: line50Start, length: 0), "tail\n"),
        ], actionName: "Multi")
        XCTAssertEqual(doc.bookmarks.lines, [27])

        doc.undoManager.undo()
        XCTAssertEqual(doc.bookmarks.lines, [25])
        doc.undoManager.redo()
        XCTAssertEqual(doc.bookmarks.lines, [27])
    }

    // MARK: 3.5 Multi-cursor surrogate snapping preserves valid UTF-8

    func testMultiCursorSurrogateSnappingPreservesValidSaveableUTF8() throws {
        let dir = try makeTempDir("tovri-surrogate-")
        let url = dir.appendingPathComponent("emoji.txt")
        let doc = Document(text: "ab😀cd\nabcd\n", name: "emoji.txt", language: LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        // Attempt to split in the middle of the 😀 surrogate pair (UTF-16 offset 3 on line 0).
        let broken = NSRange(location: 3, length: 1)
        editor.textView.setAllSelections([broken, NSRange(location: 10, length: 0)], scroll: false)
        editor.textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        try doc.save(to: url)
        let data = try Data(contentsOf: url)
        XCTAssertNotNil(String(data: data, encoding: .utf8))
    }

    // MARK: 3.6 Empty committed file diff & InlineDiff EOF clamping

    func testEmptyCommittedFileLineDiffIsPureAdditionAndInlineDiffClampsEOFDeletion() {
        let diff = GitRepository.diff(oldText: "", newText: "hello")
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.hunks.first?.oldLines, [])
        XCTAssertEqual(diff.marks, [0: .added])

        let delDiff = GitRepository.diff(old: ["a", "b", "c"], new: ["a", "b"])
        let inline = InlineDiff(diff: delDiff, lineCount: 3)
        XCTAssertEqual(inline.gaps.above[2], 1)
        XCTAssertTrue(inline.applyEdit(firstLine: 1, removed: 1, inserted: 0, lineCount: 1))
        XCTAssertEqual(inline.gaps.trailing, 1)
        XCTAssertTrue(inline.gaps.above.keys.allSatisfy { $0 < 1 })
    }

    // MARK: 3.7 ReplaceInFiles prefers open Document over earlier symlink

    func testReplaceInFilesPrefersOpenDocumentTargetOverEarlierSymlink() throws {
        let dir = try makeTempDir("tovri-replace-sym-")
        let d = AppRuntime.defaults
        d.set(false, forKey: Settings.Key.gitEnabled)
        let target = dir.appendingPathComponent("z_target.txt")
        let alias = dir.appendingPathComponent("0_link.txt")
        try "disk alpha\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let doc = try DocumentRegistry.shared.open(target)
        DocumentRegistry.shared.register(doc)
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: doc.length), with: "buffer alpha\n")

        let opts = FileSearcher.Options(query: "alpha", regex: false, caseSensitive: false, wholeWord: false,
                                        root: dir, include: [], exclude: [])
        let open = ReplaceInFiles.openFiles(under: dir, in: [doc])
        let plan = try XCTUnwrap(ReplaceInFiles.plan(opts, replacement: "beta", open: open))
        XCTAssertEqual(plan.targets.count, 1)
        XCTAssertNotNil(plan.targets.first?.open)
        XCTAssertEqual(plan.targets.first?.url.realPathURL.path, target.realPathURL.path)

        let batch = ReplaceBatch()
        let outcomes = ReplaceInFiles.applyInEditors(plan, batch: batch)
        XCTAssertEqual(outcomes.first?.replaced, 1)
        XCTAssertEqual(doc.string as String, "buffer beta\n")
    }

    // MARK: 3.8 Default editor UTIs exclude MPEG transport stream (.ts video)

    func testDefaultEditorContentTypesExcludeMpegTransportStream() throws {
        let plistURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL) as? [String: Any])
        let types = Integration.defaultEditorContentTypes(from: plist)
        XCTAssertFalse(types.contains { $0.identifier == "public.mpeg-2-transport-stream" })
    }

    // MARK: 3.9 Git porcelain C copy, intent-to-add discard, and ?? subrepo/

    func testGitUnstageCopyDiscardIntentAddedAndUntrackedNestedGitRepo() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let dir = try makeTempDir("tovri-porcelain-")
        try shell("""
        git init -q . && git config user.email t@example.com && git config user.name t
        printf 'one\\n' > a.txt && git add a.txt && \(gitCommit) init
        cp a.txt copy.txt && git add copy.txt
        printf 'intent\\n' > intent.txt && git add -N intent.txt
        mkdir subrepo && (cd subrepo && git init -q . && printf 'inner\\n' > s.txt)
        """, in: dir)

        let repo = try XCTUnwrap(GitRepository.find(for: dir.appendingPathComponent("a.txt")))
        let exp = expectation(description: "changes")
        var files: [GitRepository.ChangedFile] = []
        repo.changeList { files = $0; exp.fulfill() }
        wait(for: [exp], timeout: 10)

        let entries = GitRepository.parseStatusEntries(Data("C  copy.txt\u{0}a.txt\u{0}R  moved.txt\u{0}orig.txt\u{0}".utf8))
        XCTAssertEqual(entries.first { $0.path == "copy.txt" }?.staged, .added)
        XCTAssertEqual(entries.first { $0.path == "moved.txt" }?.staged, .renamed)
        XCTAssertEqual(entries.first { $0.path == "moved.txt" }?.originalPath, "orig.txt")

        let copyChange = GitRepository.ChangedFile(path: "copy.txt", status: .added, staged: true, originalPath: "a.txt")
        XCTAssertEqual(repo.unstage([copyChange]).done, ["copy.txt"])

        let intent = try XCTUnwrap(files.first { $0.path == "intent.txt" && !$0.staged })
        var trashed: [URL] = []
        XCTAssertEqual(repo.discard([intent], trash: { trashed.append($0) }).done, ["intent.txt"])
        XCTAssertTrue(trashed.contains { $0.lastPathComponent == "intent.txt" })

        let sub = try XCTUnwrap(files.first { $0.path == "subrepo/" })
        XCTAssertEqual(repo.discard([sub], trash: { trashed.append($0) }).done, ["subrepo/"])
        XCTAssertTrue(trashed.contains { $0.lastPathComponent == "subrepo" })
    }

    // MARK: 4.1 restoreSession=false + hotExit variants

    func testRestoreSessionFalseKeepsOnlyHotExitDirtyBuffersAndPurgesWhenBothOff() throws {
        let windows = [WindowSession(
            frame: "", folder: "/tmp/folder", sidebarVisible: true, sidebarWidth: 240, layout: "single",
            groups: [GroupSession(tabs: [
                TabSession(path: "/tmp/clean.txt", untitledName: nil, buffer: nil, selection: 0, selectionLength: 0,
                           scrollX: 0, scrollY: 0, language: nil, encoding: "UTF-8", lineEnding: "LF"),
                TabSession(path: nil, untitledName: "Untitled", buffer: "buf-1", selection: 0, selectionLength: 0,
                           scrollX: 0, scrollY: 0, language: nil, encoding: "UTF-8", lineEnding: "LF"),
            ], selected: 0)], activeGroup: 0, fullScreen: false
        )]
        let kept = SessionStore.hotExitOnlyWindows(from: windows)
        XCTAssertEqual(kept.count, 1)
        XCTAssertNil(kept[0].folder)
        XCTAssertEqual(kept[0].groups[0].tabs.map(\.buffer), ["buf-1"])

        let dir = try makeTempDir("tovri-purge-")
        let store = SessionStore()
        store.directory = dir
        store.bufferDirectory = dir.appendingPathComponent("Buffers")
        let d = AppRuntime.defaults
        d.set(true, forKey: Settings.Key.hotExit)
        d.set(true, forKey: Settings.Key.restoreSession)
        Settings.shared.reloadFromDefaults()

        let doc = Document()
        doc.restoreBuffer("unsaved")
        store.stateProvider = { [weak store] in
            let b = store?.bufferName(for: doc)
            return [WindowSession(frame: "", folder: nil, sidebarVisible: false, sidebarWidth: 240, layout: "single",
                                  groups: [GroupSession(tabs: [TabSession(path: nil, untitledName: "U", buffer: b, selection: 0,
                                                                          selectionLength: 0, scrollX: 0, scrollY: 0,
                                                                          language: nil, encoding: "UTF-8", lineEnding: "LF")],
                                                        selected: 0)], activeGroup: 0, fullScreen: false)]
        }
        defer { store.stateProvider = nil }
        try store.saveNow(synchronously: true).get()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionFile.path))

        d.set(false, forKey: Settings.Key.hotExit)
        d.set(false, forKey: Settings.Key.restoreSession)
        Settings.shared.reloadFromDefaults()
        try store.saveNow(synchronously: true).get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionFile.path))
        let remainingBuffers = (try? FileManager.default.contentsOfDirectory(atPath: store.bufferDirectory.path)) ?? []
        XCTAssertTrue(remainingBuffers.isEmpty)
    }

    // MARK: 4.2 ChangesView selection preservation & focus

    func testChangesViewSingleClickFocusesListAndPreservesSelectionAcrossStage() {
        _ = NSApplication.shared
        let view = ChangesView()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = view
        defer { win.close() }

        let unstaged = [
            GitRepository.ChangedFile(path: "a.txt", status: .modified),
            GitRepository.ChangedFile(path: "b.txt", status: .modified),
        ]
        view.setFiles(unstaged)
        let firstRow = view.list.numberOfRows > 1 ? 1 : 0
        view.list.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
        view.focus()
        XCTAssertTrue(win.firstResponder === view.list)

        view.setFiles([
            GitRepository.ChangedFile(path: "a.txt", status: .modified, staged: true),
            GitRepository.ChangedFile(path: "b.txt", status: .modified),
        ])
        XCTAssertFalse(view.list.selectedRowIndexes.isEmpty)
    }

    // MARK: 4.3 finishGitAction discard keeps dirty unsaved edits without conflict sheet

    func testGitActionDiscardKeepsDirtyUnsavedEditsWithoutConflictAlert() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let dir = try makeTempDir("tovri-discard-dirty-")
        try shell("git init -q . && git config user.email t@example.com && git config user.name t && echo v1 > f.txt && git add f.txt && \(gitCommit) init", in: dir)
        let file = dir.appendingPathComponent("f.txt")
        try "v2-disk\n".write(to: file, atomically: true, encoding: .utf8)

        try withController { c in
            c.setFolder(dir)
            let doc = try XCTUnwrap(c.open(url: file))
            c.activeEditor?.textView.performEdits([TextEdit(NSRange(location: 0, length: 0), "unsaved-")], actionName: "Edit")
            XCTAssertTrue(doc.isDirty)

            let repo = try XCTUnwrap(GitRepository.find(for: file))
            let res = repo.discard([GitRepository.ChangedFile(path: "f.txt", status: .modified)], trash: { _ in })
            c.finishGitAction(res, files: [GitRepository.ChangedFile(path: "f.txt", status: .modified)], verb: "discard")

            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "v1\n")
            XCTAssertEqual(doc.string as String, "unsaved-v2-disk\n", "Git discard must preserve unsaved editor buffer")
            XCTAssertTrue(doc.isDirty)
            XCTAssertEqual(doc.checkDiskStatus(), .unchanged, "checkExternalChanges must not raise a conflict alert after discard")
        }
    }

    // MARK: 4.4 Show Changes as Patch live updates

    func testShowChangesAsPatchUpdatesAcrossConsecutiveEdits() throws {
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let dir = try makeTempDir("tovri-patch-tab-")
        try shell("git init -q . && git config user.email t@example.com && git config user.name t && printf 'one\\n' > a.txt && git add a.txt && \(gitCommit) init", in: dir)
        let file = dir.appendingPathComponent("a.txt")
        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)

        try withController { c in
            c.setFolder(dir)
            let doc = try XCTUnwrap(c.open(url: file))
            doc.refreshGitBaseline()
            let deadline = Date().addingTimeInterval(5)
            while !doc.hasGitBaseline && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            c.showChangesAsPatch(nil)
            let patchDoc = try XCTUnwrap(c.activeGroup.tabs.first { $0.document.changesSource === doc }?.document)
            XCTAssertTrue((patchDoc.string as String).contains("+two"))

            for marker in ["edit-second", "edit-third"] {
                doc.textStorage.replaceCharacters(in: NSRange(location: doc.length, length: 0), with: "\(marker)\n")
                let d2 = Date().addingTimeInterval(3)
                while !(patchDoc.string as String).contains(marker) && Date() < d2 {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                XCTAssertTrue((patchDoc.string as String).contains("+\(marker)"), "Patch tab failed to update on \(marker)")
            }
        }
    }

    // MARK: 4.5 Full Markdown Preview focus

    func testFullMarkdownPreviewFocusesWebViewInsteadOfHiddenTextView() {
        _ = NSApplication.shared
        let doc = Document(text: "# Heading\n", name: "Note.md", language: LanguageRegistry.shared.language(id: "markdown") ?? LanguageRegistry.shared.plain)
        let editor = EditorView(document: doc)
        defer { editor.close() }
        editor.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let win = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = editor
        defer { win.close() }

        editor.setPreviewMode(.full)
        editor.focus()
        XCTAssertFalse(win.firstResponder === editor.textView)
        XCTAssertTrue(win.firstResponder is WKWebView)
    }

    // MARK: 4.7 Theme picker preview cleanup on window close

    func testClosingWindowWithThemePickerOpenRestoresSavedTheme() {
        _ = NSApplication.shared
        let initial = ThemeManager.shared.active
        let other = ThemeManager.shared.themes.first { $0 !== initial }!
        withController { c in
            c.rootView.layoutSubtreeIfNeeded()
            c.showThemePicker(nil)
            ThemeManager.shared.preview(other, from: .picker)
            XCTAssertTrue(ThemeManager.shared.active === other)
        }
        // MainWindowController.teardown() closes the open palette and cancels the preview.
        XCTAssertTrue(ThemeManager.shared.active === initial)
    }

    // MARK: 4.8 openNewFile deduplication across windows

    func testOpenNewFileAcrossTwoWindowsSharesRegistryDocument() throws {
        let dir = try makeTempDir("tovri-open-new-")
        let url = dir.appendingPathComponent("brand-new.txt")
        withController { w1 in
            withController { w2 in
                let d1 = w1.openNewFile(at: url)
                let d2 = w2.openNewFile(at: url)
                XCTAssertTrue(d1 === d2)
            }
        }
    }

    // MARK: 4.9 Sidebar 2-hop symlink loop & nodesByPath cleanup

    func testSidebarTwoHopSymlinkCycleAndDirectoryReplacementRefreshNodesByPath() throws {
        let dir = try makeTempDir("tovri-2hop-")
        // Mutual broken 2-hop symlink loop `a -> b`, `b -> a` terminates cleanly without marking expandable.
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)

        // Two-hop directory symlink cycle: dir/folder/hop -> dir/hop2 -> dir.
        let folder = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hop2 = dir.appendingPathComponent("hop2")
        try FileManager.default.createSymbolicLink(at: hop2, withDestinationURL: dir)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("hop"), withDestinationURL: hop2)

        let root = FileNode(url: dir, isDirectory: true, parent: nil)
        root.loadChildren()
        let childA = try XCTUnwrap(root.children?.first { $0.name == "a" })
        XCTAssertFalse(childA.isDirectory)
        XCTAssertFalse(childA.isExpandable)

        let folderNode = try XCTUnwrap(root.children?.first { $0.name == "folder" })
        folderNode.loadChildren()
        let hopNode = try XCTUnwrap(folderNode.children?.first { $0.name == "hop" })
        XCTAssertTrue(hopNode.isDirectory)
        XCTAssertTrue(hopNode.isLink)
        XCTAssertTrue(hopNode.isLoop)
        XCTAssertFalse(hopNode.isExpandable)

        // Replacing a real folder on disk refreshes SidebarView without crashing or keeping stale paths.
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "old\n".write(to: sub.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        let sidebar = SidebarView()
        sidebar.frame = NSRect(x: 0, y: 0, width: 220, height: 400)
        sidebar.setRoot(dir)
        sidebar.reveal(sub.appendingPathComponent("old.txt"), select: true, expand: true)
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "new\n".write(to: sub.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        sidebar.filesChanged([sub.path])
        sidebar.reveal(sub.appendingPathComponent("new.txt"), select: true, expand: true)
    }

    // MARK: 4.10 SettingsBackup > 50 themes + Document.setEncoding

    func testSettingsBackupSupportsOver50ThemesAndDocumentSetEncodingMarksDirtyWithoutDiskWrite() throws {
        let dir = try makeTempDir("tovri-backup-200-")
        let themes = (0..<60).map { i in
            ThemeDefinition(name: "Custom \(i)", dark: true, background: "#101010", foreground: "#EEEEEE", accent: "#00AAFF")
        }
        let d = AppRuntime.defaults
        d.set("Custom 55", forKey: Settings.Key.theme)
        let data = try SettingsBackup.make(from: d, themes: themes).encoded()
        let decoded = try SettingsBackup.decode(data)
        XCTAssertEqual(decoded.themes.count, 60)

        let store = CustomThemeStore(directory: dir)
        try themes.forEach { try store.save($0) }
        let file = dir.appendingPathComponent("sample.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
        try withController { c in
            let doc = try XCTUnwrap(c.open(url: file))
            let item = NSMenuItem(title: "UTF-16 LE", action: nil, keyEquivalent: "")
            item.representedObject = TextEncoding.utf16LE.rawValue
            c.setEncoding(item)
            XCTAssertEqual(doc.encoding, .utf16LE)
            XCTAssertTrue(doc.isDirty, "Changing encoding must mark document dirty instead of writing disk without permission")
            XCTAssertEqual(try Data(contentsOf: file), Data("hello\n".utf8))
            doc.undoManager.undo()
            XCTAssertEqual(doc.encoding, .utf8)
            XCTAssertFalse(doc.isDirty)
        }
    }

    // MARK: 1.7 SidebarView.trash dispatches recycle completion (NSAlert + reload) onto main thread

    func testSidebarTrashCompletionDispatchesErrorAndReloadOntoMainThread() throws {
        let dir = try makeTempDir("tovri-sidebar-trash-")
        let victim = dir.appendingPathComponent("victim.txt")
        let keeper = dir.appendingPathComponent("keeper.txt")
        try "bye\n".write(to: victim, atomically: true, encoding: .utf8)
        try "stay\n".write(to: keeper, atomically: true, encoding: .utf8)

        let sidebar = SidebarView()
        sidebar.frame = NSRect(x: 0, y: 0, width: 220, height: 300)
        sidebar.setRoot(dir)

        let victimNode = try XCTUnwrap(
            (0..<sidebar.outline.numberOfRows)
                .compactMap { sidebar.outline.item(atRow: $0) as? FileNode }
                .first { $0.name == "victim.txt" }
        )

        let exp = expectation(description: "main-thread trash completion")
        var handlerCalledOnMainThread = false
        sidebar.recycleNode(
            victimNode,
            recycle: { urls, completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    for u in urls { try? FileManager.default.removeItem(at: u) }
                    completion([:], NSError(domain: "TovriTestTrash", code: 42, userInfo: nil))
                }
            },
            errorHandler: { error in
                handlerCalledOnMainThread = Thread.isMainThread
                XCTAssertEqual((error as NSError).code, 42)
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(handlerCalledOnMainThread)
        XCTAssertEqual(sidebar.root?.children?.map(\.name), ["keeper.txt"])
    }

    // MARK: 3.7(c) & 5.4 applySaveCleanups trims whitespace-only trailing line without appending extra blank line

    func testSaveCleanupsTrimWhitespaceOnlyTrailingLineWithoutDoubleNewline() {
        let doc = Document(text: "hello\n   ", name: "trim.txt", language: LanguageRegistry.shared.plain)
        doc.applySaveCleanups(trimTrailingWhitespace: true, insertFinalNewline: true)
        XCTAssertEqual(doc.string as String, "hello\n")

        doc.undoManager.undo()
        XCTAssertEqual(doc.string as String, "hello\n   ")
    }

    // MARK: 5.2, 5.3, 5.4, 5.5 Gap buffer LineIndex, Patience diff on >40M product, incremental tail reload, and Git patch cap

    func testLineIndexGapBufferPatienceDiffIncrementalTailAndGitPatchCap() throws {
        // 5.2: LineIndex gap buffer stays exact across localized top and tail edits on 10k lines.
        let tenK = (0..<10_000).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        let gapDoc = Document(text: tenK, name: "gap.txt", language: LanguageRegistry.shared.plain)
        XCTAssertEqual(gapDoc.lines.count, 10_001)
        let line2Start = gapDoc.lines.start(of: 2)
        gapDoc.textStorage.replaceCharacters(in: NSRange(location: line2Start, length: 0), with: "inserted-top\n")
        XCTAssertEqual(gapDoc.lines.count, 10_002)
        XCTAssertEqual(gapDoc.lines.start(of: 3), line2Start + "inserted-top\n".utf16.count)
        let line9990Start = gapDoc.lines.start(of: 9990)
        gapDoc.textStorage.replaceCharacters(in: NSRange(location: line9990Start, length: 0), with: "inserted-bottom\n")
        XCTAssertEqual(gapDoc.lines.count, 10_003)
        XCTAssertEqual(gapDoc.lines.line(containing: gapDoc.lines.start(of: 9991)), 9991)

        // Ground-truth check against fresh rebuild.
        let freshIndex = LineIndex()
        freshIndex.rebuild(from: gapDoc.string)
        XCTAssertEqual(gapDoc.lines.count, freshIndex.count)
        for sample in [0, 1, 2, 3, 500, 9990, 9991, gapDoc.lines.count - 1] {
            XCTAssertEqual(gapDoc.lines.start(of: sample), freshIndex.start(of: sample))
        }

        // 5.3: Patience diff on 10,000-line files (>40M o*n) differing only at first & last line produces 2 localized hunks.
        let baseLines = (0..<10_000).map { "unique-line-\($0)" }
        var modLines = baseLines
        modLines[0] = "changed-first-line"
        modLines[9_999] = "changed-last-line"
        let diff = GitRepository.diff(oldText: baseLines.joined(separator: "\n") + "\n",
                                      newText: modLines.joined(separator: "\n") + "\n")
        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertEqual(diff.hunks.map(\.newCount), [1, 1])

        // 5.4: Incremental tail reload appends grown log lines without resetting caret on line 1.
        let tailDir = try makeTempDir("tovri-tail-")
        let logFile = tailDir.appendingPathComponent("app.log")
        let initialLog = (1...20).map { "entry-\($0)" }.joined(separator: "\n") + "\n"
        try initialLog.write(to: logFile, atomically: true, encoding: .utf8)
        try withController { c in
            let doc = try XCTUnwrap(c.open(url: logFile))
            let editor = try XCTUnwrap(c.activeEditor)
            editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
            let fh = try FileHandle(forWritingTo: logFile)
            defer { try? fh.close() }
            try fh.seekToEnd()
            try fh.write(contentsOf: Data("entry-21\nentry-22\n".utf8))
            c.checkExternalChanges()
            XCTAssertTrue((doc.string as String).hasSuffix("entry-21\nentry-22\n"))
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 0))
        }

        // 5.5: GitRepository.patch caps output at maxBlobSize on oversized untracked files.
        try XCTSkipIf(GitRepository.executable == nil, "git is not installed")
        let repoDir = try makeTempDir("tovri-patch-cap-")
        try shell("""
        git init -q . && git config user.email t@example.com && git config user.name t
        printf 'init\\n' > init.txt && git add init.txt && \(gitCommit) init
        """, in: repoDir)
        try "changed\n".write(to: repoDir.appendingPathComponent("init.txt"), atomically: true, encoding: .utf8)
        let huge = Data(repeating: 65, count: GitRepository.maxBlobSize + 65_536) // 'A'
        try huge.write(to: repoDir.appendingPathComponent("huge.txt"))
        let repo = try XCTUnwrap(GitRepository.find(for: repoDir.appendingPathComponent("init.txt")))
        let patchExp = expectation(description: "patch")
        var patchOut = ""
        repo.patch(for: [.init(path: "init.txt", status: .modified), .init(path: "huge.txt", status: .untracked)]) {
            patchOut = $0
            patchExp.fulfill()
        }
        wait(for: [patchExp], timeout: 15)
        XCTAssertTrue(patchOut.contains("init.txt"))
        XCTAssertFalse(patchOut.contains("huge.txt"))
        XCTAssertLessThanOrEqual(patchOut.utf8.count, GitRepository.maxBlobSize)
    }
}
