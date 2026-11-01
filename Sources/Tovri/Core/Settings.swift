import AppKit

/// UserDefaults-backed preferences. SwiftUI's settings window binds to the same keys via
/// `@AppStorage`, so any change (from either side) is broadcast as `.settingsDidChange`.
final class Settings {
    static let shared = Settings()

    enum Key {
        static let theme = "theme"
        static let followSystemAppearance = "followSystemAppearance"
        static let lightTheme = "lightTheme"
        static let darkTheme = "darkTheme"
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let lineHeight = "lineHeight"
        static let tabWidth = "tabWidth"
        static let insertSpaces = "insertSpaces"
        static let detectIndentation = "detectIndentation"
        static let wordWrap = "wordWrap"
        static let showLineNumbers = "showLineNumbers"
        static let showMinimap = "showMinimap"
        static let highlightCurrentLine = "highlightCurrentLine"
        static let showIndentGuides = "showIndentGuides"
        static let showInvisibles = "showInvisibles"
        static let autoCloseBrackets = "autoCloseBrackets"
        static let autoIndent = "autoIndent"
        static let autoComplete = "autoComplete"
        static let scrollPastEnd = "scrollPastEnd"
        static let trimTrailingWhitespace = "trimTrailingWhitespace"
        static let ensureNewlineAtEOF = "ensureNewlineAtEOF"
        static let hotExit = "hotExit"
        static let restoreSession = "restoreSession"
        static let showHiddenFiles = "showHiddenFiles"
        static let hiddenPatterns = "hiddenPatterns"
        static let searchExcludes = "searchExcludes"
        static let highlightBrackets = "highlightBrackets"
        static let highlightOccurrences = "highlightOccurrences"
        static let rulerColumn = "rulerColumn"
        static let showStatusBar = "showStatusBar"
        static let sidebarVisible = "sidebarVisible"
        static let sidebarWidth = "sidebarWidth"
        static let saveOnFocusLost = "saveOnFocusLost"
        static let gitEnabled = "gitEnabled"
        static let gitGutter = "gitGutter"
        static let gitSidebarStatus = "gitSidebarStatus"
        static let gitStatusBarChanges = "gitStatusBarChanges"
        static let gitChangesAndHistory = "gitChangesAndHistory"
        static let quitWhenLastWindowCloses = "quitWhenLastWindowCloses"
        static let revealActiveFile = "revealActiveFile"
        static let markdownPreviewOnOpen = "markdownPreviewOnOpen"
        static let spellCheckProse = "spellCheckProse"
        static let markdownRemoteContent = "markdownRemoteContent"
    }

    static let defaults: [String: Any] = [
        Key.theme: "Tovri Dark",
        Key.followSystemAppearance: false,
        Key.lightTheme: "Tovri Day",
        Key.darkTheme: "Tovri Dark",
        Key.fontName: "",
        Key.fontSize: 13.0,
        Key.lineHeight: 1.4,
        Key.tabWidth: 4,
        Key.insertSpaces: true,
        Key.detectIndentation: true,
        Key.wordWrap: false,
        Key.showLineNumbers: true,
        Key.showMinimap: true,
        Key.highlightCurrentLine: true,
        Key.showIndentGuides: true,
        Key.showInvisibles: false,
        Key.autoCloseBrackets: true,
        Key.autoIndent: true,
        Key.autoComplete: true,
        Key.scrollPastEnd: true,
        Key.trimTrailingWhitespace: false,
        Key.ensureNewlineAtEOF: false,
        Key.hotExit: true,
        Key.restoreSession: true,
        Key.showHiddenFiles: true,
        Key.hiddenPatterns: ".git .svn .hg .DS_Store",
        Key.searchExcludes: ".git node_modules .build build dist DerivedData Pods target .next .nuxt .venv venv __pycache__ .gradle .idea .cache vendor/bundle",
        Key.highlightBrackets: true,
        Key.highlightOccurrences: true,
        Key.rulerColumn: 0,
        Key.showStatusBar: true,
        Key.sidebarVisible: true,
        Key.sidebarWidth: 240.0,
        Key.saveOnFocusLost: false,
        Key.gitEnabled: true,
        Key.gitGutter: true,
        Key.gitSidebarStatus: true,
        Key.gitStatusBarChanges: true,
        Key.gitChangesAndHistory: false,
        Key.quitWhenLastWindowCloses: false,
        Key.revealActiveFile: true,
        Key.markdownPreviewOnOpen: false,
        Key.spellCheckProse: true,
        Key.markdownRemoteContent: false,
    ]

