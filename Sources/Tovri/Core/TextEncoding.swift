import Foundation

enum TextEncoding: String, CaseIterable {
    case utf8 = "UTF-8"
    case utf8BOM = "UTF-8 with BOM"
    case utf16LE = "UTF-16 LE"
    case utf16BE = "UTF-16 BE"
    case windows1252 = "Windows 1252"
    case latin1 = "ISO 8859-1"
    case macRoman = "Mac Roman"
    case shiftJIS = "Shift JIS"
    case gb18030 = "GB 18030"
    case eucKR = "EUC-KR"

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .windows1252: return .windowsCP1252
        case .latin1: return .isoLatin1
        case .macRoman: return .macOSRoman
        case .shiftJIS: return .shiftJIS
        case .gb18030:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .eucKR:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
        }
    }

    var bom: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        default: return []
        }
    }

    struct Decoded {
        var text: String
        var encoding: TextEncoding
        var isBinary: Bool
    }

    static func decode(_ data: Data, preferred: TextEncoding? = nil) -> Decoded {
        if var p = preferred {
            if p == .utf8 && data.starts(with: TextEncoding.utf8BOM.bom) { p = .utf8BOM }
            let body = data.starts(with: p.bom) && !p.bom.isEmpty ? data.dropFirst(p.bom.count) : data
            if let s = p.string(from: body) { return Decoded(text: s, encoding: p, isBinary: false) }
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = TextEncoding.utf8BOM.string(from: data.dropFirst(3)) {
            return Decoded(text: s, encoding: .utf8BOM, isBinary: false)
        }
        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return Decoded(text: s, encoding: .utf16LE, isBinary: false)
        }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return Decoded(text: s, encoding: .utf16BE, isBinary: false)
        }
        let binary = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress, raw.count > 0 else { return false }
            return memchr(base, 0, min(raw.count, 8192)) != nil
        }
        if !binary, let s = TextEncoding.utf8.string(from: data) {
            return Decoded(text: s, encoding: .utf8, isBinary: false)
        }
        if !binary, let s = String(data: data, encoding: .windowsCP1252) {
            return Decoded(text: s, encoding: .windows1252, isBinary: false)
        }
        let s = String(data: data, encoding: .isoLatin1) ?? ""
        return Decoded(text: s, encoding: .latin1, isBinary: binary)
    }

    /// Decodes the bytes after any BOM. Foundation silently drops a leading UTF-8 BOM, so one that is
    /// part of the text (e.g. a doubled BOM) is put back to keep saving byte-exact.
    private func string(from body: Data) -> String? {
        guard let s = String(data: body, encoding: stringEncoding) else { return nil }
        if stringEncoding == .utf8 && body.starts(with: [0xEF, 0xBB, 0xBF]) && s.utf8.count == body.count - 3 { return "\u{FEFF}" + s }
        return s
    }

    func encode(_ text: String) -> Data? {
        // The explicit-endian UTF-16 encodings never emit a BOM, so a leading U+FEFF here is text.
        guard let data = text.data(using: stringEncoding, allowLossyConversion: false) else { return nil }
        return bom.isEmpty ? data : Data(bom) + data
    }
}

enum LineEnding: String, CaseIterable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"

    var string: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    var displayName: String {
        switch self {
        case .lf: return "LF (macOS / Unix)"
        case .crlf: return "CRLF (Windows)"
        case .cr: return "CR (Classic Mac)"
        }
    }

    /// Detects the line ending and returns text normalized to LF.
    static func normalize(_ text: String, rawData: Data?) -> (String, LineEnding) {
        if let data = rawData {
            let hasCR = data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress, raw.count > 0 else { return false }
                return memchr(base, 13, raw.count) != nil
            }
            if !hasCR { return (text, .lf) }
        }
        // CRLF is a single Swift Character, so String.contains("\r") misses it.
        // Foundation searches code units and also handles mixed newline conventions.
        let source = text as NSString
        guard source.range(of: "\r").location != NSNotFound else { return (text, .lf) }
        let ns = NSMutableString(string: text)
        let crlf = ns.replaceOccurrences(of: "\r\n", with: "\n", options: .literal, range: NSRange(location: 0, length: ns.length))
        let cr = ns.replaceOccurrences(of: "\r", with: "\n", options: .literal, range: NSRange(location: 0, length: ns.length))
        let lf = lineFeeds(in: source) - crlf
        // The buffer keeps one convention, so a mixed file is saved with the one most lines already use.
        let ending: LineEnding = crlf >= lf && crlf >= cr ? .crlf : (lf >= cr ? .lf : .cr)
        return (ns as String, ending)
    }

    private static func lineFeeds(in s: NSString) -> Int {
        let chunk = 1 << 16
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var count = 0
        var pos = 0
        while pos < s.length {
            let len = min(chunk, s.length - pos)
            s.getCharacters(buf, range: NSRange(location: pos, length: len))
            for i in 0..<len where buf[i] == 10 { count += 1 }
            pos += len
        }
        return count
    }
}
