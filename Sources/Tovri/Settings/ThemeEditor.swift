import AppKit
import SwiftUI

/// A custom theme being edited: `originalName` is nil for a new theme.
struct ThemeEditorSession: Identifiable {
    let id = UUID()
    var definition: ThemeDefinition
    var originalName: String?

    /// A copy of `theme` under a name no other theme uses.
    static func copy(of theme: Theme, among themes: [Theme]) -> ThemeEditorSession {
        var d = theme.definition
        let base = String((theme.isCustom ? "\(theme.name) Copy" : "\(theme.name) Custom").prefix(ThemeDefinition.maxNameLength - 3))
        var name = base
        var n = 2
        while themes.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        d.name = name
        return ThemeEditorSession(definition: d, originalName: nil)
    }
}

struct ThemeEditor: View {
    @State private var def: ThemeDefinition
    private let originalName: String?
    @State private var error: String?
    @State private var showInterface = false
    @Environment(\.dismiss) private var dismiss

    init(session: ThemeEditorSession) {
        _def = State(initialValue: session.definition)
        originalName = session.originalName
    }

    private static let tokenLabels: [(TokenKind, String)] = [
        (.keyword, "Keywords"), (.storage, "Declarations"), (.type, "Types"), (.function, "Functions"),
        (.string, "Strings"), (.number, "Numbers"), (.comment, "Comments"), (.constant, "Constants"),
        (.builtin, "Built-in functions"), (.variable, "Variables"), (.operatorSymbol, "Operators"),
        (.punctuation, "Punctuation"), (.tag, "Markup tags"), (.attribute, "Attributes"),
        (.property, "Properties and keys"), (.preprocessor, "Preprocessor"), (.annotation, "Annotations"),
        (.escape, "Escapes"), (.regex, "Regular expressions"), (.heading, "Headings"), (.emphasis, "Italic"),
        (.strong, "Bold"), (.link, "Links"), (.code, "Code in Markdown"), (.inserted, "Added lines"),
        (.deleted, "Removed lines"), (.changed, "Changed lines"), (.invalid, "Errors"),
    ]

    private static let interfaceLabels: [(String, WritableKeyPath<ThemeUI, String?>, (Theme) -> NSColor)] = [
        ("Line numbers", \.gutter, \.gutterForeground),
        ("Current line number", \.gutterActive, \.gutterActiveForeground),
        ("Indent guides", \.guide, \.guide),
        ("Active indent guide", \.activeGuide, \.activeGuide),
        ("Invisible characters", \.invisibles, \.invisibles),
        ("Sidebar and tab text", \.chromeForeground, \.chromeForeground),
        ("Secondary text", \.chromeSecondary, \.chromeSecondary),
        ("Borders", \.border, \.chromeBorder),
        ("Active tab", \.tabActive, \.tabActiveBackground),
        ("Hovered items", \.hover, \.tabHoverBackground),
        ("Sidebar selection", \.sidebarSelection, \.sidebarSelection),
        ("Panels", \.panel, \.panelBackground),
        ("Text fields", \.field, \.fieldBackground),
        ("Find matches", \.findMatch, \.findMatch),
        ("Current find match", \.findCurrent, \.findCurrent),
        ("Matching brackets", \.bracket, \.bracketMatch),
        ("Occurrences of the selection", \.wordHighlight, \.wordHighlight),
        ("Minimap visible area", \.minimapViewport, \.minimapViewport),
        ("Unsaved changes dot", \.dirty, \.dirty),
    ]

    private var nameProblem: String? {
        let name = ThemeDefinition.cleanName(def.name)
        if name.isEmpty { return "Enter a name for the theme." }
        if name.count > ThemeDefinition.maxNameLength { return "Use a name of up to \(ThemeDefinition.maxNameLength) characters." }
        let tm = ThemeManager.shared
        if tm.isBuiltIn(name) { return "A built-in theme already uses this name." }
        if name != originalName, tm.theme(named: name) != nil { return "Another theme already uses this name." }
        return nil
    }

