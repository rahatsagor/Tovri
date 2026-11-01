import SwiftUI

import AppKit

/// Native toolbar-style settings window hosting SwiftUI panes.
enum SettingsWindow {
    static func make() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func add<V: View>(_ title: String, _ symbol: String, _ view: V, height: CGFloat) {
            let vc = NSHostingController(rootView: view.frame(width: 620, height: height))
            vc.sizingOptions = []
            vc.preferredContentSize = NSSize(width: 620, height: height)
            vc.title = title
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("Appearance", "paintpalette", AppearanceSettings(), height: 500)
        add("Editor", "text.cursor", EditorSettings(), height: 672)
        add("Files", "folder", FilesSettings(), height: 712)
        add("Git", "arrow.triangle.branch", GitSettings(), height: 440)
        add("Key Bindings", "keyboard", KeyBindingsSettings(), height: 600)
        add("Updates", "arrow.triangle.2.circlepath", UpdatesSettings(), height: 300)
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }
}

struct AppearanceSettings: View {
    @AppStorage(Settings.Key.theme) private var theme = "Tovri Dark"
    @AppStorage(Settings.Key.followSystemAppearance) private var follow = false
    @AppStorage(Settings.Key.lightTheme) private var lightTheme = "Tovri Day"
    @AppStorage(Settings.Key.darkTheme) private var darkTheme = "Tovri Dark"
    @AppStorage(Settings.Key.fontName) private var fontName = ""
    @AppStorage(Settings.Key.fontSize) private var fontSize = 13.0
    @AppStorage(Settings.Key.lineHeight) private var lineHeight = 1.4
    @AppStorage(Settings.Key.showMinimap) private var minimap = true
    @AppStorage(Settings.Key.showStatusBar) private var statusBar = true

    private let themes = ThemeManager.shared.themes
    private let fonts = Settings.monospacedFontFamilies()

    var body: some View {
        Form {
            Section("Theme") {
                Toggle("Match system appearance", isOn: $follow)
                if follow {
                    Picker("Light theme", selection: $lightTheme) { ForEach(themes.filter { !$0.isDark }, id: \.name) { Text($0.name).tag($0.name) } }
                    Picker("Dark theme", selection: $darkTheme) { ForEach(themes.filter { $0.isDark }, id: \.name) { Text($0.name).tag($0.name) } }
                } else {
                    Picker("Theme", selection: $theme) {
                        ForEach(themes, id: \.name) { t in Text(t.name).tag(t.name) }
                    }
                }
            }
            Section("Font") {
                Picker("Family", selection: $fontName) {
                    Text("SF Mono (System)").tag("")
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $fontSize, in: 8...36, step: 1) {
                    HStack { Text("Size"); Spacer(); Text("\(Int(fontSize)) pt").foregroundStyle(.secondary) }
                }
                HStack {
                    Text("Line height")
                    Slider(value: $lineHeight, in: 1.0...2.2, step: 0.05)
                    Text(String(format: "%.2f", lineHeight)).monospacedDigit().foregroundStyle(.secondary).frame(width: 38)
                }
            }
            Section("Window") {
                Toggle("Show minimap", isOn: $minimap)
                Toggle("Show status bar", isOn: $statusBar)
            }
        }
        .formStyle(.grouped)
    }
}

struct EditorSettings: View {
    @AppStorage(Settings.Key.tabWidth) private var tabWidth = 4
    @AppStorage(Settings.Key.insertSpaces) private var insertSpaces = true
    @AppStorage(Settings.Key.detectIndentation) private var detect = true
    @AppStorage(Settings.Key.wordWrap) private var wordWrap = false
    @AppStorage(Settings.Key.showLineNumbers) private var lineNumbers = true
    @AppStorage(Settings.Key.highlightCurrentLine) private var currentLine = true
    @AppStorage(Settings.Key.showIndentGuides) private var guides = true
    @AppStorage(Settings.Key.showInvisibles) private var invisibles = false
    @AppStorage(Settings.Key.autoCloseBrackets) private var autoClose = true
    @AppStorage(Settings.Key.autoIndent) private var autoIndent = true
    @AppStorage(Settings.Key.autoComplete) private var autoComplete = true
    @AppStorage(Settings.Key.scrollPastEnd) private var scrollPastEnd = true
    @AppStorage(Settings.Key.highlightBrackets) private var brackets = true
    @AppStorage(Settings.Key.highlightOccurrences) private var occurrences = true
    @AppStorage(Settings.Key.rulerColumn) private var ruler = 0
    @AppStorage(Settings.Key.spellCheckProse) private var spellCheck = true

    var body: some View {
        Form {
            Section("Indentation") {
                Picker("Tab width", selection: $tabWidth) { ForEach([2, 3, 4, 8], id: \.self) { Text("\($0)").tag($0) } }
                Toggle("Indent using spaces", isOn: $insertSpaces)
                Toggle("Detect indentation from file contents", isOn: $detect)
                Toggle("Auto indent", isOn: $autoIndent)
            }
            Section("Display") {
                Toggle("Word wrap", isOn: $wordWrap)
                Toggle("Line numbers", isOn: $lineNumbers)
                Toggle("Highlight current line", isOn: $currentLine)
                Toggle("Indent guides", isOn: $guides)
                Toggle("Invisible characters", isOn: $invisibles)
                Toggle("Highlight matching brackets", isOn: $brackets)
                Toggle("Highlight occurrences of selection", isOn: $occurrences)
                Toggle("Scroll past end", isOn: $scrollPastEnd)
                    .help("Adds space below the last line only when the file is taller than the editor.")
                Picker("Vertical ruler", selection: $ruler) {
                    Text("None").tag(0)
                    ForEach([72, 80, 100, 120], id: \.self) { Text("Column \($0)").tag($0) }
                }
            }
            Section("Typing") {
                Toggle("Auto close brackets and quotes", isOn: $autoClose)
                Toggle("Show completions while typing", isOn: $autoComplete)
                Toggle("Check spelling in Markdown and plain text", isOn: $spellCheck)
            }
        }
        .formStyle(.grouped)
    }
}

