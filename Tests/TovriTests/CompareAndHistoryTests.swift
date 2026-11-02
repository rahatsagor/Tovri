import AppKit
import XCTest
@testable import Tovri

final class CompareAndHistoryTests: XCTestCase {
    private var dir: URL!
    private var sharedHistory: LocalHistory!
    private var sharedPasteboard: NSPasteboard!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-compare-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sharedHistory = LocalHistory.shared
        LocalHistory.shared = LocalHistory(directory: dir.appendingPathComponent("History", isDirectory: true))
        sharedPasteboard = MainWindowController.comparisonPasteboard
        MainWindowController.comparisonPasteboard = NSPasteboard(name: NSPasteboard.Name("app.tovri.tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        LocalHistory.shared.waitUntilIdle()
        LocalHistory.shared = sharedHistory
        MainWindowController.comparisonPasteboard.releaseGlobally()
        MainWindowController.comparisonPasteboard = sharedPasteboard
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func setText(_ doc: Document, _ text: String) {
        doc.textStorage.replaceCharacters(in: NSRange(location: 0, length: doc.length), with: text)
    }

    private func kept(_ history: LocalHistory, _ url: URL) -> [String] {
        history.waitUntilIdle()
        return history.snapshots(for: url).map { String(decoding: history.data(of: $0, for: url) ?? Data(), as: UTF8.self) }
    }

    private func spin(_ seconds: TimeInterval = 5, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
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

    private func open(_ url: URL, in controller: MainWindowController) throws -> (Document, EditorView) {
        let doc = try XCTUnwrap(controller.open(url: url))
        controller.rootView.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(controller.activeEditor)
        XCTAssertTrue(editor.document === doc)
        return (doc, editor)
    }

    /// Waits until the editor compares with `source` and its changes match the current text.
    private func waitForComparison(_ editor: EditorView, _ source: ComparisonSource, hunks: Int? = nil) {
        spin(until: {
            editor.comparisonSource == source && editor.isComparing && editor.isLineDiffCurrent
                && (hunks == nil || editor.lineDiff.hunks.count == hunks)
        })
        XCTAssertEqual(editor.comparisonSource, source)
        XCTAssertTrue(editor.isLineDiffCurrent)
    }

    private func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

    // MARK: Comparing

    func testCompareWithSavedShowsUnsavedEditsAndRevertRestoresTheFileOnDisk() throws {
        let url = try file("saved.txt", "one\ntwo\nthree\n")
        try withController { controller in
            let (doc, editor) = try open(url, in: controller)
            XCTAssertFalse(controller.validateMenuItem(item(#selector(MainWindowController.compareWithSaved(_:)))),
                           "Compare with Saved is offered without unsaved changes")
            editor.textView.performEdits([TextEdit(NSRange(location: 4, length: 3), "TWO")], actionName: "Type")
            XCTAssertTrue(doc.isDirty)
            XCTAssertTrue(controller.validateMenuItem(item(#selector(MainWindowController.compareWithSaved(_:)))))

            controller.compareWithSaved(nil)
            waitForComparison(editor, .saved, hunks: 1)
            XCTAssertEqual(editor.comparisonLabel, "the saved file")
            XCTAssertEqual(editor.lineDiff.hunks.first?.oldLines, ["two"])
            XCTAssertEqual(editor.inlineDiff?.deleted, 1)
            XCTAssertNotNil(editor.gitHunk(at: 1))

            editor.textView.setAllSelections([NSRange(location: 5, length: 0)])
            editor.revertGitChange(try XCTUnwrap(editor.gitHunkAtCaret))
            XCTAssertEqual(doc.string as String, "one\ntwo\nthree\n")
            spin(until: { editor.isLineDiffCurrent && editor.lineDiff.hunks.isEmpty })
            XCTAssertTrue(editor.lineDiff.hunks.isEmpty)

            // Saving refreshes what “saved” means, so the comparison follows the new file.
            editor.textView.performEdits([TextEdit(NSRange(location: 0, length: 3), "ONE")], actionName: "Type")
            controller.save(doc)
            XCTAssertEqual(try contents(url), "ONE\ntwo\nthree\n")
            spin(until: { editor.isLineDiffCurrent && editor.lineDiff.hunks.isEmpty })
            XCTAssertTrue(editor.lineDiff.hunks.isEmpty, "the comparison kept the text from before the save")
            XCTAssertEqual(editor.comparisonSource, .saved)

            // Choosing it again stops, as does ⎋.
            controller.compareWithSaved(nil)
            XCTAssertFalse(editor.isComparing)
            XCTAssertNil(editor.comparisonSource)
        }
    }

    func testCompareWithClipboardAndRevertTakesTheClipboardsLine() throws {
        let url = try file("clip.txt", "alpha\nbeta\ngamma\n")
        let pb = MainWindowController.comparisonPasteboard
        pb.clearContents()
        pb.setString("alpha\r\nbeta\r\nGAMMA\r\ndelta\r\n", forType: .string)
        try withController { controller in
            let (doc, editor) = try open(url, in: controller)
            controller.compareWithClipboard(nil)
            waitForComparison(editor, .clipboard, hunks: 1)
            XCTAssertEqual(editor.comparisonLabel, "the clipboard")
            let h = try XCTUnwrap(editor.lineDiff.hunks.first)
            XCTAssertEqual(h.oldLines, ["GAMMA", "delta"], "the clipboard's line endings weren't normalized")
            XCTAssertEqual(h.newStart, 2)
            editor.revertGitChange(h)
            XCTAssertEqual(doc.string as String, "alpha\nbeta\nGAMMA\ndelta\n")
            spin(until: { editor.isLineDiffCurrent && editor.lineDiff.hunks.isEmpty })
            XCTAssertTrue(editor.lineDiff.hunks.isEmpty)

            editor.cancelOperationFallback()
            XCTAssertFalse(editor.isComparing)
            XCTAssertNil(editor.comparisonLabel)
        }
    }

    func testCompareWithFileAndRevertingEachKindOfChange() throws {
        let url = try file("mine.txt", "a\nb\nc\nd\n")
        let other = try file("theirs.txt", "a\nB\nc\nd\ne\n")
        try withController { controller in
            let (doc, editor) = try open(url, in: controller)
            controller.compare(editor, withFileAt: other)
            waitForComparison(editor, .file(other), hunks: 2)
            XCTAssertEqual(editor.comparisonLabel, "“theirs.txt”")
            XCTAssertEqual(editor.lineDiff.hunks.map(\.oldLines), [["B"], ["e"]])
            // Reverting from the end keeps the earlier hunk's lines valid.
            for h in editor.lineDiff.hunks.reversed() {
                spin(until: { editor.isLineDiffCurrent })
                let current = try XCTUnwrap(editor.lineDiff.hunks.first { $0.oldLines == h.oldLines })
                editor.revertGitChange(current)
            }
            XCTAssertEqual(doc.string as String, "a\nB\nc\nd\ne\n")
            XCTAssertEqual(try contents(url), "a\nb\nc\nd\n", "comparing changed the file on disk")
        }
    }

    func testComparedFilesMustBeRegularTextFilesOfModestSize() throws {
        let text = try file("latin.txt", "caf\u{E9}\r\n")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A]).write(to: text)
        XCTAssertEqual(MainWindowController.comparisonText(at: text, encoding: nil), .success("caf\u{E9}\n"))

        let binary = dir.appendingPathComponent("image.bin")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x01]).write(to: binary)
        XCTAssertEqual(MainWindowController.comparisonText(at: binary, encoding: nil), .failure(.binary))

        let large = dir.appendingPathComponent("large.txt")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(MainWindowController.maxComparedSize + 1))
        try handle.close()
        XCTAssertEqual(MainWindowController.comparisonText(at: large, encoding: nil), .failure(.tooLarge))

        XCTAssertEqual(MainWindowController.comparisonText(at: dir, encoding: nil), .failure(.notAFile))
        let fifo = dir.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertEqual(MainWindowController.comparisonText(at: fifo, encoding: nil), .failure(.notAFile), "a named pipe was read")
        XCTAssertEqual(MainWindowController.comparisonText(at: dir.appendingPathComponent("missing"), encoding: nil), .failure(.unreadable))

        // A symlink to a text file is followed.
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: text)
        XCTAssertEqual(MainWindowController.comparisonText(at: link, encoding: nil), .success("caf\u{E9}\n"))
    }

    func testComparisonsOtherThanCommitsWorkWithGitTurnedOff() throws {
        let d = UserDefaults.standard
        d.set(false, forKey: Settings.Key.gitChangesAndHistory)
        defer { d.removeObject(forKey: Settings.Key.gitChangesAndHistory) }
        let url = try file("nogit.txt", "x\ny\n")
        MainWindowController.comparisonPasteboard.clearContents()
        MainWindowController.comparisonPasteboard.setString("x\nz\n", forType: .string)
        try withController { controller in
            let (_, editor) = try open(url, in: controller)
            controller.compareWithClipboard(nil)
            waitForComparison(editor, .clipboard, hunks: 1)
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
            XCTAssertTrue(editor.isComparing, "a settings change stopped a comparison that isn't a Git feature")
            XCTAssertEqual(editor.lineDiff.hunks.count, 1)
            // Commits still follow the setting.
            var shown = false
            editor.compare(withBase: "x\n", label: "abc1234") { _ in shown = true }
            spin(0.5, until: { shown })
            XCTAssertFalse(shown)
        }
    }

    // MARK: Local history

    func testEachSaveKeepsThePreviousVersionOnceAndSkipsIdenticalText() throws {
        let history = LocalHistory.shared
        let url = try file("notes.txt", "one\n")
        let doc = try Document(contentsOf: url)
        setText(doc, "two\n")
        try doc.save()
        XCTAssertEqual(kept(history, url), ["one\n"])
        XCTAssertEqual(try contents(url), "two\n")

        // Saving text that's already on disk keeps nothing.
        try doc.save()
        XCTAssertEqual(kept(history, url), ["one\n"])

        setText(doc, "three\n")
        try doc.save()
        XCTAssertEqual(kept(history, url), ["two\n", "one\n"])

        // Another program puts back the newest kept text; it isn't kept twice.
        try "two\n".write(to: url, atomically: false, encoding: .utf8)
        setText(doc, "four\n")
        try doc.save(replacingExternalChanges: true)
        XCTAssertEqual(kept(history, url), ["two\n", "one\n"])

        let newest = try XCTUnwrap(history.snapshots(for: url).first)
        XCTAssertEqual(newest.size, 4)
        // The same file reached through a symlink shares its history.
        let link = dir.appendingPathComponent("notes-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertEqual(history.snapshots(for: link), history.snapshots(for: url))
    }

    func testFilesAboveTheSizeLimitAndNewFilesAreNotKept() throws {
        var limits = LocalHistory.Limits()
        limits.maxFileSize = 64
        let history = LocalHistory(directory: dir.appendingPathComponent("Small"), limits: limits)
        let big = try file("big.txt", String(repeating: "x", count: 65))
        history.recordBeforeOverwrite(of: big, with: Data("new".utf8))
        XCTAssertEqual(kept(history, big), [])
        let small = try file("small.txt", String(repeating: "x", count: 64))
        history.recordBeforeOverwrite(of: small, with: Data("new".utf8))
        XCTAssertEqual(kept(history, small).count, 1)

        history.recordBeforeOverwrite(of: dir.appendingPathComponent("not-yet.txt"), with: Data("new".utf8))
        let fifo = dir.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        history.recordBeforeOverwrite(of: fifo, with: Data("new".utf8))
        XCTAssertEqual(kept(history, fifo), [])
    }

    func testHardLinkedFilesKeepTheTextFromBeforeTheSave() throws {
        let url = try file("linked.txt", "before\n")
        XCTAssertEqual(link(url.path, dir.appendingPathComponent("other-link.txt").path), 0)
        let doc = try Document(contentsOf: url)
        setText(doc, "after\n")
        try doc.save()
        XCTAssertEqual(try contents(dir.appendingPathComponent("other-link.txt")), "after\n")
        XCTAssertEqual(kept(LocalHistory.shared, url), ["before\n"])
    }

    func testRetentionDropsTheOldestByCountAgeAndTotalSize() throws {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        var limits = LocalHistory.Limits()
        limits.maxSnapshotsPerFile = 3
        limits.maxAge = 10 * 24 * 60 * 60
        limits.maxTotalSize = 1_000
        limits.fullPruneInterval = 0
        let history = LocalHistory(directory: dir.appendingPathComponent("Retention"), limits: limits, now: { clock })
        let url = try file("a.txt", "")
        func record(_ url: URL, _ text: String) throws {
            try text.write(to: url, atomically: false, encoding: .utf8)
            history.recordBeforeOverwrite(of: url, with: Data("next".utf8))
            history.waitUntilIdle()
            clock += 60
        }
        for i in 1...5 { try record(url, "v\(i)") }
        XCTAssertEqual(kept(history, url), ["v5", "v4", "v3"])
        let folder = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: history.directory.path).first)
        let files = try FileManager.default.contentsOfDirectory(atPath: history.directory.appendingPathComponent(folder).path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".snapshot") }.count, 3, "pruned copies were left on disk")

