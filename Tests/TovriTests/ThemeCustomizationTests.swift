import AppKit
import XCTest
@testable import Tovri

final class ThemeCustomizationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("tovri-themes-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func hex(_ c: NSColor?) -> String? { c?.hexString }

    func testHexStringRoundTripsWithAndWithoutAlpha() {
        XCTAssertEqual(NSColor(hex: "#1A2B3C").hexString, "#1A2B3C")
        XCTAssertEqual(NSColor(hex: "#1A2B3C80").hexString, "#1A2B3C80")
        XCTAssertEqual(NSColor(hex: "#abc").hexString, "#AABBCC")
    }

    func testBuiltInThemeRebuiltFromItsDefinitionHasTheSameColors() throws {
        for builtIn in Themes.all {
            let data = try JSONEncoder().encode(builtIn.definition)
            let decoded = try JSONDecoder().decode(ThemeDefinition.self, from: data)
            XCTAssertEqual(decoded, builtIn.definition, builtIn.name)
            let rebuilt = Theme(definition: decoded)
            XCTAssertTrue(rebuilt.isCustom)
            XCTAssertEqual(rebuilt.isDark, builtIn.isDark)
            XCTAssertEqual(rebuilt.translucent, builtIn.translucent, builtIn.name)
            for (a, b) in [(rebuilt.background, builtIn.background), (rebuilt.selection, builtIn.selection),
                           (rebuilt.chromeBackground, builtIn.chromeBackground), (rebuilt.gutterForeground, builtIn.gutterForeground),
                           (rebuilt.findCurrent, builtIn.findCurrent)] {
                XCTAssertEqual(hex(a), hex(b), builtIn.name)
            }
            for kind in TokenKind.allCases {
                XCTAssertEqual(hex(rebuilt.color(kind)), hex(builtIn.color(kind)), "\(builtIn.name) \(kind)")
            }
        }
    }

    func testMinimalThemeFileDecodesAndDerivesTheRest() throws {
        let json = ##"{"name":"Mine","dark":true,"background":"#101010","foreground":"#EEEEEE","accent":"#FF8800"}"##
        let def = try XCTUnwrap(try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8)).validated())
        let theme = Theme(definition: def)
        XCTAssertEqual(theme.background.hexString, "#101010")
        XCTAssertNotNil(theme.color(.keyword) ?? theme.color(.punctuation))
        XCTAssertFalse(theme.translucent)
    }

    func testValidationRejectsMalformedColorsAndNames() {
        let good = ThemeDefinition(name: "Ok", dark: false, background: "#FFFFFF", foreground: "#000000", accent: "#0000FF")
        XCTAssertNotNil(good.validated())

        var bad = good
        bad.background = "red"
        XCTAssertNil(bad.validated())

        bad = good
        bad.ui.gutter = "#12345"
        XCTAssertNil(bad.validated())

        bad = good
        bad.name = "  \n "
        XCTAssertNil(bad.validated())

        bad = good
        bad.name = String(repeating: "x", count: ThemeDefinition.maxNameLength + 1)
        XCTAssertNil(bad.validated())

        var tokens = good
        tokens.tokens = ["keyword": "#FF0000", "bogus": "#00FF00", "string": "nope", "plain": "#111111"]
        XCTAssertEqual(tokens.validated()?.tokens, ["keyword": "#FF0000"])

        var named = good
        named.name = "  Tab\tName  "
        XCTAssertEqual(named.validated()?.name, "TabName")
    }

    func testStoreSavesReplacesAndDeletesByName() throws {
        let store = CustomThemeStore(directory: tempDir)
        var def = ThemeDefinition(name: "Night/Owl: 1", dark: true, background: "#000000", foreground: "#FFFFFF", accent: "#00FF00")
        try store.save(def)
        XCTAssertEqual(store.load().map(\.name), ["Night/Owl: 1"])
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(files, ["Night-Owl- 1.json"])

        def.accent = "#FF0000"
        try store.save(def)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.load().first?.accent, "#FF0000")

        // A different name that sanitizes to the same file name gets its own file.
        var other = def
        other.name = "Night:Owl/ 1"
        try store.save(other)
        XCTAssertEqual(Set(store.load().map(\.name)), ["Night/Owl: 1", "Night:Owl/ 1"])

        // Saving again overwrites the theme's own file rather than deleting it first.
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: tempDir.path))
        try store.save(other)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: tempDir.path)), before)

        try store.delete(named: "Night/Owl: 1")
        XCTAssertEqual(store.load().map(\.name), ["Night:Owl/ 1"])
    }

    func testStoreSkipsInvalidAndHiddenNameFiles() throws {
        let store = CustomThemeStore(directory: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: tempDir.appendingPathComponent("broken.json"))
        try Data(##"{"name":"X","dark":true,"background":"evil","foreground":"#FFF","accent":"#FFF"}"##.utf8)
            .write(to: tempDir.appendingPathComponent("bad.json"))
        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(CustomThemeStore.fileName(for: "../.hidden"), "-.hidden.json")
        XCTAssertEqual(CustomThemeStore.fileName(for: "..."), "Theme.json")
    }

    func testEditorCopyPicksAnUnusedName() {
        let themes = Themes.all
        let base = themes[0]
        let s = ThemeEditorSession.copy(of: base, among: themes + [Theme(name: "\(base.name) Custom", dark: true, background: "#000", foreground: "#FFF", accent: "#F00", tokens: [:], custom: true)])
        XCTAssertEqual(s.definition.name, "\(base.name) Custom 2")
        XCTAssertNil(s.originalName)
    }
}

