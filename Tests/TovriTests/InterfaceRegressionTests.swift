import AppKit
import XCTest
@testable import Tovri

final class InterfaceRegressionTests: XCTestCase {
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

    private func click(_ view: NSView, at point: NSPoint) {
        let p = view.convert(point, to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                       windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: event)
    }

    func testClicksInsideAnOverlayPanelDoNotCloseIt() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let backdrop = PaletteBackdrop(frame: window.contentView!.bounds)
        window.contentView!.addSubview(backdrop)
        let panel = FlippedView(frame: NSRect(x: 50, y: 50, width: 200, height: 100))
        backdrop.addSubview(panel)
        var closed = 0
        backdrop.onClick = { closed += 1 }
        click(backdrop, at: NSPoint(x: 60, y: 60))
        XCTAssertEqual(closed, 0, "a click on the panel's padding closed it")
        click(backdrop, at: NSPoint(x: 10, y: 10))
        XCTAssertEqual(closed, 1)

        var resized = 0
        backdrop.onResize = { resized += 1 }
        backdrop.setFrameSize(NSSize(width: 500, height: 300))
        XCTAssertEqual(resized, 1)
    }

    func testCommandPaletteListsEachCommandOnceAndOnlyWhenItWorks() throws {
        let previous = NSApp.mainMenu
        NSApp.mainMenu = MainMenu.build(recentMenu: NSMenu())
        defer { NSApp.mainMenu = previous }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-palette-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "one\ntwo\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        withController { controller in
            _ = controller.open(url: dir.appendingPathComponent("a.txt"))
            controller.rootView.layoutSubtreeIfNeeded()
            var titles = controller.paletteCommands().map(\.title)
            XCTAssertEqual(titles.filter { $0.hasSuffix(": Python") }, ["Set Syntax: Python"])
            XCTAssertFalse(titles.contains("File: Close Folder"), "listed with no folder open")
            XCTAssertFalse(titles.contains("File: Close Other Tabs"), "listed with one tab")
            XCTAssertTrue(titles.contains("Edit: Line: Duplicate Line") || titles.contains("Edit: Duplicate Line"), "editor commands missing: \(titles.filter { $0.hasPrefix("Edit") })")
            controller.setFolder(dir)
            titles = controller.paletteCommands().map(\.title)
            XCTAssertTrue(titles.contains("File: Close Folder"))
        }
    }
}
