import AppKit

/// Semantic token classes produced by the lexers and mapped to colors by themes.
enum TokenKind: UInt8, CaseIterable {
    case plain = 0
    case keyword        // control flow and operators-as-words: if, return, in, and
    case storage        // declarations and modifiers: let, var, func, class, public, static
    case type           // built-in or inferred type names
    case function       // function names (calls and definitions)
    case string
    case number
    case comment
    case constant       // true, false, nil, null, self, enum-like constants
    case builtin        // built-in functions and globals: print, len, console
    case variable       // sigil variables: $foo, @bar
    case operatorSymbol
    case punctuation
    case tag            // markup tag names
    case attribute      // markup attribute names
    case property       // object keys: YAML/JSON/TOML/CSS properties
    case preprocessor   // #include, #define, <?php
    case annotation     // @decorators, #[attributes], lifetimes
    case escape         // \n, \u{..} inside strings
    case regex
    case heading        // markdown headings, section headers
    case emphasis
    case strong
    case link
    case code           // markdown inline/fenced code
    case inserted       // diff +
    case deleted        // diff -
    case changed        // diff @@
    case invalid
}

/// Opener of an expression embedded in a string and lexed as code. It is closed by the ")" or "}"
/// matching its last character.
enum Interpolation: UInt8 {
    case none
    case dollarBrace     // ${expr}
    case hashBrace       // #{expr}
    case backslashParen  // \(expr)
    case dollarParen     // $(command)
    case brace           // {expr}, where {{ is a literal brace

    var start: UInt16 {
        switch self {
        case .none: return 0
        case .dollarBrace, .dollarParen: return 36
        case .hashBrace: return 35
        case .backslashParen: return 92
        case .brace: return 123
        }
    }

    /// Second character of two-character openers, 0 otherwise.
    var next: UInt16 {
        switch self {
        case .dollarBrace, .hashBrace: return 123
        case .backslashParen, .dollarParen: return 40
        case .none, .brace: return 0
        }
    }

    var length: Int { next == 0 ? 1 : 2 }
    var bracket: UInt16 { next == 0 ? start : next }
    var close: UInt16 { bracket == 40 ? 41 : 125 }
}

struct StringRule {
    let open: [UInt16]
    let close: [UInt16]
    let kind: TokenKind
    let interpolation: Interpolation
    // The boolean options share one byte. The lexer copies a rule for every string it opens, and
    // each additional stored field measurably slows lexing in every language.
    private let options: UInt8

    var escape: Bool { options & 1 != 0 }
    var multiline: Bool { options & 2 != 0 }
    /// Character literal: if the close is not found within a few characters the opener is
    /// treated as punctuation (Rust lifetimes, generics in some languages).
    var isChar: Bool { options & 4 != 0 }
    /// Sigil variables ($name, ${name}) are highlighted inside the string.
    var variables: Bool { options & 8 != 0 }

    init(_ open: String, _ close: String? = nil, escape: Bool = true, multiline: Bool = false,
         kind: TokenKind = .string, isChar: Bool = false, interpolation: Interpolation = .none, variables: Bool = false) {
        self.open = Array(open.utf16)
        self.close = Array((close ?? open).utf16)
        self.kind = kind
        self.interpolation = interpolation
        options = (escape ? 1 : 0) | (multiline ? 2 : 0) | (isChar ? 4 : 0) | (variables ? 8 : 0)
    }
}

enum LexerStyle {
    case code, markup, markdown, plain, findResults
}

enum PropertyKeys {
    case none
    case colon      // key: value (YAML, CSS)
    case equals     // key = value (INI, TOML, properties)
    case jsonKeys   // "key": value
}

final class Language {
    let id: String
    let name: String
    var aliases: [String] = []
    var extensions: [String] = []
    var filenames: [String] = []
    var filenamePrefixes: [String] = []
    var shebangs: [String] = []

    var style: LexerStyle = .code
    var lineComment: [String] = []
    var blockComment: [(String, String)] = []
    var nestedComments = false
    var strings: [StringRule] = []

    var keywords: [String] = []
    var storage: [String] = []
    var types: [String] = []
    var constants: [String] = []
    var builtins: [String] = []
    var caseInsensitive = false

