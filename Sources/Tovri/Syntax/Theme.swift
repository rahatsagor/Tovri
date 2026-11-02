import AppKit
import Combine

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        let hasAlpha = h.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : alpha
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    func mix(_ other: NSColor, _ fraction: CGFloat) -> NSColor {
        blended(withFraction: fraction, of: other) ?? self
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the color isn't opaque.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
        let a = byte(c.alphaComponent)
        return a == 255 ? rgb : rgb + String(format: "%02X", a)
    }
}

extension TokenKind {
    /// Stable name used in theme files.
    var key: String { String(describing: self) }
    static let byKey: [String: TokenKind] = Dictionary(uniqueKeysWithValues: allCases.map { ($0.key, $0) })
}

/// Optional per-theme UI colors; anything left nil is derived from the base palette.
struct ThemeUI: Codable, Equatable {
    var gutter: String?
    var gutterActive: String?
    var guide: String?
    var activeGuide: String?
    var invisibles: String?
    var border: String?
    var chromeForeground: String?
    var chromeSecondary: String?
    var tabActive: String?
    var hover: String?
    var sidebarSelection: String?
    var panel: String?
    var field: String?
    var findMatch: String?
    var findCurrent: String?
    var bracket: String?
    var wordHighlight: String?
    var minimapViewport: String?
    var dirty: String?
    /// Window blur: the window background is a blurred view tinted with this color.
    var windowTint: String?

    static let keyPaths: [WritableKeyPath<ThemeUI, String?>] = [
        \.gutter, \.gutterActive, \.guide, \.activeGuide, \.invisibles, \.border, \.chromeForeground,
        \.chromeSecondary, \.tabActive, \.hover, \.sidebarSelection, \.panel, \.field, \.findMatch,
        \.findCurrent, \.bracket, \.wordHighlight, \.minimapViewport, \.dirty, \.windowTint,
    ]
}

/// The colors a theme is made from, as stored in a custom theme file. Colors left out are
/// derived from the base palette when the theme is built.
struct ThemeDefinition: Codable, Equatable {
    var name: String
    var dark: Bool
    var background: String
    var foreground: String
    var accent: String
    var selection: String?
    var lineHighlight: String?
    var caret: String?
    var chrome: String?
    var ui: ThemeUI
    /// Token color by `TokenKind.key`.
    var tokens: [String: String]

    init(name: String, dark: Bool, background: String, foreground: String, accent: String,
         selection: String? = nil, lineHighlight: String? = nil, caret: String? = nil, chrome: String? = nil,
         ui: ThemeUI = ThemeUI(), tokens: [String: String] = [:]) {
        self.name = name
        self.dark = dark
        self.background = background
        self.foreground = foreground
        self.accent = accent
        self.selection = selection
        self.lineHighlight = lineHighlight
        self.caret = caret
        self.chrome = chrome
        self.ui = ui
        self.tokens = tokens
    }

    private enum CodingKeys: String, CodingKey {
        case name, dark, background, foreground, accent, selection, lineHighlight, caret, chrome, ui, tokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        dark = try c.decode(Bool.self, forKey: .dark)
        background = try c.decode(String.self, forKey: .background)
        foreground = try c.decode(String.self, forKey: .foreground)
        accent = try c.decode(String.self, forKey: .accent)
        selection = try c.decodeIfPresent(String.self, forKey: .selection)
        lineHighlight = try c.decodeIfPresent(String.self, forKey: .lineHighlight)
        caret = try c.decodeIfPresent(String.self, forKey: .caret)
        chrome = try c.decodeIfPresent(String.self, forKey: .chrome)
        ui = try c.decodeIfPresent(ThemeUI.self, forKey: .ui) ?? ThemeUI()
        tokens = try c.decodeIfPresent([String: String].self, forKey: .tokens) ?? [:]
    }

    static let maxNameLength = 60

    static func isValidHex(_ s: String) -> Bool {
        let h = s.hasPrefix("#") ? s.dropFirst() : Substring(s)
        return [3, 6, 8].contains(h.count) && h.allSatisfy(\.isHexDigit)
    }

    static func cleanName(_ s: String) -> String {
        s.filter { !$0.isNewline && !($0.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? false) }
            .trimmingCharacters(in: .whitespaces)
    }

