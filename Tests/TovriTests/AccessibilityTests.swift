import AppKit
import XCTest
@testable import Tovri

final class AccessibilityTests: XCTestCase {
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

    func testTabsAreExposedAsSelectableTabButtonsWithCloseButtons() {
        withController { controller in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let group = controller.activeGroup
            group.add(Document(newFileAt: root.appendingPathComponent("first.txt")))
            let edited = Document(newFileAt: root.appendingPathComponent("second.txt"))
            edited.restoreBuffer("unsaved")
            group.add(edited)
            controller.rootView.layoutSubtreeIfNeeded()

            let bar = group.tabBar
            XCTAssertEqual(bar.accessibilityRole(), .tabGroup)
            let tabs = bar.accessibilityTabs() as? [NSAccessibilityElement] ?? []
            XCTAssertEqual(tabs.count, 2)
            XCTAssertEqual(tabs.map { $0.accessibilityRole() }, [.radioButton, .radioButton])
            XCTAssertEqual(tabs.map { $0.accessibilityLabel() }, ["first.txt", "second.txt"])
            XCTAssertEqual(tabs.map { $0.isAccessibilitySelected() }, [false, true])
            XCTAssertTrue(tabs[1].accessibilityHelp()?.contains("Edited") == true)
            XCTAssertFalse(tabs[0].accessibilityHelp()?.contains("Edited") == true)

            let buttons = (bar.accessibilityChildren() as? [NSAccessibilityElement] ?? []).filter { $0.accessibilityRole() == .button }
            XCTAssertEqual(buttons.map { $0.accessibilityLabel() }, ["Close first.txt", "Close second.txt"])

            XCTAssertTrue(tabs[0].accessibilityPerformPress())
            XCTAssertEqual(group.selectedIndex, 0)
            XCTAssertEqual(tabs.map { $0.isAccessibilitySelected() }, [true, false])
            XCTAssertTrue(bar.accessibilityValue() as? NSAccessibilityElement === tabs[0])
        }
    }

    func testStatusBarItemsAreLabeledButtons() {
        withController { controller in
            controller.activeGroup.add(Document())
            controller.updateStatusBar()
            let items = controller.statusBar.accessibilityChildren() as? [NSAccessibilityElement] ?? []
            let labels = items.compactMap { $0.accessibilityLabel() }
            XCTAssertTrue(labels.contains("Line ending: LF"), "\(labels)")
            XCTAssertTrue(labels.contains { $0.hasPrefix("Cursor position: Ln 1, Col 1") }, "\(labels)")
            XCTAssertTrue(labels.contains { $0.hasPrefix("Language: ") }, "\(labels)")
            XCTAssertTrue(items.filter { $0.accessibilityLabel()?.hasPrefix("Git branch") != true }.allSatisfy { $0.accessibilityRole() == .button })
        }
    }

    func testEmptyStateReadsShortcuts() {
        let view = EmptyStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        let values = (view.accessibilityChildren() as? [NSAccessibilityElement] ?? []).compactMap { $0.accessibilityValue() as? String }
        XCTAssertTrue(values.contains("Go to File: Command P"), "\(values)")
        XCTAssertTrue(values.contains("Find in Files: Shift Command F"), "\(values)")
    }

    func testGutterAndMinimapAreHiddenFromAccessibility() {
        XCTAssertFalse(GutterView().isAccessibilityElement())
        XCTAssertFalse(MinimapView().isAccessibilityElement())
    }

    func testSidebarRowReadsGitStatusAndUnsavedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("a.txt"))
        try Data().write(to: root.appendingPathComponent("b.txt"))

        let sidebar = SidebarView()
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.setRoot(root)
        sidebar.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(findOutline(in: sidebar))
        let a = try XCTUnwrap(outline.item(atRow: 0) as? FileNode)
        let b = try XCTUnwrap(outline.item(atRow: 1) as? FileNode)
        sidebar.setGitStatus([a.url.standardizedFileURL.path: .modified, b.url.standardizedFileURL.path: .untracked])
        sidebar.setDirtyPaths([a.url.standardizedFileURL.path])

        let first = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let second = try XCTUnwrap(outline.view(atColumn: 0, row: 1, makeIfNecessary: true))
        XCTAssertTrue(first.isAccessibilityElement())
        XCTAssertEqual(first.accessibilityLabel(), "a.txt, Modified, Unsaved changes")
        XCTAssertEqual(second.accessibilityLabel(), "b.txt, New")
        XCTAssertTrue(first.subviews.allSatisfy { !$0.isAccessibilityElement() })
    }

    private func findOutline(in view: NSView) -> SidebarOutlineView? {
        if let o = view as? SidebarOutlineView { return o }
        for sub in view.subviews { if let o = findOutline(in: sub) { return o } }
        return nil
    }
}