    /// Extra characters allowed anywhere in identifiers (e.g. "$" for JS, "-" for CSS).
    var identifierChars: String = ""
    /// Extra characters allowed only after the first identifier character (e.g. "?!" for Ruby).
    var identifierPartChars: String = ""
    var variablePrefixes: String = ""
    var annotationPrefix: String = ""
    /// Rust-style `#[attr]` / `#![attr]` attributes.
    var hashAttributes = false
    var preprocessor = false
    var functionCalls = true
    var capitalizedTypes = false
    var functionDefKeywords: [String] = []
    var typeDefKeywords: [String] = []
    var propertyKeys: PropertyKeys = .none
    var sectionHeaders = false
    var regexLiterals = false
    var stringPrefixes: String = ""
    /// String prefix characters that make a string raw, so escapes are not highlighted (r"", @"").
    var rawStringPrefixes: String = ""
    /// In raw strings a backslash still keeps the next quote from closing the string (Python).
    /// Otherwise a backslash in a raw string is an ordinary character (Rust, C#).
    var rawStringBackslashQuotes = false
    /// When set, string interpolation is only active after one of these prefixes (f"", $"").
    var interpolationPrefixes: String = ""
    /// Heredoc operator ("<<" or "<<<"): lines up to the delimiter line are a string.
    var heredoc: String = ""
    var heredocAllowsSpace = false
    /// Line comments only start a word, so `a#b` and `url#frag` are not comments (shell, YAML).
    var commentsNeedSpace = false
    /// YAML `|` and `>` block scalars: the more-indented lines that follow are strings.
    var blockScalars = false
    /// Keywords only count as the first word of a line (Dockerfile instructions, dotenv export).
    var keywordsAtLineStart = false
    /// C++14 digit separators: 1'000'000.
    var quoteDigitSeparators = false
    /// Make-style $(NAME) variable references.
    var parenVariables = false
    var cssMode = false
    var linePrefixRules: [(String, TokenKind)] = []
    var operatorChars: String = "+-*/%=&|^!<>~?:"

    var indentAfter: String = "{[("
    var indentAfterColon = false
    var dedentChars: String = "}])"
    var autoPairs: String = "()[]{}\"\"''"
    var symbolPattern: String?

    /// Markup only: language ids for embedded `<script>` and `<style>` content.
    var embeddedScript: String?
    var embeddedStyle: String?

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    static func make(_ id: String, _ name: String, _ configure: (Language) -> Void) -> Language {
        let l = Language(id: id, name: name)
        configure(l)
        return l
    }

    // MARK: Compiled lookup tables (built lazily, used by the lexer)

    private(set) lazy var wordTable: [UInt64: TokenKind] = {
        var t: [UInt64: TokenKind] = [:]
        func add(_ words: [String], _ kind: TokenKind) {
            for w in words { t[Language.hash(w, caseInsensitive: caseInsensitive)] = kind }
        }
        add(builtins, .builtin)
        add(types, .type)
        add(constants, .constant)
        add(storage, .storage)
        add(keywords, .keyword)
        return t
    }()

    private(set) lazy var functionDefHashes: Set<UInt64> = Set(functionDefKeywords.map { Language.hash($0, caseInsensitive: caseInsensitive) })
    private(set) lazy var typeDefHashes: Set<UInt64> = Set(typeDefKeywords.map { Language.hash($0, caseInsensitive: caseInsensitive) })

    private(set) lazy var lineCommentUnits: [[UInt16]] = lineComment.map { Array($0.utf16) }
    private(set) lazy var blockCommentUnits: [([UInt16], [UInt16])] = blockComment.map { (Array($0.0.utf16), Array($0.1.utf16)) }
    private(set) lazy var linePrefixUnits: [([UInt16], TokenKind)] = linePrefixRules.map { (Array($0.0.utf16), $0.1) }

    private(set) lazy var identStartSet: Set<UInt16> = Set(identifierChars.utf16)
    private(set) lazy var identPartSet: Set<UInt16> = Set(identifierChars.utf16).union(identifierPartChars.utf16)
    private(set) lazy var variablePrefixSet: Set<UInt16> = Set(variablePrefixes.utf16)
    private(set) lazy var annotationPrefixSet: Set<UInt16> = Set(annotationPrefix.utf16)
    private(set) lazy var stringPrefixSet: Set<UInt16> = Set(stringPrefixes.utf16)
    private(set) lazy var operatorSet: Set<UInt16> = Set(operatorChars.utf16)

