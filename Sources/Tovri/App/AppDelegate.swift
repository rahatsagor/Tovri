import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var controllers: [MainWindowController] = []
    private(set) var isTerminating = false
    private var pendingURLs: [URL] = []
    private var launched = false
    private var settingsWindow: NSWindow?
    private var appearanceObservation: NSKeyValueObservation?
    private var sessionTimer: Timer?
    private var integrationObserver: AnyCancellable?
    /// Windows closed with the close button, oldest first, so reopening (or the next launch)
    /// brings back their tabs and unsaved buffers the way Sublime Text does.
    private var closedWindows: [WindowSession] = []
    let recentMenu = NSMenu(title: "Open Recent")

    var activeController: MainWindowController? {
        (NSApp.keyWindow?.windowController as? MainWindowController)
            ?? (NSApp.mainWindow?.windowController as? MainWindowController)
            ?? controllers.last
    }

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        recentMenu.delegate = self
        let menu = MainMenu.build(recentMenu: recentMenu)
        KeyBindings.shared.install(on: menu)
        NSApp.mainMenu = menu
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Settings.shared
        ThemeManager.shared.refresh()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async { ThemeManager.shared.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .themeListDidChange, object: nil, queue: .main) { _ in
            MainMenu.rebuildThemeItems()
        }

        SessionStore.shared.stateProvider = { [weak self] in
            guard let self else { return [] }
            return AppDelegate.sessionWindows(open: self.controllers.map { $0.sessionState() }, closed: self.closedWindows)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(documentChangedOnDisk(_:)), name: .documentFileDidChangeOnDisk, object: nil)

        if Settings.shared.restoreSession || Settings.shared.hotExit, let session = SessionStore.shared.load(), !session.windows.isEmpty {
            for w in session.windows {
                if AppDelegate.skipsAtLaunch(w, openingFiles: !pendingURLs.isEmpty) {
                    closedWindows.append(w)
                    continue
                }
                let c = makeController()
                c.restore(w)
                c.showWindow(nil)
            }
        }
        launched = true
        if !pendingURLs.isEmpty {
            openURLs(pendingURLs)
            pendingURLs = []
        }
        if controllers.isEmpty { newWindow() }
        for c in controllers where c.groups.allSatisfy({ $0.tabs.isEmpty }) && c.folderURL == nil { c.newTab(nil) }
        NSApp.activate(ignoringOtherApps: true)

        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, !self.isTerminating else { return }
            SessionStore.shared.saveNow(synchronously: false)
        }
        RunLoop.main.add(t, forMode: .common)
        sessionTimer = t
        Perf.startStallDetector()
        Updater.shared.start()
        integrationObserver = Integration.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIntegrationMenuItems() }
        }
        updateIntegrationMenuItems()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Integration.shared.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Integration.shared.refresh() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { openURLs(urls) } else { pendingURLs.append(contentsOf: urls) }
    }

    // MARK: Command line (tovri:// URLs)

    private static func unhex(_ s: String?) -> String? {
        guard let s, s.count % 2 == 0, !s.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Accepts only files the CLI created for this user in its temporary folder: any web page or
    /// app can fire a tovri:// URL, but it can't plant such a file.
    private static func cliTempFile(_ path: String, prefix: String) -> URL? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        guard file.lastPathComponent.hasPrefix(prefix),
              file.deletingLastPathComponent().resolvingSymlinksInPath().path == tmpDir,
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        else { return nil }
        return file
    }

    /// Line and column numbers from outside are clamped so arithmetic on them can't overflow.
    static func clampedPosition(_ s: String?) -> Int? {
        s.flatMap { Int($0) }.map { min(max($0, 1), 100_000_000) }
    }

    /// Handles `tovri://open?req=<hex path>`. The request file holds the CLI's query
    /// (`path=<hex>&line=&col=&new=1&wait=<id>&stdin=<hex>`); any other tovri:// URL only
    /// brings Tovri to the front.
    private func handleCommandURL(_ url: URL) {
        guard url.host == "open", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let reqPath = AppDelegate.unhex(comps.queryItems?.first(where: { $0.name == "req" })?.value),
              let reqFile = AppDelegate.cliTempFile(reqPath, prefix: "tovri-req."),
              let body = try? String(contentsOf: reqFile, encoding: .utf8),
              let request = URLComponents(string: "tovri://open?" + body.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        try? FileManager.default.removeItem(at: reqFile)
        var q: [String: String] = [:]
        for item in request.queryItems ?? [] { q[item.name] = item.value ?? "" }
        let wantsNewWindow = q["new"] == "1"
        let wait = q["wait"]
        func target() -> MainWindowController {
            if wantsNewWindow { return newWindow() }
            return windowForOpening()
        }
        // A waiter whose request opened no document (a folder, Quick Look, an error) is released
        // right away so `tovri -w` doesn't block forever.
        func finish(_ doc: Document?) {
            guard let wait else { return }
            if let doc { WaitRegistry.shared.register(wait, for: doc) } else { WaitRegistry.shared.release(wait) }
        }
        if let tmp = AppDelegate.unhex(q["stdin"]) {
            guard let file = AppDelegate.cliTempFile(tmp, prefix: "tovri-stdin.") else { finish(nil); return }
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) ?? ""
            try? FileManager.default.removeItem(at: file)
            let c = target()
            finish(c.openText(text))
            c.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let path = AppDelegate.unhex(q["path"]) else {
            if wantsNewWindow { newWindow() }
            finish(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
        if exists && isDir.boolValue {
            if wantsNewWindow { newWindow(folder: fileURL) } else { openURLs([fileURL]) }
            finish(nil)
        } else {
            let c = target()
            let doc = exists
                ? c.open(url: fileURL, line: AppDelegate.clampedPosition(q["line"]), column: AppDelegate.clampedPosition(q["col"]))
                : c.openNewFile(at: fileURL)
            finish(doc)
            c.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let c = controllers.first { c.showWindow(nil) } else { reopenLastWindowOrCreate() }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Settings.shared.quitWhenLastWindowCloses
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Settings.shared.hotExit {
            guard saveSessionBeforeExit() else { return .terminateCancel }
            isTerminating = true
            return .terminateNow
        }
        let dirty = AppDelegate.quitConfirmationTargets(in: controllers)
        guard !dirty.isEmpty else {
            guard saveSessionBeforeExit() else { return .terminateCancel }
            isTerminating = true
            return .terminateNow
        }
        func next(_ i: Int) {
            guard i < dirty.count else {
                guard saveSessionBeforeExit() else {
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
                isTerminating = true
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            let target = dirty[i]
            target.controller.window?.makeKeyAndOrderFront(nil)
            target.controller.confirmClose([target.document]) { ok in
                if ok { next(i + 1) } else { NSApp.reply(toApplicationShouldTerminate: false) }
            }
        }
        next(0)
        return .terminateLater
    }

    /// Window-close rules may skip a shared document, but quitting must ask about it once.
    static func quitConfirmationTargets(in controllers: [MainWindowController]) -> [(controller: MainWindowController, document: Document)] {
        var seen = Set<ObjectIdentifier>()
        return controllers.flatMap { controller in
            controller.allOpenDocuments().compactMap { doc in
                guard doc.isDirty, seen.insert(ObjectIdentifier(doc)).inserted else { return nil }
                return (controller: controller, document: doc)
            }
        }
    }

    private func saveSessionBeforeExit() -> Bool {
        switch SessionStore.shared.saveNow(synchronously: true) {
        case .success:
            return true
        case .failure(let error):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Tovri couldn’t save your session."
            alert.informativeText = "Your windows will stay open to protect unsaved changes. Save your files or resolve the storage problem, then try again.\n\n" + error.localizedDescription
            alert.addButton(withTitle: "OK")
            if let window = activeController?.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionTimer?.invalidate()
        WaitRegistry.shared.releaseAll()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard Settings.shared.saveOnFocusLost else { return }
        for c in controllers {
            for doc in c.allOpenDocuments() where doc.isDirty && doc.url != nil && !doc.isTransient { c.save(doc, interactive: false) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        activeController?.checkExternalChanges()
    }

    // MARK: Windows

    private func makeController() -> MainWindowController {
        let c = MainWindowController()
        if let last = controllers.last?.window {
            c.window?.setFrame(last.frame, display: false)
            c.window?.setFrameTopLeftPoint(last.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        controllers.append(c)
        return c
    }

    @discardableResult
    func newWindow(folder: URL? = nil) -> MainWindowController {
        let c = makeController()
        if let folder { c.setFolder(folder) }
        c.showWindow(nil)
        if folder == nil { c.newTab(nil) }
        return c
    }

    /// Runs from windowShouldClose, while failure can still keep every editor alive.
    func saveSessionBeforeClosingWindow(_ c: MainWindowController) -> Bool {
        guard saveSessionBeforeExit() else { return false }
        var s = c.sessionState()
        s.closed = true
        closedWindows = AppDelegate.remembering(closedWindows, closing: s)
        return true
    }

    func windowControllerDidClose(_ c: MainWindowController) {
        controllers.removeAll { $0 === c }
        if !isTerminating { SessionStore.shared.saveNow(synchronously: false) }
    }

    /// Whether closing this window should skip unsaved-changes prompts (hot exit keeps them).
    func closingKeepsUnsavedChanges(_ c: MainWindowController) -> Bool {
        Settings.shared.hotExit && controllers.count == 1 && controllers.first === c
    }

    @discardableResult
    private func reopenLastWindowOrCreate() -> MainWindowController {
        guard let s = closedWindows.popLast() else { return newWindow() }
        return restoreClosed(s)
    }

    private func restoreClosed(_ s: WindowSession) -> MainWindowController {
        let c = makeController()
        c.restore(s)
        c.showWindow(nil)
        if c.groups.allSatisfy({ $0.tabs.isEmpty }) && c.folderURL == nil { c.newTab(nil) }
        return c
    }

    /// The window for a file opened from Finder or the command line. With no window open, a
    /// closed one comes back only when it holds unsaved changes; otherwise a single file gets a
    /// fresh window instead of reopening the folder that was closed.
    private func windowForOpening() -> MainWindowController {
        if let c = activeController { return c }
        if let i = closedWindows.lastIndex(where: \.hasUnsavedChanges) { return restoreClosed(closedWindows.remove(at: i)) }
        closedWindows.removeAll()
        return newWindow()
    }

    /// Closing a window forgets earlier closed windows unless they hold unsaved changes, which
    /// must survive until they are reopened.
    static func remembering(_ closed: [WindowSession], closing s: WindowSession) -> [WindowSession] {
        closed.filter(\.hasUnsavedChanges) + [s]
    }

    /// Launching Tovri to open files skips a window that was closed before quitting, by the
    /// same rule as opening a file while Tovri runs with no window.
    static func skipsAtLaunch(_ w: WindowSession, openingFiles: Bool) -> Bool {
        openingFiles && w.closed == true && !w.hasUnsavedChanges
    }

    /// The windows to save: closed windows while no other window is open, and those with unsaved
    /// changes always, so opening another window can't drop them.
    static func sessionWindows(open: [WindowSession], closed: [WindowSession]) -> [WindowSession] {
        open.isEmpty ? closed : open + closed.filter(\.hasUnsavedChanges)
    }

    @objc private func documentChangedOnDisk(_ n: Notification) {
        guard let doc = n.object as? Document else { return }
        let owner = controllers.first { $0.window?.isKeyWindow == true && $0.allOpenDocuments().contains { $0 === doc } }
            ?? controllers.first { $0.allOpenDocuments().contains { $0 === doc } }
        owner?.handleDiskChange(doc)
    }

    func openURLs(_ urls: [URL]) {
        for url in urls where url.scheme == "tovri" { handleCommandURL(url) }
        for url in urls where url.isFileURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let c = activeController, c.isEmptyWindow || c.folderURL == nil {
                    c.setFolder(url)
                    c.window?.makeKeyAndOrderFront(nil)
                } else {
                    newWindow(folder: url)
                }
            } else {
                let c = windowForOpening()
                c.open(url: url)
                c.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: Actions

    @objc func newDocument(_ sender: Any?) {
        if let c = activeController {
            c.newTab(nil)
            c.window?.makeKeyAndOrderFront(nil)
            return
        }
        let c = windowForOpening()
        // A fresh window already has its empty tab; a reopened one with unsaved changes needs one.
        if !c.isEmptyWindow { c.newTab(nil) }
        c.window?.makeKeyAndOrderFront(nil)
    }

    @objc func newWindowAction(_ sender: Any?) { newWindow() }

    /// ⌘W in auxiliary windows (Settings, About) closes the window.
    @objc func closeTabCommand(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.directoryURL = activeController?.activeDocument?.url?.deletingLastPathComponent() ?? activeController?.folderURL
        guard panel.runModal() == .OK else { return }
        openURLs(panel.urls)
    }

    @objc func openFolderAction(_ sender: Any?) {
        openFolderPanel(for: activeController)
    }

    func openFolderPanel(for controller: MainWindowController?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let c = controller {
            c.openFolder(url)
            c.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow(folder: url)
        }
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openURLs([url])
    }

    @objc func clearRecent(_ sender: Any?) { RecentFiles.shared.clear() }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindow.make() }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// The copyright and license line comes from NSHumanReadableCopyright in Info.plist.
    @objc func showAbout(_ sender: Any?) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]
        let credits = NSMutableAttributedString(string: "A fast, native code editor for macOS, built for Apple silicon.\nFree and open source.\n\n", attributes: style)
        var link = style
        link[.link] = ProjectLinks.repository
        credits.append(NSAttributedString(string: "github.com/rahatsagor/Tovri", attributes: link))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "Tovri"])
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        let integration = Integration.shared
        integration.refreshCommandLine()
        if integration.commandLinePath == nil { integration.installCommandLine() } else { integration.uninstallCommandLine() }
    }

    @objc func makeDefaultEditor(_ sender: Any?) { Integration.shared.makeDefaultEditor() }

    @objc func openProjectLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Hidden menu items aren't validated, so these follow the integration state directly.
    private func updateIntegrationMenuItems() {
        let integration = Integration.shared
        func items(_ action: Selector, in menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { ($0.action == action ? [$0] : []) + items(action, in: $0.submenu) }
        }
        for item in items(#selector(installCommandLineTool(_:)), in: NSApp.mainMenu) {
            item.title = integration.commandLinePath == nil ? "Install “tovri” Command…" : "Uninstall “tovri” Command…"
        }
        for item in items(#selector(makeDefaultEditor(_:)), in: NSApp.mainMenu) {
            item.isHidden = integration.isDefaultEditor
        }
    }

    // MARK: Recent menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let items = RecentFiles.shared.items.filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in items {
            let item = NSMenuItem(title: (url.path as NSString).abbreviatingWithTildeInPath, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let icon = NSImage(systemSymbolName: isDir.boolValue ? "folder" : "doc", accessibilityDescription: nil)
            icon?.size = NSSize(width: 14, height: 14)
            item.image = icon
            menu.addItem(item)
        }
        if items.isEmpty {
            let none = NSMenuItem(title: "No Recent Items", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }
}