    private let d = UserDefaults.standard
    private var pendingNotify = false
    private var lastSnapshot: [String: String] = [:]

    private init() {
        d.register(defaults: Settings.defaults)
        lastSnapshot = snapshot()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: d, queue: .main) { [weak self] _ in
            self?.scheduleNotify()
        }
    }

    private func snapshot() -> [String: String] {
        var s: [String: String] = [:]
        for k in Settings.defaults.keys { s[k] = "\(d.object(forKey: k) ?? "")" }
        return s
    }

    private func scheduleNotify() {
        guard !pendingNotify else { return }
        pendingNotify = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingNotify = false
            let snap = self.snapshot()
            guard snap != self.lastSnapshot else { return }
            self.lastSnapshot = snap
            self._font = nil
            ThemeManager.shared.refresh()
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }

    var theme: String { get { d.string(forKey: Key.theme) ?? "Tovri Dark" } set { d.set(newValue, forKey: Key.theme) } }
    var followSystemAppearance: Bool { get { d.bool(forKey: Key.followSystemAppearance) } set { d.set(newValue, forKey: Key.followSystemAppearance) } }
    var lightTheme: String { d.string(forKey: Key.lightTheme) ?? "Tovri Day" }
    var darkTheme: String { d.string(forKey: Key.darkTheme) ?? "Tovri Dark" }
    var fontName: String { get { d.string(forKey: Key.fontName) ?? "" } set { d.set(newValue, forKey: Key.fontName) } }
    var fontSize: Double { get { min(max(d.double(forKey: Key.fontSize), 6), 72) } set { d.set(min(max(newValue, 6), 72), forKey: Key.fontSize) } }
    var lineHeight: Double { min(max(d.double(forKey: Key.lineHeight), 1.0), 2.5) }
    var tabWidth: Int { get { min(max(d.integer(forKey: Key.tabWidth), 1), 16) } set { d.set(newValue, forKey: Key.tabWidth) } }
    var insertSpaces: Bool { d.bool(forKey: Key.insertSpaces) }
    var detectIndentation: Bool { d.bool(forKey: Key.detectIndentation) }
    var wordWrap: Bool { get { d.bool(forKey: Key.wordWrap) } set { d.set(newValue, forKey: Key.wordWrap) } }
    var showLineNumbers: Bool { get { d.bool(forKey: Key.showLineNumbers) } set { d.set(newValue, forKey: Key.showLineNumbers) } }
    var showMinimap: Bool { get { d.bool(forKey: Key.showMinimap) } set { d.set(newValue, forKey: Key.showMinimap) } }
    var highlightCurrentLine: Bool { d.bool(forKey: Key.highlightCurrentLine) }
    var showIndentGuides: Bool { get { d.bool(forKey: Key.showIndentGuides) } set { d.set(newValue, forKey: Key.showIndentGuides) } }
    var showInvisibles: Bool { get { d.bool(forKey: Key.showInvisibles) } set { d.set(newValue, forKey: Key.showInvisibles) } }
    var autoCloseBrackets: Bool { d.bool(forKey: Key.autoCloseBrackets) }
    var autoIndent: Bool { d.bool(forKey: Key.autoIndent) }
    var autoComplete: Bool { d.bool(forKey: Key.autoComplete) }
    var scrollPastEnd: Bool { d.bool(forKey: Key.scrollPastEnd) }
    var trimTrailingWhitespace: Bool { d.bool(forKey: Key.trimTrailingWhitespace) }
    var ensureNewlineAtEOF: Bool { d.bool(forKey: Key.ensureNewlineAtEOF) }
    var hotExit: Bool { d.bool(forKey: Key.hotExit) }
    var restoreSession: Bool { d.bool(forKey: Key.restoreSession) }
    var showHiddenFiles: Bool { d.bool(forKey: Key.showHiddenFiles) }
    var highlightBrackets: Bool { d.bool(forKey: Key.highlightBrackets) }
    var highlightOccurrences: Bool { d.bool(forKey: Key.highlightOccurrences) }
    var rulerColumn: Int { max(0, d.integer(forKey: Key.rulerColumn)) }
    var showStatusBar: Bool { get { d.bool(forKey: Key.showStatusBar) } set { d.set(newValue, forKey: Key.showStatusBar) } }
    var sidebarVisible: Bool { get { d.bool(forKey: Key.sidebarVisible) } set { d.set(newValue, forKey: Key.sidebarVisible) } }
    var sidebarWidth: Double { get { min(max(d.double(forKey: Key.sidebarWidth), 140), 600) } set { d.set(newValue, forKey: Key.sidebarWidth) } }

    var saveOnFocusLost: Bool { d.bool(forKey: Key.saveOnFocusLost) }
    /// Off: Tovri never runs git or reads a .git folder. Each Git feature below also needs this.
    var gitEnabled: Bool { d.bool(forKey: Key.gitEnabled) }
    /// Change markers, the change card and Compare with Last Commit. Off: no committed copies are loaded or diffed.
    var gitGutter: Bool { gitEnabled && d.bool(forKey: Key.gitGutter) }
    var gitSidebarStatus: Bool { gitEnabled && d.bool(forKey: Key.gitSidebarStatus) }
    var gitStatusBarChanges: Bool { gitEnabled && d.bool(forKey: Key.gitStatusBarChanges) }
    /// The sidebar's Changes view and File History. Off by default.
    var gitChangesAndHistory: Bool { gitEnabled && d.bool(forKey: Key.gitChangesAndHistory) }
    /// Whether anything needs `git status`.
    var gitNeedsStatus: Bool { gitSidebarStatus || gitStatusBarChanges || gitChangesAndHistory }
    var quitWhenLastWindowCloses: Bool { d.bool(forKey: Key.quitWhenLastWindowCloses) }
    var revealActiveFile: Bool { d.bool(forKey: Key.revealActiveFile) }
    var markdownPreviewOnOpen: Bool { d.bool(forKey: Key.markdownPreviewOnOpen) }
    var spellCheckProse: Bool { d.bool(forKey: Key.spellCheckProse) }
    var markdownRemoteContent: Bool { d.bool(forKey: Key.markdownRemoteContent) }

    var hiddenPatterns: Set<String> {
        Set((d.string(forKey: Key.hiddenPatterns) ?? "").split(separator: " ").map(String.init))
    }

    var searchExcludes: Set<String> {
        Set((d.string(forKey: Key.searchExcludes) ?? "").split(separator: " ").map(String.init))
    }

    private var _font: NSFont?
    var font: NSFont {
        if let f = _font { return f }
        let size = CGFloat(fontSize)
        var f: NSFont = .monospacedSystemFont(ofSize: size, weight: .regular)
        if !fontName.isEmpty, let custom = NSFont(name: fontName, size: size) { f = custom }
        _font = f
        return f
    }

    static func monospacedFontFamilies() -> [String] {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies.filter { family in
            guard let members = fm.availableMembers(ofFontFamily: family), let first = members.first,
                  let name = first[0] as? String, let font = NSFont(name: name, size: 12) else { return false }
            return font.isFixedPitch || family.localizedCaseInsensitiveContains("mono") || family.localizedCaseInsensitiveContains("code")
        }.sorted()
    }
}
