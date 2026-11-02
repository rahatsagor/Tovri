import Foundation

/// A settings file: the preferences someone changed, their key bindings and their custom themes.
struct SettingsBackup: Codable, Equatable {
    static let formatName = "tovri-settings"
    static let currentVersion = 1
    static let maxFileSize = 8 * 1024 * 1024

    enum Value: Codable, Equatable {
        case bool(Bool)
        case number(Double)
        case string(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else { self = .string(try c.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .bool(let b): try c.encode(b)
            case .number(let n): try c.encode(n)
            case .string(let s): try c.encode(s)
            }
        }
    }

    enum Failure: LocalizedError {
        case tooLarge
        case notASettingsFile

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "This file is too large to be a Tovri settings file."
            case .notASettingsFile: return "This file isn't a Tovri settings file. Choose a file made with Export Settings."
            }
        }
    }

    var format: String = SettingsBackup.formatName
    var version: Int = SettingsBackup.currentVersion
    var settings: [String: Value] = [:]
    var keyBindings: [String: String] = [:]
    var themes: [ThemeDefinition] = []

    private static let maxStringLength = 10_000
    private static let maxKeyBindings = 2_000

    /// Captures the settings that differ from their defaults, so a file made today doesn't pin
    /// defaults a later version of Tovri improves.
    static func make(from d: UserDefaults, themes: [ThemeDefinition]) -> SettingsBackup {
        var b = SettingsBackup()
        for (key, def) in Settings.defaults where d.object(forKey: key) != nil {
            switch def {
            case let v as Bool where d.bool(forKey: key) != v: b.settings[key] = .bool(d.bool(forKey: key))
            case let v as Int where d.integer(forKey: key) != v: b.settings[key] = .number(Double(d.integer(forKey: key)))
            case let v as Double where d.double(forKey: key) != v: b.settings[key] = .number(d.double(forKey: key))
            case let v as String: if let s = d.string(forKey: key), s != v { b.settings[key] = .string(s) }
            default: break
            }
        }
        b.keyBindings = d.dictionary(forKey: KeyBindings.storeKey) as? [String: String] ?? [:]
        b.themes = themes
        return b
    }

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    /// Reads a settings file. Anything Tovri can't use, such as unknown keys, values of the wrong
    /// type or malformed themes, is dropped rather than failing the whole import.
    static func decode(_ data: Data) throws -> SettingsBackup {
        guard data.count <= maxFileSize else { throw Failure.tooLarge }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.format == formatName else { throw Failure.notASettingsFile }
        var b = SettingsBackup()
        b.version = raw.version ?? currentVersion
        for (key, value) in raw.settings ?? [:] {
            if let v = validated(value, for: key) { b.settings[key] = v }
        }
        for (id, shortcut) in (raw.keyBindings ?? [:]).prefix(maxKeyBindings)
        where id.count <= 500 && (shortcut.isEmpty || KeyShortcut(storage: shortcut) != nil) {
            b.keyBindings[id] = shortcut
        }
        var names = Set<String>()
        b.themes = (raw.themes ?? []).compactMap { $0.flatMap { $0.validated() } }.filter { names.insert($0.name).inserted }
        return b
    }

    /// The values Settings accepts; numbers outside them are clamped so a hand-edited file can't
    /// store a value the settings window can't show (a font size of 1e300 traps in `Int(_:)`).
    static let ranges: [String: ClosedRange<Double>] = [
        Settings.Key.fontSize: 6...72,
        Settings.Key.lineHeight: 1...2.5,
        Settings.Key.tabWidth: 1...16,
        Settings.Key.rulerColumn: 0...500,
        Settings.Key.sidebarWidth: 140...600,
    ]

    private static func validated(_ value: Value, for key: String) -> Value? {
        guard let def = Settings.defaults[key] else { return nil }
        func clamped(_ n: Double) -> Double {
            let r = ranges[key] ?? -1_000_000...1_000_000
            return min(max(n, r.lowerBound), r.upperBound)
        }
        switch (def, value) {
        case (is Bool, .bool): return value
        case (is Int, .number(let n)) where n.isFinite: return .number(clamped(n).rounded())
        case (is Double, .number(let n)) where n.isFinite: return .number(clamped(n))
        case (is String, .string(let s)) where s.count <= maxStringLength: return value
        default: return nil
        }
    }

    /// Replaces preferences and key bindings with the file's. Preferences the file doesn't list go
    /// back to their defaults, the same as on the Mac that made it. Themes are saved separately.
    func apply(to d: UserDefaults) {
        for (key, def) in Settings.defaults {
            switch (def, settings[key]) {
            case (_, .bool(let b)?): d.set(b, forKey: key)
            case (is Int, .number(let n)?): d.set(Int(n), forKey: key)
            case (_, .number(let n)?): d.set(n, forKey: key)
            case (_, .string(let s)?): d.set(s, forKey: key)
            case (_, nil): d.removeObject(forKey: key)
            }
        }
        if keyBindings.isEmpty { d.removeObject(forKey: KeyBindings.storeKey) } else { d.set(keyBindings, forKey: KeyBindings.storeKey) }
    }

    /// Lenient shape for decoding: a theme that fails to decode is skipped, not fatal.
    private struct Raw: Decodable {
        var format: String
        var version: Int?
        var settings: [String: Value]?
        var keyBindings: [String: String]?
        var themes: [ThemeDefinition?]?

        private enum CodingKeys: String, CodingKey { case format, version, settings, keyBindings, themes }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.decode(String.self, forKey: .format)
            version = try? c.decodeIfPresent(Int.self, forKey: .version)
            settings = (try? c.decodeIfPresent([String: Lenient<Value>].self, forKey: .settings))?.compactMapValues(\.value)
            keyBindings = (try? c.decodeIfPresent([String: Lenient<String>].self, forKey: .keyBindings))?.compactMapValues(\.value)
            themes = (try? c.decodeIfPresent([Lenient<ThemeDefinition>].self, forKey: .themes))?.map(\.value)
        }
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}
