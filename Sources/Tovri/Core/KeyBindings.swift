import AppKit
import Combine

struct KeyShortcut: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.intersection(KeyShortcut.relevant)
    }

    init?(item: NSMenuItem) {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var mods = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        if key.count == 1, let c = key.first, c.isUppercase { mods.insert(.shift); key = key.lowercased() }
        self.init(key: key, modifiers: mods)
    }

    init?(storage: String) {
        let parts = storage.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let raw = UInt(parts[1]), !parts[0].isEmpty else { return nil }
        self.init(key: String(parts[0]), modifiers: NSEvent.ModifierFlags(rawValue: raw))
    }

    var storage: String { key + "\u{1}" + String(modifiers.rawValue) }

    var display: String { KeyShortcut.display(key: key, modifiers: modifiers) }

    static func display(key: String, modifiers m: NSEvent.ModifierFlags) -> String {
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let code = key.unicodeScalars.first.map { Int($0.value) } ?? 0
        switch code {
        case NSUpArrowFunctionKey: return s + "↑"
        case NSDownArrowFunctionKey: return s + "↓"
        case NSLeftArrowFunctionKey: return s + "←"
        case NSRightArrowFunctionKey: return s + "→"
        case NSPageUpFunctionKey: return s + "⇞"
        case NSPageDownFunctionKey: return s + "⇟"
        case NSHomeFunctionKey: return s + "↖"
        case NSEndFunctionKey: return s + "↘"
        case 13, 3: return s + "↩"
        case 9: return s + "⇥"
        case 27: return s + "⎋"
        case 8, 127: return s + "⌫"
        case NSDeleteFunctionKey: return s + "⌦"
        case 32: return s + "Space"
        case NSF1FunctionKey...NSF20FunctionKey: return s + "F\(code - NSF1FunctionKey + 1)"
        default: return s + key.uppercased()
        }
    }

    /// Builds a shortcut from a key event, or nil if it isn't a usable menu shortcut.
    static func from(event: NSEvent) -> KeyShortcut? {
        let mods = event.modifierFlags.intersection(relevant)
        guard var chars = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        let code = chars.unicodeScalars.first.map { Int($0.value) } ?? 0
        let isFunctionKey = (NSF1FunctionKey...NSF20FunctionKey).contains(code)
        let isNav = [NSUpArrowFunctionKey, NSDownArrowFunctionKey, NSLeftArrowFunctionKey, NSRightArrowFunctionKey,
                     NSPageUpFunctionKey, NSPageDownFunctionKey, NSHomeFunctionKey, NSEndFunctionKey].contains(code)
        let hasCommandish = mods.contains(.command) || mods.contains(.control) || mods.contains(.option)
        guard hasCommandish || isFunctionKey || (isNav && !mods.isEmpty) else { return nil }
        if code == 25 { chars = "\t" }
        return KeyShortcut(key: chars.lowercased(), modifiers: mods)
    }
}

struct CommandBinding: Identifiable {
    let id: String
    let title: String
    let path: String
    let defaultShortcut: KeyShortcut?
    var shortcut: KeyShortcut?
    var isCustomized: Bool { shortcut != defaultShortcut }
}

/// User-customizable shortcuts for every menu command. Defaults are captured from the menu as
/// built; overrides are stored in UserDefaults and applied to the live menu immediately.
final class KeyBindings: ObservableObject {
    static let shared = KeyBindings()

    @Published private(set) var commands: [CommandBinding] = []
    private var defaults: [String: KeyShortcut?] = [:]
    private var overrides: [String: String]
    static let storeKey = "keyBindings"
    private var storeKey: String { KeyBindings.storeKey }
    private weak var menu: NSMenu?

    private init() {
        overrides = UserDefaults.standard.dictionary(forKey: KeyBindings.storeKey) as? [String: String] ?? [:]
    }

    /// Picks up overrides written to UserDefaults directly, such as by a settings import.
    func reloadFromDefaults() {
        overrides = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        apply()
    }

    private static let skippedSubmenus: Set<String> = ["Services", "Open Recent"]
    private static let skippedActions: Set<String> = ["setSyntaxFromMenu:", "setThemeFromMenu:", "openRecentItem:"]

    private func walk(_ menu: NSMenu, path: [String], _ visit: (NSMenuItem, String, String) -> Void) {
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let sub = item.submenu {
                if KeyBindings.skippedSubmenus.contains(item.title) { continue }
                walk(sub, path: path + [item.title], visit)
                continue
            }
            guard let action = item.action, !item.title.isEmpty,
                  !KeyBindings.skippedActions.contains(NSStringFromSelector(action)) else { continue }
            let p = path.joined(separator: " › ")
            visit(item, p + "/" + item.title, p)
        }
    }

    func install(on menu: NSMenu) {
        self.menu = menu
        walk(menu, path: []) { item, id, _ in
            if defaults[id] == nil { defaults[id] = .some(KeyShortcut(item: item)) }
        }
        apply()
    }

    private func current(for id: String) -> KeyShortcut? {
        if let o = overrides[id] { return KeyShortcut(storage: o) }
        return defaults[id] ?? nil
    }

    private func apply() {
        guard let menu else { return }
        var list: [CommandBinding] = []
        walk(menu, path: []) { item, id, path in
            let sc = current(for: id)
            item.keyEquivalent = sc?.key ?? ""
            item.keyEquivalentModifierMask = sc?.modifiers ?? []
            list.append(CommandBinding(id: id, title: item.title, path: path, defaultShortcut: defaults[id] ?? nil, shortcut: sc))
        }
        commands = list
    }

    func set(_ shortcut: KeyShortcut?, for id: String) {
        let def = defaults[id] ?? nil
        if shortcut == def { overrides.removeValue(forKey: id) } else { overrides[id] = shortcut?.storage ?? "" }
        persist()
        apply()
    }

    func reset(_ id: String) {
        overrides.removeValue(forKey: id)
        persist()
        apply()
    }

    func resetAll() {
        overrides.removeAll()
        persist()
        apply()
    }

    func conflicts(for shortcut: KeyShortcut?, excluding id: String) -> [CommandBinding] {
        guard let shortcut else { return [] }
        return commands.filter { $0.id != id && $0.shortcut == shortcut }
    }

    private func persist() {
        UserDefaults.standard.set(overrides, forKey: storeKey)
    }
}

/// Click to record a shortcut; Esc cancels, ⌫ clears.
final class ShortcutRecorderField: NSView {
    var shortcut: KeyShortcut? { didSet { needsDisplay = true } }
    var onChange: ((KeyShortcut?) -> Void)?
    private var recording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 24) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(KeyShortcut.relevant)
        if event.keyCode == 53 && mods.isEmpty {
            recording = false
            window?.makeFirstResponder(nil)
            return
        }
        if (event.keyCode == 51 || event.keyCode == 117) && mods.isEmpty {
            shortcut = nil
            onChange?(nil)
            recording = false
            window?.makeFirstResponder(nil)
            return
        }
        guard let sc = KeyShortcut.from(event: event) else { NSSound.beep(); return }
        shortcut = sc
        onChange?(sc)
        recording = false
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
        let text: String
        let color: NSColor
        if recording { text = "Type shortcut…"; color = .controlAccentColor }
        else if let s = shortcut { text = s.display; color = .labelColor }
        else { text = "—"; color = .tertiaryLabelColor }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: recording ? .regular : .medium), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