final class SettingsBackupTests: XCTestCase {
    private var suites: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "tovri-backup-tests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for s in suites { UserDefaults.standard.removePersistentDomain(forName: s) }
        suites = []
    }

    func testExportListsOnlyChangedSettings() {
        let d = makeDefaults()
        d.set(true, forKey: Settings.Key.wordWrap)
        d.set(Settings.defaults[Settings.Key.showMinimap] as! Bool, forKey: Settings.Key.showMinimap)
        d.set(2, forKey: Settings.Key.tabWidth)
        d.set(15.0, forKey: Settings.Key.fontSize)
        d.set("Dracula", forKey: Settings.Key.theme)
        d.set(["File/Save": "s\u{1}1048576"], forKey: KeyBindings.storeKey)
        let b = SettingsBackup.make(from: d, themes: [])
        XCTAssertEqual(b.settings, [
            Settings.Key.wordWrap: .bool(true),
            Settings.Key.tabWidth: .number(2),
            Settings.Key.fontSize: .number(15),
            Settings.Key.theme: .string("Dracula"),
        ])
        XCTAssertEqual(b.keyBindings, ["File/Save": "s\u{1}1048576"])
    }

    func testRoundTripReplacesSettingsAndResetsTheRest() throws {
        let source = makeDefaults()
        source.set(true, forKey: Settings.Key.wordWrap)
        source.set(8, forKey: Settings.Key.tabWidth)
        source.set("node_modules", forKey: Settings.Key.searchExcludes)
        source.set(["Edit/Copy": ""], forKey: KeyBindings.storeKey)
        let theme = ThemeDefinition(name: "Mine", dark: true, background: "#000000", foreground: "#FFFFFF", accent: "#00FF00")
        let data = try SettingsBackup.make(from: source, themes: [theme]).encoded()

        let target = makeDefaults()
        target.set(true, forKey: Settings.Key.showInvisibles)
        target.set(["Old/Thing": "x\u{1}1048576"], forKey: KeyBindings.storeKey)
        let decoded = try SettingsBackup.decode(data)
        XCTAssertEqual(decoded.themes, [theme])
        decoded.apply(to: target)

        XCTAssertTrue(target.bool(forKey: Settings.Key.wordWrap))
        XCTAssertEqual(target.integer(forKey: Settings.Key.tabWidth), 8)
        XCTAssertTrue(target.object(forKey: Settings.Key.tabWidth) is NSNumber)
        XCTAssertEqual(target.string(forKey: Settings.Key.searchExcludes), "node_modules")
        let stored = UserDefaults.standard.persistentDomain(forName: suites.last!) ?? [:]
        XCTAssertNil(stored[Settings.Key.showInvisibles], "a setting missing from the file should go back to its default")
        XCTAssertEqual(target.dictionary(forKey: KeyBindings.storeKey) as? [String: String], ["Edit/Copy": ""])
    }

    func testDecodeDropsWhatItCannotUse() throws {
        let json = """
        {
          "format": "tovri-settings",
          "version": 1,
          "settings": {
            "wordWrap": 1,
            "tabWidth": 4.6,
            "fontSize": "huge",
            "theme": "Nord",
            "unknownKey": true,
            "showMinimap": false,
            "rulerColumn": {"nested": true}
          },
          "keyBindings": {"A/B": "garbage", "C/D": "k\\u00011048576", "E/F": ""},
          "themes": [
            {"name": "Good", "dark": false, "background": "#FFF", "foreground": "#000", "accent": "#00F"},
            {"name": "Bad", "dark": false, "background": "nope", "foreground": "#000", "accent": "#00F"},
            {"oops": true},
            {"name": "Good", "dark": true, "background": "#000", "foreground": "#FFF", "accent": "#00F"}
          ]
        }
        """
        let b = try SettingsBackup.decode(Data(json.utf8))
        XCTAssertEqual(b.settings, [Settings.Key.tabWidth: .number(5), Settings.Key.theme: .string("Nord"), Settings.Key.showMinimap: .bool(false)])
        XCTAssertEqual(b.keyBindings, ["C/D": "k\u{1}1048576", "E/F": ""])
        XCTAssertEqual(b.themes.map(\.name), ["Good"])
        XCTAssertEqual(b.themes.first?.dark, false)
    }

    func testDecodeClampsNumbersToWhatSettingsAccepts() throws {
        let json = ##"{"format":"tovri-settings","settings":{"fontSize":1e300,"lineHeight":-4,"tabWidth":900,"rulerColumn":-3}}"##
        let b = try SettingsBackup.decode(Data(json.utf8))
        XCTAssertEqual(b.settings[Settings.Key.fontSize], .number(72))
        XCTAssertEqual(b.settings[Settings.Key.lineHeight], .number(1))
        XCTAssertEqual(b.settings[Settings.Key.tabWidth], .number(16))
        XCTAssertEqual(b.settings[Settings.Key.rulerColumn], .number(0))
    }

    func testDecodeRejectsOtherFiles() {
        XCTAssertThrowsError(try SettingsBackup.decode(Data("[]".utf8)))
        XCTAssertThrowsError(try SettingsBackup.decode(Data(#"{"format":"something-else"}"#.utf8)))
        XCTAssertThrowsError(try SettingsBackup.decode(Data(count: SettingsBackup.maxFileSize + 1)))
    }
}