    /// Sorted so longer openers (""") win over shorter ones (").
    private(set) lazy var sortedStringRules: [(index: Int, rule: StringRule)] =
        strings.enumerated().map { ($0.offset, $0.element) }.sorted { $0.rule.open.count > $1.rule.open.count }

    private(set) lazy var symbolRegex: NSRegularExpression? = {
        let pattern = symbolPattern ?? Language.defaultSymbolPattern
        return try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }()

    static let defaultSymbolPattern =
        #"^[ \t]*(?:(?:export|public|private|protected|internal|fileprivate|open|static|final|abstract|async|override|default|pub(?:\([a-z]+\))?|unsafe|extern|inline|virtual|const)\s+)*(?:func|function|def|fn|class|struct|enum|interface|trait|protocol|extension|impl|module|object|type|record|union|namespace|macro|proc|sub)\s+([A-Za-z_$][\w$]*)"#

    static func hash(_ word: String, caseInsensitive: Bool) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for u in word.utf16 {
            var c = u
            if caseInsensitive, c >= 65, c <= 90 { c += 32 }
            h = (h ^ UInt64(c)) &* 0x100000001b3
        }
        return h
    }

    var lexer: Lexer {
        if let l = _lexer { return l }
        let l: Lexer
        switch style {
        case .code: l = CodeLexer(language: self)
        case .markup: l = MarkupLexer(language: self)
        case .markdown: l = MarkdownLexer(language: self)
        case .findResults: l = FindResultsLexer()
        case .plain: l = PlainLexer()
        }
        _lexer = l
        return l
    }
    private var _lexer: Lexer?

    var primaryLineComment: String? { lineComment.first }
    var primaryBlockComment: (String, String)? { blockComment.first }
}

/// Resolves languages by file name, extension, shebang or name.
final class LanguageRegistry {
    static let shared = LanguageRegistry()

    let all: [Language]
    let plain: Language
    let findResults: Language
    private var byExtension: [String: Language] = [:]
    private var byFilename: [String: Language] = [:]
    private var byId: [String: Language] = [:]
    private var byShebang: [String: Language] = [:]

    private init() {
        plain = Language.make("plain", "Plain Text") { $0.style = .plain; $0.extensions = ["txt", "text", "log"] }
        findResults = Language.make("find-results", "Find Results") { $0.style = .findResults }
        var langs = Languages.all
        langs.append(plain)
        all = langs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for l in all {
            byId[l.id.lowercased()] = l
            for a in l.aliases { byId[a.lowercased()] = l }
            for e in l.extensions where byExtension[e.lowercased()] == nil { byExtension[e.lowercased()] = l }
            for f in l.filenames { byFilename[f.lowercased()] = l }
            for s in l.shebangs { byShebang[s] = l }
        }
        byId[findResults.id] = findResults
    }

    func language(id: String) -> Language? { byId[id.lowercased()] }

    func language(forFileName name: String, firstLine: String? = nil) -> Language {
        let lower = name.lowercased()
        if let l = byFilename[lower] { return l }
        for l in all {
            for p in l.filenamePrefixes where lower.hasPrefix(p.lowercased()) { return l }
        }
        // Try compound extensions first (e.g. "d.ts", "blade.php"), then the last one.
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1 {
            for i in 1..<parts.count {
                let ext = parts[i...].joined(separator: ".")
                if let l = byExtension[ext] { return l }
            }
        }
        if let line = firstLine, let l = language(forFirstLine: line) { return l }
        if lower.hasPrefix(".") && !lower.dropFirst().contains(".") {
            if let l = byExtension[String(lower.dropFirst())] { return l }
        }
        return plain
    }

    func language(forFirstLine line: String) -> Language? {
        if line.hasPrefix("#!") {
            let parts = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "/" })
            var interpreter = parts.last.map(String.init) ?? ""
            if let envIndex = parts.firstIndex(of: "env"), envIndex + 1 < parts.count {
                interpreter = String(parts[envIndex + 1])
                if interpreter == "-S", envIndex + 2 < parts.count { interpreter = String(parts[envIndex + 2]) }
            }
            if let l = byShebang[interpreter] { return l }
            let stripped = interpreter.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789."))
            return byShebang[stripped]
        }
        if line.hasPrefix("<?xml") { return byId["xml"] }
        if line.lowercased().hasPrefix("<!doctype html") { return byId["html"] }
        return nil
    }
}