    /// Theme files come from outside Tovri, so this rejects anything `Theme` can't use as is:
    /// a missing name, a malformed color, or unknown token names (which are dropped).
    func validated() -> ThemeDefinition? {
        var d = self
        d.name = ThemeDefinition.cleanName(name)
        guard !d.name.isEmpty, d.name.count <= ThemeDefinition.maxNameLength else { return nil }
        let required = [background, foreground, accent]
        let optional = [selection, lineHighlight, caret, chrome] + ThemeUI.keyPaths.map { ui[keyPath: $0] }
        guard required.allSatisfy(ThemeDefinition.isValidHex),
              optional.allSatisfy({ $0.map(ThemeDefinition.isValidHex) ?? true }) else { return nil }
        d.tokens = tokens.filter { TokenKind.byKey[$0.key] != nil && $0.key != TokenKind.plain.key && ThemeDefinition.isValidHex($0.value) }
        return d
    }
}

final class Theme {
    let name: String
    let isDark: Bool
    /// Made in Tovri's theme editor or imported, rather than built in.
    let isCustom: Bool
    let definition: ThemeDefinition
    /// Translucent themes draw editor surfaces clear over a blurred, tinted window.
    let translucent: Bool
    let windowTint: NSColor
    /// What editor surfaces (text, gutter, minimap) fill with: clear when translucent.
    let editorBackground: NSColor

    let background: NSColor
    let foreground: NSColor
    let caret: NSColor
    let selection: NSColor
    let inactiveSelection: NSColor
    let lineHighlight: NSColor
    let gutterForeground: NSColor
    let gutterActiveForeground: NSColor
    let guide: NSColor
    let activeGuide: NSColor
    let invisibles: NSColor

    let chromeBackground: NSColor
    let chromeBorder: NSColor
    let chromeForeground: NSColor
    let chromeSecondary: NSColor
    let tabActiveBackground: NSColor
    let tabHoverBackground: NSColor
    let sidebarSelection: NSColor
    let accent: NSColor
    let panelBackground: NSColor
    let fieldBackground: NSColor

    let findMatch: NSColor
    let findCurrent: NSColor
    let bracketMatch: NSColor
    let wordHighlight: NSColor
    let minimapViewport: NSColor
    let dirty: NSColor