        clock += 11 * 24 * 60 * 60
        try record(url, "v6")
        XCTAssertEqual(kept(history, url), ["v6"])

        // The total limit removes the oldest copies of any file first: v6, then the first b.
        let b = try file("b.txt", ""), c = try file("c.txt", "")
        try record(b, String(repeating: "b", count: 400))
        try record(c, String(repeating: "c", count: 400))
        XCTAssertEqual(kept(history, url), ["v6"])
        try record(b, String(repeating: "B", count: 400))
        XCTAssertEqual(kept(history, b), [String(repeating: "B", count: 400)])
        XCTAssertEqual(kept(history, c).count, 1)
        XCTAssertEqual(kept(history, url), [])

        // Copies past the age limit go even without a new save of that file.
        clock += 11 * 24 * 60 * 60
        history.pruneNow()
        XCTAssertEqual(kept(history, b), [])
        XCTAssertEqual(kept(history, c), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.directory.path), [], "empty history folders were left behind")
    }

    func testHistoryIsReadableOnlyByTheUser() throws {
        let url = try file("private.txt", "secret\n")
        let doc = try Document(contentsOf: url)
        setText(doc, "public\n")
        try doc.save()
        let history = LocalHistory.shared
        history.waitUntilIdle()
        func mode(_ path: String) throws -> Int {
            try (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(try mode(history.directory.path), 0o700)
        let folders = try FileManager.default.contentsOfDirectory(at: history.directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 1)
        let folder = try XCTUnwrap(folders.first)
        XCTAssertEqual(try mode(folder.path), 0o700)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 2, "\(files)")
        for f in files { XCTAssertEqual(try mode(folder.appendingPathComponent(f).path), 0o600, f) }
        XCTAssertTrue(files.contains("index.json"))
        let index = try String(contentsOf: folder.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertTrue(index.contains("private.txt"), "the index doesn't name the original file")

        let cleared = expectation(description: "cleared")
        history.clear { cleared.fulfill() }
        wait(for: [cleared], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.directory.path))
        XCTAssertEqual(history.snapshots(for: url), [])
    }

    func testAHistoryThatCantBeWrittenDoesNotStopTheSave() throws {
        let blocker = try file("blocker", "a file where the history folder should be")
        LocalHistory.shared = LocalHistory(directory: blocker.appendingPathComponent("History"))
        let url = try file("work.txt", "old\n")
        let doc = try Document(contentsOf: url)
        setText(doc, "new\n")
        XCTAssertNoThrow(try doc.save())
        LocalHistory.shared.waitUntilIdle()
        XCTAssertEqual(try contents(url), "new\n")
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(LocalHistory.shared.snapshots(for: url), [])

        // Nor does a history folder the user can't write to.
        let locked = dir.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o500)
        defer { chmod(locked.path, 0o700) }
        LocalHistory.shared = LocalHistory(directory: locked.appendingPathComponent("History"))
        setText(doc, "newer\n")
        XCTAssertNoThrow(try doc.save())
        LocalHistory.shared.waitUntilIdle()
        XCTAssertEqual(try contents(url), "newer\n")
    }

    func testComparingWithAKeptVersionRevertsHunksAndRestoreThisVersionIsUndoable() throws {
        let url = try file("story.txt", "first\nsecond\nthird\n")
        try withController { controller in
            let (doc, editor) = try open(url, in: controller)
            editor.textView.performEdits([TextEdit(NSRange(location: 0, length: 5), "FIRST")], actionName: "Type")
            controller.save(doc)
            editor.textView.performEdits([TextEdit(NSRange(location: doc.length, length: 0), "fourth\n")], actionName: "Type")
            controller.save(doc)
            XCTAssertEqual(try contents(url), "FIRST\nsecond\nthird\nfourth\n")
            XCTAssertTrue(controller.validateMenuItem(item(#selector(MainWindowController.showLocalHistory(_:)))))
            XCTAssertFalse(controller.validateMenuItem(item(#selector(MainWindowController.restoreComparedVersion(_:)))))

            let snapshots = kept(LocalHistory.shared, url)
            XCTAssertEqual(snapshots, ["FIRST\nsecond\nthird\n", "first\nsecond\nthird\n"])
            let oldest = try XCTUnwrap(LocalHistory.shared.snapshots(for: url).last)
            controller.compare(editor, withSnapshot: oldest, of: url)
            waitForComparison(editor, .snapshot(oldest), hunks: 2)
            XCTAssertTrue(editor.comparisonLabel?.hasPrefix("the version from ") == true, editor.comparisonLabel ?? "")
            XCTAssertTrue(controller.validateMenuItem(item(#selector(MainWindowController.restoreComparedVersion(_:)))))

            // Revert Change restores one hunk from the kept version.
            editor.textView.setAllSelections([NSRange(location: 0, length: 0)])
            editor.revertGitChange(try XCTUnwrap(editor.gitHunkAtCaret))
            XCTAssertEqual(doc.string as String, "first\nsecond\nthird\nfourth\n")
            spin(until: { editor.isLineDiffCurrent && editor.lineDiff.hunks.count == 1 })

            // Restore This Version replaces the rest as one undoable edit, without saving.
            editor.textView.performEdits([TextEdit(NSRange(location: 6, length: 6), "2nd")], actionName: "Type")
            // Undo groups edits by run loop pass, as it would by key press.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let before = doc.string as String
            controller.restoreComparedVersion(nil)
            XCTAssertEqual(doc.string as String, "first\nsecond\nthird\n")
            XCTAssertTrue(doc.isDirty)
            XCTAssertEqual(try contents(url), "FIRST\nsecond\nthird\nfourth\n", "restoring saved the file")
            spin(until: { editor.isLineDiffCurrent && editor.lineDiff.hunks.isEmpty })
            XCTAssertTrue(editor.lineDiff.hunks.isEmpty)
            doc.undoManager.undo()
            XCTAssertEqual(doc.string as String, before)
            doc.undoManager.redo()
            XCTAssertEqual(doc.string as String, "first\nsecond\nthird\n")
        }
    }

    func testRestoreEditCoversOnlyTheChangedLines() {
        let cases: [(String, String)] = [
            ("a\nb\nc\n", "a\nX\nc\n"), ("a\nb\nc\n", "a\nb\nc\n"), ("", "new\n"), ("old\n", ""),
            ("same\nab\n", "same\naXb\n"), ("x😀y\n", "x😁y\n"), ("😀\n😀\n", "😀\n😀\n😀\n"), ("a\nb", "a\nb\nc"),
            ("line\n", "line\nline\n"), ("p\nq\n", "q\n"),
        ]
        for (current, target) in cases {
            let edit = MainWindowController.restoreEdit(from: current as NSString, to: target as NSString)
            if current == target { XCTAssertNil(edit); continue }
            let e = try! XCTUnwrap(edit)
            let result = (current as NSString).replacingCharacters(in: e.range, with: e.text)
            XCTAssertEqual(result, target, "\(current.debugDescription) → \(target.debugDescription)")
            XCTAssertFalse(e.text.contains("\u{FFFD}"), "a surrogate pair was split")
        }
        let e = MainWindowController.restoreEdit(from: "keep\nold\nkeep\n", to: "keep\nnew\nkeep\n")
        XCTAssertEqual(e?.range, NSRange(location: 5, length: 4))
        XCTAssertEqual(e?.text, "new\n")
    }
}
