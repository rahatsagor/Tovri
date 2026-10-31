import AppKit
import Combine
import UniformTypeIdentifiers

/// How Tovri is hooked into the system: the `tovri` command and Finder's default apps.
/// Shared by the app menu and Settings so both show the real state.
final class Integration: ObservableObject {
    static let shared = Integration()

    /// Path of a `tovri` link that points at this app's launcher, if one is installed.
    @Published private(set) var commandLinePath: String?
    /// How many of the claimable code file types already open in Tovri; nil until checked.
    @Published private(set) var defaultEditorTypes: (claimed: Int, total: Int)?

    var isDefaultEditor: Bool { defaultEditorTypes.map { $0.total > 0 && $0.claimed == $0.total } ?? false }

    private static let binDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    private var checkingDefaults = false

    private init() { refreshCommandLine() }

    func refresh() {
        refreshCommandLine()
        refreshDefaultEditor()
    }

    // MARK: Command line tool

    private var launcher: URL? { Bundle.main.url(forResource: "tovri", withExtension: nil) }

    /// A link counts when it points at the launcher inside any copy of Tovri (e.g. the one in
    /// /Applications while a development build is running).
    func refreshCommandLine() {
        let ours = Bundle.main.bundleIdentifier
        commandLinePath = Integration.binDirectories.map { $0 + "/tovri" }.first { link in
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil else { return false }
            let target = URL(fileURLWithPath: link).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: target.path) else { return false }
            let app = target.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return target.lastPathComponent == "tovri" && app.pathExtension == "app" && Bundle(url: app)?.bundleIdentifier == ours
        }
    }

    /// Links `tovri` into the first writable bin directory on the usual PATH; no admin rights are
    /// needed when Homebrew's prefix exists. Otherwise copies the one-line sudo command.
    func installCommandLine() {
        guard let script = launcher else { NSSound.beep(); return }
        let fm = FileManager.default
        let alert = NSAlert()
        // A link into a translocated or mounted copy breaks once the disk image is ejected.
        if script.path.contains("/AppTranslocation/") || script.path.hasPrefix("/Volumes/") {
            alert.messageText = "Move Tovri to Applications first"
            alert.informativeText = "Tovri is running from a disk image or a temporary location. Drag it to the Applications folder, open it from there, and install the command again."
            alert.runModal()
            return
        }
        for dir in Integration.binDirectories where fm.isWritableFile(atPath: dir) {
            let link = dir + "/tovri"
            if (try? fm.attributesOfItem(atPath: link)) != nil || (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
                // Only replace a link to some copy of Tovri's launcher; anything else belongs to another tool.
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: link), dest.hasSuffix("/Contents/Resources/tovri") else { continue }
            }
            try? fm.removeItem(atPath: link)
            do {
                try fm.createSymbolicLink(atPath: link, withDestinationPath: script.path)
                refreshCommandLine()
                alert.messageText = "Installed the “tovri” command"
                alert.informativeText = "Linked \(link). Try:\n\ntovri .\ntovri file.txt:12\ngit diff | tovri\ntovri --help"
                alert.runModal()
                return
            } catch { continue }
        }
        let cmd = "sudo mkdir -p /usr/local/bin && sudo ln -sf \(Integration.shellQuoted(script.path)) /usr/local/bin/tovri"
        alert.messageText = "Install the “tovri” command"
        alert.informativeText = "Run this in Terminal (the command is on your clipboard):\n\n\(cmd)"
        copy(cmd)
        alert.runModal()
        refreshCommandLine()
    }

    func uninstallCommandLine() {
        refreshCommandLine()
        guard let link = commandLinePath else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the “tovri” command?"
        alert.informativeText = "This deletes the link at \(link). Tovri itself isn’t affected, and you can install the command again at any time."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.removeItem(atPath: link)
        } catch {
            let cmd = "sudo rm \(Integration.shellQuoted(link))"
            let fail = NSAlert()
            fail.messageText = "Remove the “tovri” command"
            fail.informativeText = "Run this in Terminal (the command is on your clipboard):\n\n\(cmd)"
            copy(cmd)
            fail.runModal()
        }
        refreshCommandLine()
    }

    /// Single quotes keep `$`, backticks and quotes in a path from being run by the shell under sudo.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Default editor

    /// Content types Tovri declares that are reasonable to claim. Broad or non-code types
    /// (any data, HTML, SVG, CSV, plists) keep their current handlers.
    static var defaultEditorContentTypes: [UTType] {
        let skip: Set<String> = ["public.data", "public.text", "public.folder", "public.html", "public.svg-image",
                                 "public.comma-separated-values-text", "public.tab-separated-values-text",
                                 "com.apple.property-list", "public.log"]
        var seen = Set<String>()
        var result: [UTType] = []
        func add(_ t: UTType?) {
            guard let t, !t.isDynamic, !skip.contains(t.identifier), seen.insert(t.identifier).inserted else { return }
            result.append(t)
        }
        let docTypes = Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        for entry in docTypes {
            for id in entry["LSItemContentTypes"] as? [String] ?? [] { add(UTType(id)) }
            for ext in entry["CFBundleTypeExtensions"] as? [String] ?? [] { add(UTType(filenameExtension: ext)) }
        }
        return result
    }

    /// Checks Launch Services off the main thread; any installed copy of Tovri counts.
    func refreshDefaultEditor() {
        guard !checkingDefaults else { return }
        checkingDefaults = true
        let types = Integration.defaultEditorContentTypes
        let ours = Bundle.main.bundleIdentifier
        DispatchQueue.global(qos: .utility).async {
            var cache: [URL: Bool] = [:]
            let claimed = types.filter { t in
                guard let app = NSWorkspace.shared.urlForApplication(toOpen: t) else { return false }
                if let known = cache[app] { return known }
                let mine = Bundle(url: app)?.bundleIdentifier == ours
                cache[app] = mine
                return mine
            }.count
            DispatchQueue.main.async {
                self.checkingDefaults = false
                self.defaultEditorTypes = (claimed, types.count)
            }
        }
    }

    func makeDefaultEditor() {
        let types = Integration.defaultEditorContentTypes
        let alert = NSAlert()
        alert.messageText = "Make Tovri the default editor for code files?"
        alert.informativeText = "Finder will open \(types.count) source code and config file types (Swift, JavaScript, TypeScript, Python, Go, Rust, JSON, YAML, Markdown, shell scripts, plain text and more) in Tovri.\n\nHTML, SVG, CSV and property lists keep their current apps. You can change any file type later with Finder’s Get Info → Open with."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let app = Bundle.main.bundleURL
        let group = DispatchGroup()
        var failures = 0
        let lock = NSLock()
        for t in types {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: t) { error in
                if error != nil { lock.lock(); failures += 1; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.refreshDefaultEditor()
            let done = NSAlert()
            done.messageText = failures == 0 ? "Tovri is now the default editor" : "Tovri is the default for \(types.count - failures) of \(types.count) file types"
            done.informativeText = failures == 0 ? "Code files opened from Finder will open in Tovri." : "macOS declined some types; set them with Finder’s Get Info → Open with."
            done.runModal()
        }
    }
}
