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
            for group in controller.groups { for tab in group.tabs { tab.close() } }
            controller.window?.delegate = nil
            controller.window?.close()
        }
        try body(controller)
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
}