struct GitSettings: View {
    @AppStorage(Settings.Key.gitEnabled) private var enabled = true
    @AppStorage(Settings.Key.gitGutter) private var gutter = true
    @AppStorage(Settings.Key.gitSidebarStatus) private var sidebar = true
    @AppStorage(Settings.Key.gitStatusBarChanges) private var statusBar = true
    @AppStorage(Settings.Key.gitChangesAndHistory) private var history = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Text("Use Git")
                    Text("When off, Tovri never runs git or reads .git folders, and every Git feature below is gone.")
                }
            }
            Section("Features") {
                Toggle(isOn: $gutter) {
                    Text("Changes in the editor")
                    Text("Gutter markers, the change card, Revert Change and Compare with Last Commit. Loads the committed copy of each open file.")
                }
                Toggle(isOn: $sidebar) {
                    Text("File status in the sidebar")
                    Text("Colors changed files and dims ignored ones.")
                }
                Toggle(isOn: $statusBar) {
                    Text("Changed files in the status bar")
                    Text("Shows how many files have uncommitted changes. Click it to list them.")
                }
            }
            .disabled(!enabled)
            Section("More") {
                Toggle(isOn: $history) {
                    Text("Changes and file history")
                    Text("A Changes list in the sidebar, and File History (⇧⌥⌘H) to compare a file with any earlier commit. Runs git only while you use them.")
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
    }
}

struct FilesSettings: View {
    @AppStorage(Settings.Key.hotExit) private var hotExit = true
    @AppStorage(Settings.Key.restoreSession) private var restore = true
    @AppStorage(Settings.Key.trimTrailingWhitespace) private var trim = false
    @AppStorage(Settings.Key.ensureNewlineAtEOF) private var newline = false
    @AppStorage(Settings.Key.saveOnFocusLost) private var saveOnFocusLost = false
    @AppStorage(Settings.Key.showHiddenFiles) private var hidden = true
    @AppStorage(Settings.Key.hiddenPatterns) private var hiddenPatterns = ".git .svn .hg .DS_Store"
    @AppStorage(Settings.Key.searchExcludes) private var excludes = ""
    @AppStorage(Settings.Key.quitWhenLastWindowCloses) private var quitOnLastClose = false
    @AppStorage(Settings.Key.revealActiveFile) private var revealActive = true
    @AppStorage(Settings.Key.markdownPreviewOnOpen) private var markdownPreview = false
    @AppStorage(Settings.Key.markdownRemoteContent) private var remoteContent = false
    @ObservedObject private var integration = Integration.shared

    private var defaultEditorStatus: String {
        guard let s = integration.defaultEditorTypes else { return "Checking…" }
        if s.claimed == s.total { return "Finder opens code and config files in Tovri" }
        if s.claimed == 0 { return "Finder opens code files in other apps" }
        return "Finder opens \(s.claimed) of \(s.total) code file types in Tovri"
    }

    var body: some View {
        Form {
            Section("Session") {
                Toggle("Restore windows and tabs on launch", isOn: $restore)
                Toggle("Hot exit (keep unsaved changes between launches)", isOn: $hotExit)
                Toggle("Quit when the last tab or window closes", isOn: $quitOnLastClose)
            }
            Section("Opening") {
                Toggle("Open Markdown files in preview mode", isOn: $markdownPreview)
                Toggle("Load remote images in Markdown previews", isOn: $remoteContent)
                    .help("Remote images let the sender see when and where a document was opened. When off, the preview offers to load them for one document.")
                LabeledContent {
                    if integration.commandLinePath == nil {
                        Button("Install…") { integration.installCommandLine() }
                    } else {
                        Button("Uninstall…") { integration.uninstallCommandLine() }
                    }
                } label: {
                    Text("“tovri” command")
                    Text(integration.commandLinePath.map { "Installed at \($0)" } ?? "Open files and folders from Terminal: tovri file.txt:12")
                }
                LabeledContent {
                    if !integration.isDefaultEditor {
                        Button("Make Default…") { integration.makeDefaultEditor() }
                    }
                } label: {
                    Text("Default editor")
                    Text(defaultEditorStatus)
                }
            }
            .onAppear { integration.refresh() }
            Section("Saving") {
                Toggle("Trim trailing whitespace on save", isOn: $trim)
                Toggle("Ensure newline at end of file", isOn: $newline)
                Toggle("Save files when Tovri loses focus", isOn: $saveOnFocusLost)
            }
            Section("Sidebar & Search") {
                Toggle("Reveal the active file in the sidebar", isOn: $revealActive)
                Toggle("Show hidden files", isOn: $hidden)
                TextField("Never show", text: $hiddenPatterns)
                TextField("Exclude from search & Go to File", text: $excludes, axis: .vertical)
                    .lineLimit(2...4)
            }
        }
        .formStyle(.grouped)
    }
}