    private(set) var tokenColors: [NSColor?]

    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    init(name: String, dark: Bool, background: String, foreground: String, accent: String,
         selection: String? = nil, lineHighlight: String? = nil, caret: String? = nil,
         chrome: String? = nil, ui: ThemeUI = ThemeUI(), tokens: [TokenKind: String], custom: Bool = false) {
        func c(_ hex: String?) -> NSColor? { hex.map { NSColor(hex: $0) } }
        self.name = name
        self.isDark = dark
        self.isCustom = custom
        self.definition = ThemeDefinition(name: name, dark: dark, background: background, foreground: foreground, accent: accent,
                                          selection: selection, lineHighlight: lineHighlight, caret: caret, chrome: chrome, ui: ui,
                                          tokens: Dictionary(uniqueKeysWithValues: tokens.map { ($0.key.key, $0.value) }))
        let bg = NSColor(hex: background)
        let fg = NSColor(hex: foreground)
        let ac = NSColor(hex: accent)
        let contrast: NSColor = dark ? .white : .black
        self.background = bg
        self.foreground = fg
        self.accent = ac
        self.caret = caret.map { NSColor(hex: $0) } ?? ac
        self.selection = selection.map { NSColor(hex: $0) } ?? bg.mix(ac, dark ? 0.32 : 0.22)
        self.inactiveSelection = self.selection.mix(bg, 0.45)
        self.lineHighlight = lineHighlight.map { NSColor(hex: $0) } ?? bg.mix(contrast, dark ? 0.045 : 0.035)
        self.gutterForeground = c(ui.gutter) ?? fg.mix(bg, dark ? 0.62 : 0.55)
        self.gutterActiveForeground = c(ui.gutterActive) ?? fg.mix(bg, 0.12)
        self.guide = c(ui.guide) ?? fg.mix(bg, dark ? 0.88 : 0.86)
        self.activeGuide = c(ui.activeGuide) ?? fg.mix(bg, dark ? 0.7 : 0.66)
        self.invisibles = c(ui.invisibles) ?? fg.mix(bg, dark ? 0.78 : 0.74)
        self.translucent = ui.windowTint != nil
        self.windowTint = c(ui.windowTint) ?? bg
        self.editorBackground = ui.windowTint != nil ? .clear : bg

        let chromeBg = chrome.map { NSColor(hex: $0) } ?? bg.mix(dark ? .black : NSColor(hex: "#E9ECF2"), dark ? 0.22 : 0.55)
        self.chromeBackground = chromeBg
        self.chromeBorder = c(ui.border) ?? chromeBg.mix(contrast, dark ? 0.09 : 0.1)
        self.chromeForeground = c(ui.chromeForeground) ?? fg.mix(chromeBg, 0.12)
        self.chromeSecondary = c(ui.chromeSecondary) ?? fg.mix(chromeBg, 0.48)
        self.tabActiveBackground = c(ui.tabActive) ?? bg
        self.tabHoverBackground = c(ui.hover) ?? chromeBg.mix(contrast, dark ? 0.05 : 0.05)
        self.sidebarSelection = c(ui.sidebarSelection) ?? chromeBg.mix(ac, dark ? 0.28 : 0.2)
        self.panelBackground = c(ui.panel) ?? bg.mix(contrast, dark ? 0.06 : 0.02)
        self.fieldBackground = c(ui.field) ?? bg.mix(contrast, dark ? 0.1 : 0.05)

        self.findMatch = c(ui.findMatch) ?? ac.withAlphaComponent(dark ? 0.28 : 0.22)
        self.findCurrent = c(ui.findCurrent) ?? NSColor(hex: dark ? "#FFB454" : "#FF9F1A").withAlphaComponent(dark ? 0.55 : 0.5)
        self.bracketMatch = c(ui.bracket) ?? fg.withAlphaComponent(0.45)
        self.wordHighlight = c(ui.wordHighlight) ?? fg.withAlphaComponent(dark ? 0.12 : 0.1)
        self.minimapViewport = c(ui.minimapViewport) ?? fg.withAlphaComponent(dark ? 0.07 : 0.07)
        self.dirty = c(ui.dirty) ?? ac

        var colors = [NSColor?](repeating: nil, count: TokenKind.allCases.count)
        for (k, v) in tokens { colors[Int(k.rawValue)] = NSColor(hex: v) }
        func fallback(_ k: TokenKind, _ to: TokenKind) {
            if colors[Int(k.rawValue)] == nil { colors[Int(k.rawValue)] = colors[Int(to.rawValue)] }
        }
        fallback(.storage, .keyword)
        fallback(.builtin, .function)
        fallback(.constant, .number)
        fallback(.property, .attribute)
        fallback(.annotation, .attribute)
        fallback(.preprocessor, .keyword)
        fallback(.escape, .constant)
        fallback(.regex, .string)
        fallback(.heading, .function)
        fallback(.emphasis, .keyword)
        fallback(.strong, .number)
        fallback(.link, .builtin)
        fallback(.code, .string)
        fallback(.variable, .tag)
        if colors[Int(TokenKind.punctuation.rawValue)] == nil { colors[Int(TokenKind.punctuation.rawValue)] = fg.mix(bg, 0.3) }
        if colors[Int(TokenKind.operatorSymbol.rawValue)] == nil { colors[Int(TokenKind.operatorSymbol.rawValue)] = fg.mix(bg, 0.15) }
        if colors[Int(TokenKind.inserted.rawValue)] == nil { colors[Int(TokenKind.inserted.rawValue)] = NSColor(hex: dark ? "#8BD49C" : "#2E7D32") }
        if colors[Int(TokenKind.deleted.rawValue)] == nil { colors[Int(TokenKind.deleted.rawValue)] = NSColor(hex: dark ? "#F07178" : "#C62828") }
        if colors[Int(TokenKind.changed.rawValue)] == nil { colors[Int(TokenKind.changed.rawValue)] = NSColor(hex: dark ? "#E5C07B" : "#A06A00") }
        if colors[Int(TokenKind.invalid.rawValue)] == nil { colors[Int(TokenKind.invalid.rawValue)] = NSColor(hex: "#FF5370") }
        self.tokenColors = colors
    }

    convenience init(definition d: ThemeDefinition, custom: Bool = true) {
        var tokens: [TokenKind: String] = [:]
        for (k, v) in d.tokens { if let kind = TokenKind.byKey[k] { tokens[kind] = v } }
        self.init(name: d.name, dark: d.dark, background: d.background, foreground: d.foreground, accent: d.accent,
                  selection: d.selection, lineHighlight: d.lineHighlight, caret: d.caret, chrome: d.chrome,
                  ui: d.ui, tokens: tokens, custom: custom)
    }