    var body: some View {
        let theme = Theme(definition: def)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Name", text: $def.name)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $def.dark) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Dark themes are offered for dark mode, light ones for light mode.")
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)

            ThemePreview(theme: theme)
                .padding(.horizontal, 16)

            Form {
                Section("Base colors") {
                    requiredRow("Background", \.background)
                    requiredRow("Text", \.foreground)
                    requiredRow("Accent", \.accent)
                    optionalRow("Selection", value: $def.selection, effective: theme.selection)
                    optionalRow("Current line", value: $def.lineHighlight, effective: theme.lineHighlight)
                    optionalRow("Cursor", value: $def.caret, effective: theme.caret)
                    optionalRow("Sidebar and tab bar", value: $def.chrome, effective: theme.chromeBackground)
                }
                Section("Syntax") {
                    ForEach(ThemeEditor.tokenLabels, id: \.0) { kind, label in
                        optionalRow(label, value: tokenBinding(kind), effective: theme.color(kind) ?? theme.foreground)
                    }
                }
                Section {
                    DisclosureGroup("Interface colors", isExpanded: $showInterface) {
                        Toggle(isOn: blurBinding) {
                            Text("Blurred window")
                            Text("The window shows a blurred view of what's behind it, tinted with this color.")
                        }
                        if def.ui.windowTint != nil {
                            optionalRow("Window tint", value: $def.ui.windowTint, effective: theme.windowTint)
                        }
                        ForEach(ThemeEditor.interfaceLabels, id: \.0) { label, path, effective in
                            optionalRow(label, value: $def.ui[dynamicMember: path], effective: effective(theme))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let problem = error ?? nameProblem {
                    Text(problem).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameProblem != nil)
            }
            .padding(16)
        }
        .frame(width: 600, height: 640)
        .task(id: def) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            ThemeManager.shared.preview(Theme(definition: def), from: .editor)
        }
        .onChange(of: def) { _, _ in error = nil }
        .onDisappear { ThemeManager.shared.preview(nil, from: .editor) }
    }

    private func tokenBinding(_ kind: TokenKind) -> Binding<String?> {
        Binding(get: { def.tokens[kind.key] }, set: { def.tokens[kind.key] = $0 })
    }

    private var blurBinding: Binding<Bool> {
        Binding(get: { def.ui.windowTint != nil }, set: { on in
            def.ui.windowTint = on ? NSColor(hex: def.background).withAlphaComponent(0.6).hexString : nil
        })
    }

    private func requiredRow(_ label: String, _ path: WritableKeyPath<ThemeDefinition, String>) -> some View {
        ColorPicker(label, selection: Binding(
            get: { Color(nsColor: NSColor(hex: def[keyPath: path])) },
            set: { def[keyPath: path] = NSColor($0).hexString }
        ), supportsOpacity: false)
    }

    private func optionalRow(_ label: String, value: Binding<String?>, effective: NSColor) -> some View {
        HStack {
            Text(label)
            Spacer()
            if value.wrappedValue == nil {
                Text("Automatic").font(.callout).foregroundStyle(.tertiary)
            } else {
                Button {
                    value.wrappedValue = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Use the automatic color, worked out from the base colors")
            }
            ColorPicker(label, selection: Binding(
                get: { Color(nsColor: value.wrappedValue.map { NSColor(hex: $0) } ?? effective) },
                set: { value.wrappedValue = NSColor($0).hexString }
            ), supportsOpacity: true)
            .labelsHidden()
        }
    }

    private func save() {
        guard nameProblem == nil else { return }
        var d = def
        d.name = ThemeDefinition.cleanName(d.name)
        do {
            try ThemeManager.shared.saveCustomTheme(d, replacing: originalName)
        } catch {
            self.error = "Tovri couldn't save the theme. \(error.localizedDescription)"
            return
        }
        if originalName == nil {
            let s = UserDefaults.standard
            if s.bool(forKey: Settings.Key.followSystemAppearance) {
                s.set(d.name, forKey: d.dark ? Settings.Key.darkTheme : Settings.Key.lightTheme)
            } else {
                s.set(d.name, forKey: Settings.Key.theme)
            }
        }
        dismiss()
    }
}

/// A small mock of the editor window drawn with a theme's colors.
struct ThemePreview: View {
    let theme: Theme

    private enum Mark { case selection, find }
    private enum Seg {
        case text(String, TokenKind? = nil, Mark? = nil)
        case caret
    }

