import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private(set) var controllers: [MainWindowController] = []
    private(set) var isTerminating = false
    private var pendingURLs: [URL] = []
    private var launched = false
    private var settingsWindow: NSWindow?
    private var appearanceObservation: NSKeyValueObservation?
    private var sessionTimer: Timer?
    private var integrationObserver: AnyCancellable?
    private weak var initialEmptyController: MainWindowController?
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
        if !AppRuntime.isRunningTests {
            UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Settings.shared
        _ = RecentFiles.shared.availableItems()
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
        AutoSave.shared.save = { [weak self] doc in
            guard let self, !self.isTerminating else { return }
            let owner = self.controllers.first { $0.window?.isKeyWindow == true && $0.allOpenDocuments().contains { $0 === doc } }
                ?? self.controllers.first { $0.allOpenDocuments().contains { $0 === doc } }
            owner?.save(doc, interactive: false)
        }

        let hasOpenablePending = pendingURLs.contains { $0.isFileURL || AppDelegate.isCommandOpenURL($0) }
        if Settings.shared.restoreSession || Settings.shared.hotExit, let session = SessionStore.shared.load(), !session.windows.isEmpty {
            var windows = session.windows
            if !Settings.shared.restoreSession { windows = SessionStore.hotExitOnlyWindows(from: windows) }
            for w in windows {
                if AppDelegate.skipsAtLaunch(w, openingFiles: hasOpenablePending) {
                    closedWindows.append(w)
                    continue
                }
                let c = makeController()
                c.restore(w)
                c.rootView.layoutSubtreeIfNeeded()
                c.showWindow(nil)
            }
        }
        launched = true
        if !pendingURLs.isEmpty {
            openURLs(pendingURLs)
            pendingURLs = []
        }
        if controllers.isEmpty {
            initialEmptyController = newWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.initialEmptyController = nil }
        }
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

    private static func isCommandOpenURL(_ url: URL) -> Bool {
        url.scheme == "tovri" && url.host == "open"
            && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "req" } == true
    }

    /// Accepts and reads only files the CLI created for this user in its temporary folder using one
    /// non-following descriptor, eliminating TOCTOU races between checking and reading.
    private static func readCLITempFile(_ path: String, prefix: String, maxBytes: Int) -> Data? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        // The CLI writes to `getconf DARWIN_USER_TEMP_DIR`, which is usually the app's own
        // temporary folder too; both are private to this user.
        var tmpDirs = [NSTemporaryDirectory()]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 { tmpDirs.append(String(cString: buffer)) }
        let allowed = Set(tmpDirs.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        guard file.lastPathComponent.hasPrefix(prefix),
              allowed.contains(file.deletingLastPathComponent().resolvingSymlinksInPath().path)
        else { return nil }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_size >= 0,
              info.st_size <= off_t(maxBytes) else { return nil }
        var data = Data(count: Int(info.st_size) + 1)
        var filled = 0
        while true {
            if filled == data.count {
                guard data.count <= maxBytes else { return nil }
                data.count += max(1 << 14, data.count / 4)
            }
            let n = data.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + filled, raw.count - filled, off_t(filled))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            filled += n
        }
        guard filled <= maxBytes else { return nil }
        data.count = filled
        unlink(file.path)
        return data
    }

    /// Line and column numbers from outside are clamped so arithmetic on them can't overflow.
    static func clampedPosition(_ s: String?) -> Int? {
        s.flatMap { Int($0) }.map { min(max($0, 1), 100_000_000) }
    }

    static func decodeStandardInput(_ data: Data) -> (text: String, encoding: TextEncoding) {
        let decoded = TextEncoding.decode(data)
        return (decoded.text, decoded.isBinary ? .utf8 : decoded.encoding)
    }

    private func takeCommandQuery(from url: URL) -> [String: String]? {
        guard url.host == "open", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let reqPath = AppDelegate.unhex(comps.queryItems?.first(where: { $0.name == "req" })?.value),
              let data = AppDelegate.readCLITempFile(reqPath, prefix: "tovri-req.", maxBytes: 1_000_000),
              let body = String(data: data, encoding: .utf8),
              let request = URLComponents(string: "tovri://open?" + body.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        var q: [String: String] = [:]
        for item in request.queryItems ?? [] { q[item.name] = item.value ?? "" }
        return q
    }

    /// Executes a pre-accepted `tovri://open` request. Reading and unlinking the request file up
    /// front keeps a blocking modal alert on an earlier file from timing out later CLI requests.
    private func handleCommandQuery(_ q: [String: String]) {
        let wantsNewWindow = q["new"] == "1"
        let wait = q["wait"]
        func target() -> MainWindowController {
            if wantsNewWindow {
                if controllers.count == 1, let cold = initialEmptyController, cold.isEmptyWindow {
                    initialEmptyController = nil
                    return cold
                }
                initialEmptyController = nil
                return newWindow()
            }
            initialEmptyController = nil
            return windowForOpening()
        }
        // A waiter whose request opened no document (a folder, Quick Look, an error) is released
        // right away so `tovri -w` doesn't block forever.
        func finish(_ doc: Document?) {
            guard let wait else { return }
            if let doc { WaitRegistry.shared.register(wait, for: doc) } else { WaitRegistry.shared.release(wait) }
        }
        if let tmp = AppDelegate.unhex(q["stdin"]) {
            guard let data = AppDelegate.readCLITempFile(tmp, prefix: "tovri-stdin.", maxBytes: 512_000_000) else {
                finish(nil)
                return
            }
            let decoded = AppDelegate.decodeStandardInput(data)
            let c = target()
            finish(c.openText(decoded.text, encoding: decoded.encoding))
            c.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let path = AppDelegate.unhex(q["path"]) else {
            if wantsNewWindow { _ = target() }
            finish(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
        if exists && isDir.boolValue {
            if wantsNewWindow {
                if controllers.count == 1, let cold = initialEmptyController, cold.isEmptyWindow {
                    initialEmptyController = nil
                    for g in cold.groups { while !g.tabs.isEmpty { g.removeTab(at: 0) } }
                    cold.setFolder(fileURL)
                    cold.window?.makeKeyAndOrderFront(nil)
                } else {
                    initialEmptyController = nil
                    newWindow(folder: fileURL)
                }
            } else {
                openURLs([fileURL])
            }
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
        if let busy = controllers.first(where: { $0.replaceInFiles.isBusy }) {
            busy.window?.makeKeyAndOrderFront(nil)
            NSSound.beep()
            busy.statusBar.flash("Finish or stop Replace in Files before quitting.")
            return .terminateCancel
        }
        let hotExit = Settings.shared.hotExit
        if !hotExit {
            let unsavedClosed = closedWindows.filter(\.hasUnsavedChanges)
            if !unsavedClosed.isEmpty {
                closedWindows.removeAll(where: \.hasUnsavedChanges)
                for w in unsavedClosed { _ = restoreClosed(w) }
            }
        }
        let allDirty = AppDelegate.quitConfirmationTargets(in: controllers)
        let dirty = hotExit ? allDirty.filter { WaitRegistry.shared.isWaiting(on: $0.document) } : allDirty
        guard !dirty.isEmpty else {
            guard saveSessionBeforeExit() else { return .terminateCancel }
            isTerminating = true
            return .terminateNow
        }
        func next(_ i: Int) {
            guard i < dirty.count else {
                if hotExit {
                    for target in dirty where target.document.isDirty {
                        let d = target.document
                        if let url = d.url, !d.isNewFile, FileManager.default.fileExists(atPath: url.path) {
                            try? d.reload()
                        } else {
                            d.replaceAllContent("")
                        }
                    }
                }
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
            for doc in c.allOpenDocuments() where AutoSave.canSave(doc) && !AutoSave.isComposing(doc) {
                c.save(doc, interactive: false)
            }
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
        if let folder { c.setFolder(folder) } else { c.newTab(nil) }
        c.rootView.layoutSubtreeIfNeeded()
        c.showWindow(nil)
        return c
    }

    /// Runs from windowShouldClose, while failure can still keep every editor alive.
    func saveSessionBeforeClosingWindow(_ c: MainWindowController) -> Bool {
        guard saveSessionBeforeExit() else { return false }
        recordClosedWindow(c.sessionState())
        return true
    }

    func windowControllerDidClose(_ c: MainWindowController) {
        controllers.removeAll { $0 === c }
        if !isTerminating { SessionStore.shared.saveNow(synchronously: false) }
    }

    /// Whether closing this window should skip unsaved-changes prompts (hot exit keeps them).
    func closingKeepsUnsavedChanges(_ c: MainWindowController) -> Bool {
        guard Settings.shared.hotExit && controllers.count == 1 && controllers.first === c else { return false }
        return !c.allOpenDocuments().contains { $0.isDirty && WaitRegistry.shared.isWaiting(on: $0) }
    }

    var canReopenClosedWindow: Bool { !closedWindows.isEmpty }

    func recordClosedWindow(_ session: WindowSession) {
        var s = session
        s.closed = true
        closedWindows = AppDelegate.remembering(closedWindows, closing: s)
    }

    @discardableResult
    private func reopenLastWindowOrCreate() -> MainWindowController {
        guard let s = closedWindows.popLast() else { return newWindow() }
        let c = restoreClosed(s)
        SessionStore.shared.setNeedsSave()
        return c
    }

    @discardableResult
    @objc func reopenClosedWindow(_ sender: Any?) -> MainWindowController? {
        guard let s = closedWindows.popLast() else { NSSound.beep(); return nil }
        let c = restoreClosed(s)
        c.window?.makeKeyAndOrderFront(nil)
        SessionStore.shared.setNeedsSave()
        return c
    }

    private func restoreClosed(_ s: WindowSession) -> MainWindowController {
        let c = makeController()
        c.restore(s)
        if c.groups.allSatisfy({ $0.tabs.isEmpty }) && c.folderURL == nil { c.newTab(nil) }
        c.rootView.layoutSubtreeIfNeeded()
        c.showWindow(nil)
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
        var queries: [[String: String]] = []
        var sawUnrecognizedCommand = false
        for url in urls where url.scheme == "tovri" {
            if let q = takeCommandQuery(from: url) { queries.append(q) } else { sawUnrecognizedCommand = true }
        }
        if sawUnrecognizedCommand && queries.isEmpty { NSApp.activate(ignoringOtherApps: true) }
        for q in queries { handleCommandQuery(q) }
        for url in urls where url.isFileURL {
            initialEmptyController = nil
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let c = activeController, c.isEmptyWindow || c.folderURL == nil {
                    if c.isEmptyWindow {
                        for g in c.groups { while !g.tabs.isEmpty { g.removeTab(at: 0) } }
                    }
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
        guard !(NSApp.keyWindow?.windowController is MainWindowController) else { return }
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reopenClosedWindow(_:)) { return canReopenClosedWindow }
        if menuItem.action == #selector(clearRecent(_:)) { return !RecentFiles.shared.paths.isEmpty }
        return true
    }

    // MARK: Recent menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let items = RecentFiles.shared.availableItems()
        for url in items {
            let item = NSMenuItem(title: (url.path as NSString).abbreviatingWithTildeInPath, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            let icon = NSImage(systemSymbolName: url.hasDirectoryPath ? "folder" : "doc", accessibilityDescription: nil)
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
