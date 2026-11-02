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
        add("Appearance", "paintpalette", AppearanceSettings(), height: 700)
        add("Editor", "text.cursor", EditorSettings(), height: 720)
        add("Files", "folder", FilesSettings(), height: 740)
        add("Git", "arrow.triangle.branch", GitSettings(), height: 440)
        add("Key Bindings", "keyboard", KeyBindingsSettings(), height: 600)
        add("Updates", "arrow.triangle.2.circlepath", UpdatesSettings(), height: 300)
        add("Backup", "externaldrive", BackupSettings(), height: 340)
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
    @AppStorage(Settings.Key.fontWeight) private var fontWeight = Settings.FontWeight.regular.rawValue
    @AppStorage(Settings.Key.fontLigatures) private var ligatures = false
    @AppStorage(Settings.Key.lineHeight) private var lineHeight = 1.4
    @AppStorage(Settings.Key.showMinimap) private var minimap = true
    @AppStorage(Settings.Key.showStatusBar) private var statusBar = true

    @ObservedObject private var manager = ThemeManager.shared
    @State private var editing: ThemeEditorSession?
    @State private var deleting: String?
    @State private var deleteError: String?

    private var themes: [Theme] { manager.themes }
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
            customThemesSection
            Section("Font") {
                Picker("Family", selection: $fontName) {
                    Text("SF Mono (System)").tag("")
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                Picker("Weight", selection: $fontWeight) {
                    ForEach(Settings.FontWeight.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Stepper(value: $fontSize, in: 8...36, step: 1) {
                    HStack { Text("Size"); Spacer(); Text("\(Int(fontSize)) pt").foregroundStyle(.secondary) }
                }
                HStack {
                    Text("Line height")
                    Slider(value: $lineHeight, in: 1.0...2.2, step: 0.05)
                    Text(String(format: "%.2f", lineHeight)).monospacedDigit().foregroundStyle(.secondary).frame(width: 38)
                }
                Toggle(isOn: $ligatures) {
                    Text("Use ligatures")
                    Text("In fonts that have them, character pairs such as -> and != are drawn as one symbol.")
                }
            }
            Section("Window") {
                Toggle("Show minimap", isOn: $minimap)
                Toggle("Show status bar", isOn: $statusBar)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { ThemeEditor(session: $0) }
    }

    private var customThemesSection: some View {
        Section {
            ForEach(manager.customThemes, id: \.name) { t in
                HStack(spacing: 10) {
                    ThemeSwatch(theme: t)
                    Text(t.name)
                    Text(t.isDark ? "Dark" : "Light").foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit…") { editing = ThemeEditorSession(definition: t.definition, originalName: t.name) }
                    Button {
                        deleting = t.name
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this theme")
                    .accessibilityLabel("Delete \(t.name)")
                }
            }
            LabeledContent {
                Menu("New Theme…") {
                    Button("Copy of \(manager.current.name)") { editing = .copy(of: manager.current, among: themes) }
                    Divider()
                    ForEach(themes, id: \.name) { t in
                        Button(t.name) { editing = .copy(of: t, among: themes) }
                    }
                }
                .fixedSize()
            } label: {
                Text("Make your own theme")
                Text("Start from any theme and change its colors. Open windows show your changes as you make them.")
            }
            if let deleteError {
                Text(deleteError).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Custom Themes")
        }
        .confirmationDialog("Delete the theme “\(deleting ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { name in
            Button("Delete", role: .destructive) {
                do { try manager.deleteCustomTheme(named: name); deleteError = nil }
                catch { deleteError = "Tovri couldn't delete the theme. \(error.localizedDescription)" }
            }
        } message: { _ in
            Text("Windows using it switch to a built-in theme. This can't be undone.")
        }
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
    @AppStorage(Settings.Key.spellCheckProse) private var spellCheck = true
    @AppStorage(Settings.Key.languageIndentation) private var languageIndentation = ""
    @State private var rulers = Settings.shared.rulersText

    private var languageEntries: [(language: String, indentation: Settings.Indentation)] {
        Settings.parseLanguageIndentation(languageIndentation)
    }

    private func updateLanguages(_ change: (inout [(language: String, indentation: Settings.Indentation)]) -> Void) {
        var entries = languageEntries
        change(&entries)
        languageIndentation = Settings.formatLanguageIndentation(entries)
    }

    private func indentation(_ id: String) -> Binding<Settings.Indentation> {
        Binding(get: { languageEntries.first { $0.language == id }?.indentation ?? Settings.Indentation(tabs: false, width: 4) },
                set: { value in updateLanguages { e in if let i = e.firstIndex(where: { $0.language == id }) { e[i].indentation = value } } })
    }

    var body: some View {
        Form {
            Section("Indentation") {
                Picker("Tab width", selection: $tabWidth) { ForEach([2, 3, 4, 8], id: \.self) { Text("\($0)").tag($0) } }
                Toggle("Indent using spaces", isOn: $insertSpaces)
                Toggle("Detect indentation from file contents", isOn: $detect)
                Toggle("Auto indent", isOn: $autoIndent)
            }
            languagesSection
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
                LabeledContent {
                    TextField("Vertical rulers", text: $rulers, prompt: Text("None"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .onChange(of: rulers) { _, new in Settings.shared.rulersText = new }
                } label: {
                    Text("Vertical rulers")
                    Text("Columns to draw a line at, such as 80, or 80, 120 for two. Leave empty for none.")
                }
            }
            Section("Typing") {
                Toggle("Auto close brackets and quotes", isOn: $autoClose)
                Toggle("Show completions while typing", isOn: $autoComplete)
                Toggle("Check spelling in Markdown and plain text", isOn: $spellCheck)
            }
        }
        .formStyle(.grouped)
        .onAppear { rulers = Settings.shared.rulersText }
    }

    private var languagesSection: some View {
        Section {
            ForEach(languageEntries.map { $0.language }, id: \.self) { id in
                let value = indentation(id)
                HStack {
                    Text(LanguageRegistry.shared.language(id: id)?.name ?? id)
                    Spacer()
                    Picker("Indent using", selection: value.tabs) {
                        Text("Spaces").tag(false)
                        Text("Tabs").tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Stepper(value: value.width, in: 1...16) {
                        Text("Width \(value.wrappedValue.width)").monospacedDigit()
                    }
                    .fixedSize()
                    Button {
                        updateLanguages { e in e.removeAll { $0.language == id } }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Use the usual indentation for this language")
                    .accessibilityLabel("Remove \(LanguageRegistry.shared.language(id: id)?.name ?? id)")
                }
            }
            LabeledContent {
                Menu("Add Language…") {
                    let used = Set(languageEntries.map { $0.language })
                    ForEach(LanguageRegistry.shared.all.filter { !used.contains($0.id) }, id: \.id) { lang in
                        Button(lang.name) {
                            updateLanguages { e in
                                e.append((lang.id, Settings.Indentation(tabs: !insertSpaces, width: tabWidth)))
                            }
                        }
                    }
                }
                .fixedSize()
            } label: {
                Text("Indentation for a language")
                Text("Used instead of the indentation found in the file. A project's .editorconfig still comes first.")
            }
        } header: {
            Text("Languages")
        }
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
    @AppStorage(Settings.Key.autoSaveDelay) private var autoSaveDelay = 0
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
                Picker(selection: $autoSaveDelay) {
                    Text("Off").tag(0)
                    ForEach(([1, 5, 30] + ([0, 1, 5, 30].contains(autoSaveDelay) ? [] : [autoSaveDelay])).sorted(), id: \.self) { s in
                        Text(s == 1 ? "After 1 second" : "After \(s) seconds").tag(s)
                    }
                } label: {
                    Text("Save changes automatically")
                    Text("Saves files that are already on disk once you stop typing. New files still need Save.")
                }
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