    private static let lines: [[Seg]] = [
        [.text("// Moves a point on the map", .comment)],
        [.text("@MainActor", .annotation)],
        [.text("struct", .storage), .text(" "), .text("Point", .type), .text(":", .punctuation), .text(" "), .text("Codable", .type), .text(" "), .text("{", .punctuation)],
        [.text("    "), .text("let", .storage), .text(" name "), .text("=", .operatorSymbol), .text(" "), .text("\"origin", .string), .text("\\n", .escape), .text("\"", .string)],
        [.text("    "), .text("var", .storage), .text(" x "), .text("=", .operatorSymbol), .text(" "), .text("42", .number, .find), .text(", y "), .text("=", .operatorSymbol), .text(" "), .text("3.5", .number)],
        [.text("    "), .text("func", .storage), .text(" "), .text("move", .function), .text("(", .punctuation), .text("by d"), .text(":", .punctuation), .text(" "), .text("Int", .type), .text(")", .punctuation), .text(" "), .text("->", .operatorSymbol), .text(" "), .text("Bool", .type), .text(" "), .text("{", .punctuation)],
        [.text("        "), .text("if", .keyword), .text(" d "), .text(">", .operatorSymbol), .text(" "), .text("0", .number), .text(" "), .text("{", .punctuation), .text(" "), .text("print", .builtin), .text("(", .punctuation), .text("name", nil, .selection), .caret, .text(")", .punctuation), .text(" "), .text("}", .punctuation)],
        [.text("        "), .text("return", .keyword), .text(" "), .text("true", .constant)],
        [.text("    "), .text("}", .punctuation)],
        [.text("}", .punctuation)],
    ]
    private static let currentLine = 6

    private func c(_ ns: NSColor) -> Color { Color(nsColor: ns) }

    var body: some View {
        let font = Font.system(size: 11.5, design: .monospaced)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tab("Point.swift", active: true)
                tab("README.md", active: false)
                Spacer(minLength: 0)
            }
            .frame(height: 26)
            .background(c(theme.translucent ? theme.windowTint : theme.chromeBackground))
            Rectangle().fill(c(theme.chromeBorder)).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(0..<ThemePreview.lines.count, id: \.self) { i in
                        Text("\(i + 1)")
                            .foregroundColor(c(i == ThemePreview.currentLine ? theme.gutterActiveForeground : theme.gutterForeground))
                            .frame(height: 16)
                    }
                }
                .padding(.horizontal, 10)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<ThemePreview.lines.count, id: \.self) { i in
                        line(ThemePreview.lines[i])
                            .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
                            .background(i == ThemePreview.currentLine ? c(theme.lineHighlight) : .clear)
                    }
                }
            }
            .font(font)
            .padding(.vertical, 6)
            .background(c(theme.background))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(c(theme.chromeBorder)))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the theme")
    }

    private func tab(_ title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            if active { Circle().fill(c(theme.dirty)).frame(width: 6, height: 6) }
            Text(title).font(.system(size: 11))
                .foregroundColor(c(active ? theme.chromeForeground : theme.chromeSecondary))
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(active ? c(theme.tabActiveBackground) : .clear)
    }

    private func line(_ segs: [Seg]) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<segs.count, id: \.self) { i in
                switch segs[i] {
                case .caret:
                    Rectangle().fill(c(theme.caret)).frame(width: 1.5, height: 14)
                case let .text(s, kind, mark):
                    Text(s)
                        .foregroundColor(c(kind.flatMap { theme.color($0) } ?? theme.foreground))
                        .background(mark == .selection ? c(theme.selection) : mark == .find ? c(theme.findMatch) : .clear)
                }
            }
        }
        .fixedSize()
    }
}

/// A chip showing a theme's background, text and accent colors.
struct ThemeSwatch: View {
    let theme: Theme

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(nsColor: theme.background))
            .overlay(alignment: .leading) {
                HStack(spacing: 3) {
                    Circle().fill(Color(nsColor: theme.accent)).frame(width: 6, height: 6)
                    Capsule().fill(Color(nsColor: theme.foreground)).frame(width: 10, height: 3)
                }
                .padding(.leading, 5)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
            .frame(width: 34, height: 20)
    }
}
