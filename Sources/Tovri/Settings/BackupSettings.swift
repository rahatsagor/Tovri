import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Export and import of a settings file, driven from the Backup pane.
enum SettingsTransfer {
    private static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    static func summary(_ b: SettingsBackup, themes: Int? = nil) -> String {
        "\(plural(b.settings.count, "changed setting")), \(plural(b.keyBindings.count, "key binding")) and \(plural(themes ?? b.themes.count, "custom theme"))"
    }

    private static func showError(_ message: String, _ detail: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func export(from window: NSWindow?, done: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Tovri Settings.json"
        panel.canCreateDirectories = true
        panel.message = "Your preferences, key bindings and custom themes are saved to this file."
        func finish(_ response: NSApplication.ModalResponse) {
            guard response == .OK, let url = panel.url else { return }
            let backup = SettingsBackup.make(from: .standard, themes: ThemeManager.shared.customThemes.map(\.definition))
            do {
                try backup.encoded().write(to: url, options: .atomic)
                done("Exported \(summary(backup)) to “\(url.lastPathComponent)”.")
            } catch {
                showError("Tovri couldn't export your settings.", error.localizedDescription, in: window)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    static func importFile(from window: NSWindow?, done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a settings file made with Export Settings."
        func finish(_ response: NSApplication.ModalResponse) {
            guard response == .OK, let url = panel.url else { return }
            let backup: SettingsBackup
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= SettingsBackup.maxFileSize else { throw SettingsBackup.Failure.tooLarge }
                backup = try SettingsBackup.decode(Data(contentsOf: url))
            } catch {
                showError("Tovri couldn't import these settings.", error.localizedDescription, in: window)
                return
            }
            // Let the open panel's sheet finish closing before the confirmation sheet appears.
            DispatchQueue.main.async { confirm(backup, from: url, in: window, done: done) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private static func confirm(_ backup: SettingsBackup, from url: URL, in window: NSWindow?, done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Replace your settings with the ones in “\(url.lastPathComponent)”?"
        var info = "Your preferences and key bindings are replaced with the file's. Settings it doesn't include go back to their defaults."
        if !backup.themes.isEmpty {
            info += "\n\nIts \(plural(backup.themes.count, "custom theme")) are added, replacing your themes with the same names."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        func finish(_ response: NSApplication.ModalResponse) {
            guard response == .alertFirstButtonReturn else { return }
            done(apply(backup))
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// Themes go first so settings that choose an imported theme find it.
    @discardableResult
    static func apply(_ backup: SettingsBackup, defaults: UserDefaults = .standard, themes tm: ThemeManager = .shared) -> String {
        var saved = 0, failed = 0, reserved = 0
        for t in backup.themes {
            if tm.isBuiltIn(t.name) { reserved += 1; continue }
            do { try tm.store.save(t); saved += 1 } catch { failed += 1 }
        }
        tm.reloadCustomThemes()
        backup.apply(to: defaults)
        KeyBindings.shared.reloadFromDefaults()
        var message = "Imported \(summary(backup, themes: saved))."
        if reserved > 0 { message += " Skipped \(plural(reserved, "theme")) with the name of a built-in theme." }
        if failed > 0 { message += " \(plural(failed, "theme")) couldn't be saved." }
        return message
    }
}

struct BackupSettings: View {
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Export…") { SettingsTransfer.export(from: NSApp.keyWindow) { status = $0 } }
                } label: {
                    Text("Export settings")
                    Text("Saves your preferences, key bindings and custom themes to a file. Keep it as a backup or use it on another Mac.")
                }
                LabeledContent {
                    Button("Import…") { SettingsTransfer.importFile(from: NSApp.keyWindow) { status = $0 } }
                } label: {
                    Text("Import settings")
                    Text("Replaces your preferences and key bindings with the ones in a settings file, and adds its themes.")
                }
            } footer: {
                Text("Open windows, tabs, unsaved changes and recent files aren't part of a settings file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let status {
                Section {
                    Label(status, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