    @inline(__always) func color(_ kind: TokenKind) -> NSColor? { tokenColors[Int(kind.rawValue)] }
}

extension Notification.Name {
    static let themeDidChange = Notification.Name("TovriThemeDidChange")
    static let settingsDidChange = Notification.Name("TovriSettingsDidChange")
    /// Custom themes were added, changed or removed.
    static let themeListDidChange = Notification.Name("TovriThemeListDidChange")
}

/// Custom theme files in a folder, one JSON `ThemeDefinition` per file.
struct CustomThemeStore {
    let directory: URL

    static let shared = CustomThemeStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tovri", isDirectory: true).appendingPathComponent("Themes", isDirectory: true))

    static let maxFileSize = 256 * 1024

    private func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func read(_ url: URL) -> ThemeDefinition? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= CustomThemeStore.maxFileSize,
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(ThemeDefinition.self, from: data))?.validated()
    }

    /// Valid themes, sorted by name; when two files use the same name, the first one wins.
    func load() -> [ThemeDefinition] {
        var seen = Set<String>()
        return files().compactMap(read).filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func fileName(for name: String) -> String {
        var s = String(name.map { "/:\\".contains($0) ? "-" : $0 })
        while s.hasPrefix(".") { s.removeFirst() }
        return (s.isEmpty ? "Theme" : s) + ".json"
    }

    /// Saves `definition`, replacing any theme file with the same name.
    func save(_ definition: ThemeDefinition) throws {
        guard let d = definition.validated() else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Overwrite the theme's existing file in place, so a failed write leaves the old theme intact.
        let existing = files().filter { read($0)?.name == d.name }
        var url = existing.first ?? directory.appendingPathComponent(CustomThemeStore.fileName(for: d.name))
        var n = 2
        while existing.isEmpty && FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent((CustomThemeStore.fileName(for: d.name) as NSString).deletingPathExtension + " \(n).json")
            n += 1
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(d).write(to: url, options: .atomic)
        for other in existing.dropFirst() { try? FileManager.default.removeItem(at: other) }
    }

    func delete(named name: String) throws {
        for url in files() where read(url)?.name == name { try FileManager.default.removeItem(at: url) }
    }
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    let builtIn: [Theme] = Themes.all
    private(set) var themes: [Theme]
    private(set) var current: Theme
    enum PreviewSource { case picker, editor }
    /// Temporarily shown themes; nil when not previewing. The theme picker can open while the
    /// theme editor is previewing, so each keeps its own slot and the picker's wins.
    private var pickerPreview: Theme?
    private var editorPreview: Theme?
    var store: CustomThemeStore

    var active: Theme { pickerPreview ?? editorPreview ?? current }
    var customThemes: [Theme] { themes.filter(\.isCustom) }

    private init() {
        store = .shared
        themes = Themes.all
        current = Themes.all[0]
        themes = builtIn + loadCustom()
        current = resolvedTheme()
    }

    private func loadCustom() -> [Theme] {
        let reserved = Set(builtIn.map(\.name))
        return store.load().filter { !reserved.contains($0.name) }.map { Theme(definition: $0) }
    }

    func theme(named name: String) -> Theme? { themes.first { $0.name == name } }

    func isBuiltIn(_ name: String) -> Bool { builtIn.contains { $0.name == name } }

    func reloadCustomThemes() {
        objectWillChange.send()
        themes = builtIn + loadCustom()
        repairSelection()
        NotificationCenter.default.post(name: .themeListDidChange, object: nil)
        refresh()
    }

    /// Theme settings that name a missing theme, or a light or dark slot holding the other kind
    /// (after a theme was switched between light and dark), go back to Tovri's own themes.
    private func repairSelection() {
        let d = UserDefaults.standard
        func fix(_ key: String, fallback: String, valid: (Theme) -> Bool) {
            guard let name = d.string(forKey: key) else { return }
            if let t = theme(named: name), valid(t) { return }
            d.set(fallback, forKey: key)
        }
        fix(Settings.Key.theme, fallback: "Tovri Dark") { _ in true }
        fix(Settings.Key.lightTheme, fallback: "Tovri Day") { !$0.isDark }
        fix(Settings.Key.darkTheme, fallback: "Tovri Dark") { $0.isDark }
    }

    /// Saves a custom theme. When it was renamed, the old file goes and any setting that chose the
    /// old name follows the new one.
    func saveCustomTheme(_ definition: ThemeDefinition, replacing oldName: String?) throws {
        guard let d = definition.validated(), !isBuiltIn(d.name) else { throw CocoaError(.fileWriteInvalidFileName) }
        try store.save(d)
        if let oldName, oldName != d.name {
            try store.delete(named: oldName)
            renameSelection(from: oldName, to: d.name)
        }
        reloadCustomThemes()
    }

    /// A setting that chose the deleted theme falls back to Tovri's own light or dark theme.
    func deleteCustomTheme(named name: String) throws {
        let dark = theme(named: name)?.isDark ?? true
        try store.delete(named: name)
        let d = UserDefaults.standard
        if d.string(forKey: Settings.Key.theme) == name { d.set(dark ? "Tovri Dark" : "Tovri Day", forKey: Settings.Key.theme) }
        if d.string(forKey: Settings.Key.lightTheme) == name { d.set("Tovri Day", forKey: Settings.Key.lightTheme) }
        if d.string(forKey: Settings.Key.darkTheme) == name { d.set("Tovri Dark", forKey: Settings.Key.darkTheme) }
        reloadCustomThemes()
    }

    private func renameSelection(from old: String, to new: String) {
        let d = UserDefaults.standard
        for key in [Settings.Key.theme, Settings.Key.lightTheme, Settings.Key.darkTheme] where d.string(forKey: key) == old {
            d.set(new, forKey: key)
        }
    }

    func resolvedTheme() -> Theme {
        let s = Settings.shared
        if s.followSystemAppearance {
            let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return theme(named: dark ? s.darkTheme : s.lightTheme) ?? theme(named: dark ? "Tovri Dark" : "Tovri Day") ?? themes[0]
        }
        return theme(named: s.theme) ?? themes[0]
    }

    func refresh() {
        let t = resolvedTheme()
        if t !== current {
            current = t
            if pickerPreview == nil && editorPreview == nil { NotificationCenter.default.post(name: .themeDidChange, object: nil) }
        }
    }

    func preview(_ theme: Theme?, from source: PreviewSource = .picker) {
        switch source {
        case .picker: pickerPreview = theme
        case .editor: editorPreview = theme
        }
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }
}

enum Themes {
    static let all: [Theme] = [
        // Based on the RS "Dark Blur Light" Zed theme: blurred window, calm Catppuccin-like syntax.
        Theme(name: "Tovri Dark", dark: true, background: "#0B0C10", foreground: "#CDD6F4", accent: "#CBA6F7",
              selection: "#9399B240", lineHighlight: "#F5E0DC0D", caret: "#F5E0DC", chrome: "#00000000",
              ui: ThemeUI(gutter: "#FFFFFF33", gutterActive: "#F5E0DCB0", guide: "#31324499", activeGuide: "#585B70",
                          invisibles: "#9399B266", border: "#45475A80", chromeForeground: "#CDD6F4", chromeSecondary: "#9399B2",
                          tabActive: "#1E1E2E80", hover: "#31324466", sidebarSelection: "#45475A99", panel: "#14141CF2",
                          field: "#11111BCC", findMatch: "#94E2D54D", findCurrent: "#F38BA866", bracket: "#CBA6F7AA",
                          wordHighlight: "#A6ADC829", minimapViewport: "#CBA6F726", dirty: "#CBA6F7", windowTint: "#0B0C1099"),
              tokens: [.keyword: "#CBA6F7", .storage: "#CBA6F7", .type: "#F9E2AF", .function: "#89B4FA",
                       .string: "#A6E3A1", .number: "#FAB387", .comment: "#9399B2", .constant: "#FAB387",
                       .builtin: "#FAB387", .variable: "#F38BA8", .operatorSymbol: "#89DCEB", .punctuation: "#9399B2",
                       .tag: "#89B4FA", .attribute: "#F9E2AF", .property: "#89B4FA", .preprocessor: "#F5C2E7",
                       .annotation: "#FAB387", .escape: "#F5C2E7", .regex: "#FAB387", .heading: "#CBA6F7",
                       .emphasis: "#EBA0AC", .strong: "#EBA0AC", .link: "#B4BEFE", .code: "#A6E3A1",
                       .inserted: "#A6E3A1", .deleted: "#F38BA8", .changed: "#F9E2AF", .invalid: "#F38BA8"]),
        Theme(name: "Tovri Night", dark: true, background: "#15171C", foreground: "#D4D9E1", accent: "#7C8CFF",
              selection: "#2A3350", lineHighlight: "#1B1E25", caret: "#8C9BFF", chrome: "#101216",
              tokens: [.keyword: "#C49BFF", .storage: "#8FA8FF", .type: "#5FD7C4", .function: "#7DB7FF",
                       .string: "#A8D98B", .number: "#FFB86B", .comment: "#5D6573", .constant: "#FF9E64",
                       .builtin: "#6DCFF6", .variable: "#F07178", .operatorSymbol: "#89DDFF", .punctuation: "#8A93A3",
                       .tag: "#F07178", .attribute: "#FFCB6B", .property: "#7FDBCA", .preprocessor: "#FF79C6",
                       .annotation: "#FFCB6B", .escape: "#FF9E64", .regex: "#B4F9F8", .heading: "#7DB7FF",
                       .emphasis: "#C49BFF", .strong: "#FFB86B", .link: "#6DCFF6", .code: "#A8D98B"]),
        Theme(name: "Tovri Day", dark: false, background: "#FBFBFD", foreground: "#24292F", accent: "#5B6CFF",
              selection: "#D6E2FF", lineHighlight: "#F1F3F8", caret: "#4C5DF2", chrome: "#F1F2F6",
              tokens: [.keyword: "#A626A4", .storage: "#4B5BD8", .type: "#0E7C86", .function: "#2F6FDB",
                       .string: "#3B8A2E", .number: "#C25E00", .comment: "#8C95A3", .constant: "#C25E00",
                       .builtin: "#0B7FA8", .variable: "#C4322C", .operatorSymbol: "#3E7A99", .punctuation: "#6B7280",
                       .tag: "#C4322C", .attribute: "#A06A00", .property: "#0F7A6A", .preprocessor: "#B5179E",
                       .annotation: "#A06A00", .escape: "#C25E00", .regex: "#0B7FA8", .heading: "#2F6FDB",
                       .emphasis: "#A626A4", .strong: "#C25E00", .link: "#0B7FA8", .code: "#3B8A2E"]),
        Theme(name: "One Dark", dark: true, background: "#282C34", foreground: "#ABB2BF", accent: "#61AFEF",
              selection: "#3E4451", lineHighlight: "#2C313C", caret: "#528BFF", chrome: "#21252B",
              tokens: [.keyword: "#C678DD", .storage: "#C678DD", .type: "#E5C07B", .function: "#61AFEF",
                       .string: "#98C379", .number: "#D19A66", .comment: "#5C6370", .constant: "#D19A66",
                       .builtin: "#56B6C2", .variable: "#E06C75", .operatorSymbol: "#56B6C2", .tag: "#E06C75",
                       .attribute: "#D19A66", .property: "#E06C75", .preprocessor: "#C678DD", .annotation: "#E5C07B",
                       .escape: "#56B6C2", .regex: "#56B6C2", .heading: "#E06C75", .link: "#61AFEF"]),
        Theme(name: "Monokai", dark: true, background: "#272822", foreground: "#F8F8F2", accent: "#A6E22E",
              selection: "#49483E", lineHighlight: "#3E3D32", caret: "#F8F8F0", chrome: "#1E1F1C",
              tokens: [.keyword: "#F92672", .storage: "#66D9EF", .type: "#66D9EF", .function: "#A6E22E",
                       .string: "#E6DB74", .number: "#AE81FF", .comment: "#75715E", .constant: "#AE81FF",
                       .builtin: "#66D9EF", .variable: "#FD971F", .operatorSymbol: "#F92672", .punctuation: "#F8F8F2",
                       .tag: "#F92672", .attribute: "#A6E22E", .property: "#66D9EF", .preprocessor: "#F92672",
                       .annotation: "#A6E22E", .escape: "#AE81FF", .heading: "#A6E22E", .link: "#66D9EF"]),
        Theme(name: "Dracula", dark: true, background: "#282A36", foreground: "#F8F8F2", accent: "#BD93F9",
              selection: "#44475A", lineHighlight: "#2F3141", caret: "#F8F8F2", chrome: "#21222C",
              tokens: [.keyword: "#FF79C6", .storage: "#FF79C6", .type: "#8BE9FD", .function: "#50FA7B",
                       .string: "#F1FA8C", .number: "#BD93F9", .comment: "#6272A4", .constant: "#BD93F9",
                       .builtin: "#8BE9FD", .variable: "#FFB86C", .operatorSymbol: "#FF79C6", .tag: "#FF79C6",
                       .attribute: "#50FA7B", .property: "#8BE9FD", .preprocessor: "#FF79C6", .annotation: "#50FA7B",
                       .escape: "#FF79C6", .heading: "#BD93F9", .link: "#8BE9FD"]),
        Theme(name: "Tokyo Night", dark: true, background: "#1A1B26", foreground: "#C0CAF5", accent: "#7AA2F7",
              selection: "#283457", lineHighlight: "#1F2133", caret: "#C0CAF5", chrome: "#16161E",
              tokens: [.keyword: "#BB9AF7", .storage: "#9D7CD8", .type: "#2AC3DE", .function: "#7AA2F7",
                       .string: "#9ECE6A", .number: "#FF9E64", .comment: "#565F89", .constant: "#FF9E64",
                       .builtin: "#2AC3DE", .variable: "#F7768E", .operatorSymbol: "#89DDFF", .tag: "#F7768E",
                       .attribute: "#BB9AF7", .property: "#73DACA", .preprocessor: "#7DCFFF", .annotation: "#E0AF68",
                       .escape: "#89DDFF", .regex: "#B4F9F8", .heading: "#7AA2F7", .link: "#73DACA"]),
        Theme(name: "Catppuccin Mocha", dark: true, background: "#1E1E2E", foreground: "#CDD6F4", accent: "#CBA6F7",
              selection: "#45475A", lineHighlight: "#25253A", caret: "#F5E0DC", chrome: "#181825",
              tokens: [.keyword: "#CBA6F7", .storage: "#CBA6F7", .type: "#F9E2AF", .function: "#89B4FA",
                       .string: "#A6E3A1", .number: "#FAB387", .comment: "#6C7086", .constant: "#FAB387",
                       .builtin: "#F38BA8", .variable: "#F2CDCD", .operatorSymbol: "#89DCEB", .tag: "#89B4FA",
                       .attribute: "#F9E2AF", .property: "#89DCEB", .preprocessor: "#F5C2E7", .annotation: "#F9E2AF",
                       .escape: "#F5C2E7", .heading: "#F38BA8", .link: "#74C7EC"]),
        Theme(name: "Nord", dark: true, background: "#2E3440", foreground: "#D8DEE9", accent: "#88C0D0",
              selection: "#434C5E", lineHighlight: "#3B4252", caret: "#D8DEE9", chrome: "#272C36",
              tokens: [.keyword: "#81A1C1", .storage: "#81A1C1", .type: "#8FBCBB", .function: "#88C0D0",
                       .string: "#A3BE8C", .number: "#B48EAD", .comment: "#616E88", .constant: "#81A1C1",
                       .builtin: "#88C0D0", .variable: "#D8DEE9", .operatorSymbol: "#81A1C1", .tag: "#81A1C1",
                       .attribute: "#8FBCBB", .property: "#8FBCBB", .preprocessor: "#5E81AC", .annotation: "#D08770",
                       .escape: "#EBCB8B", .heading: "#88C0D0", .link: "#8FBCBB"]),
        Theme(name: "Gruvbox Dark", dark: true, background: "#282828", foreground: "#EBDBB2", accent: "#FE8019",
              selection: "#504945", lineHighlight: "#32302F", caret: "#EBDBB2", chrome: "#1D2021",
              tokens: [.keyword: "#FB4934", .storage: "#FE8019", .type: "#FABD2F", .function: "#B8BB26",
                       .string: "#B8BB26", .number: "#D3869B", .comment: "#928374", .constant: "#D3869B",
                       .builtin: "#8EC07C", .variable: "#83A598", .operatorSymbol: "#8EC07C", .tag: "#FB4934",
                       .attribute: "#FABD2F", .property: "#83A598", .preprocessor: "#8EC07C", .annotation: "#FABD2F",
                       .escape: "#FE8019", .heading: "#FABD2F", .link: "#83A598"]),
        Theme(name: "GitHub Dark", dark: true, background: "#0D1117", foreground: "#E6EDF3", accent: "#2F81F7",
              selection: "#264F78", lineHighlight: "#161B22", caret: "#2F81F7", chrome: "#010409",
              tokens: [.keyword: "#FF7B72", .storage: "#FF7B72", .type: "#FFA657", .function: "#D2A8FF",
                       .string: "#A5D6FF", .number: "#79C0FF", .comment: "#8B949E", .constant: "#79C0FF",
                       .builtin: "#FFA657", .variable: "#FFA657", .operatorSymbol: "#FF7B72", .tag: "#7EE787",
                       .attribute: "#79C0FF", .property: "#79C0FF", .preprocessor: "#FF7B72", .annotation: "#D2A8FF",
                       .escape: "#79C0FF", .heading: "#79C0FF", .link: "#A5D6FF"]),
        Theme(name: "GitHub Light", dark: false, background: "#FFFFFF", foreground: "#1F2328", accent: "#0969DA",
              selection: "#C8DDFB", lineHighlight: "#F6F8FA", caret: "#0969DA", chrome: "#F6F8FA",
              tokens: [.keyword: "#CF222E", .storage: "#CF222E", .type: "#953800", .function: "#8250DF",
                       .string: "#0A3069", .number: "#0550AE", .comment: "#6E7781", .constant: "#0550AE",
                       .builtin: "#953800", .variable: "#953800", .operatorSymbol: "#CF222E", .tag: "#116329",
                       .attribute: "#0550AE", .property: "#0550AE", .preprocessor: "#CF222E", .annotation: "#8250DF",
                       .escape: "#0550AE", .heading: "#0550AE", .link: "#0A3069"]),
        Theme(name: "Solarized Dark", dark: true, background: "#002B36", foreground: "#93A1A1", accent: "#268BD2",
              selection: "#0A4656", lineHighlight: "#073642", caret: "#93A1A1", chrome: "#00222B",
              tokens: [.keyword: "#859900", .storage: "#268BD2", .type: "#B58900", .function: "#268BD2",
                       .string: "#2AA198", .number: "#D33682", .comment: "#586E75", .constant: "#CB4B16",
                       .builtin: "#268BD2", .variable: "#B58900", .operatorSymbol: "#859900", .tag: "#268BD2",
                       .attribute: "#93A1A1", .property: "#268BD2", .preprocessor: "#CB4B16", .annotation: "#6C71C4",
                       .escape: "#DC322F", .heading: "#268BD2", .link: "#2AA198"]),
        Theme(name: "Solarized Light", dark: false, background: "#FDF6E3", foreground: "#586E75", accent: "#268BD2",
              selection: "#E6DFC8", lineHighlight: "#F3ECD7", caret: "#586E75", chrome: "#EEE8D5",
              tokens: [.keyword: "#859900", .storage: "#268BD2", .type: "#B58900", .function: "#268BD2",
                       .string: "#2AA198", .number: "#D33682", .comment: "#93A1A1", .constant: "#CB4B16",
                       .builtin: "#268BD2", .variable: "#B58900", .operatorSymbol: "#859900", .tag: "#268BD2",
                       .attribute: "#657B83", .property: "#268BD2", .preprocessor: "#CB4B16", .annotation: "#6C71C4",
                       .escape: "#DC322F", .heading: "#268BD2", .link: "#2AA198"]),
        Theme(name: "Catppuccin Latte", dark: false, background: "#EFF1F5", foreground: "#4C4F69", accent: "#8839EF",
              selection: "#CCD0DA", lineHighlight: "#E6E9EF", caret: "#DC8A78", chrome: "#E6E9EF",
              tokens: [.keyword: "#8839EF", .storage: "#8839EF", .type: "#DF8E1D", .function: "#1E66F5",
                       .string: "#40A02B", .number: "#FE640B", .comment: "#9CA0B0", .constant: "#FE640B",
                       .builtin: "#D20F39", .variable: "#DD7878", .operatorSymbol: "#04A5E5", .tag: "#1E66F5",
                       .attribute: "#DF8E1D", .property: "#179299", .preprocessor: "#EA76CB", .annotation: "#DF8E1D",
                       .escape: "#EA76CB", .heading: "#D20F39", .link: "#209FB5"]),
    ]
}
