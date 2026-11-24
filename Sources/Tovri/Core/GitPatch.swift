import Foundation

/// One line of a file's diff. `range` is the line's text, without the leading " ", "+" or "-", as UTF-16
/// offsets into the patch document, so a large patch isn't copied line by line.
struct PatchLine: Equatable {
    enum Kind: UInt8 { case context, added, removed, note }
    var kind: Kind
    /// 1-based line number on the old side, or 0 for an added line.
    var oldNumber: Int32
    /// 1-based line number on the new side, or 0 for a removed line.
    var newNumber: Int32
    var range: NSRange
}

struct PatchHunk: Equatable {
    /// The whole `@@ -10,7 +10,8 @@ func foo` line.
    var header: NSRange
    var oldStart: Int
    var newStart: Int
    var lines: [PatchLine]
}

/// A row of a file's diff as shown: a hunk header, or a line (or, side by side, a pair of lines).
struct DiffRow: Equatable {
    enum Kind: UInt8 { case hunk, line }
    var kind: Kind
    var hunk: Int32
    /// Index into the hunk's lines: the only line when unified, the old side when split. -1 for none.
    var left: Int32
    /// The new side when split.
    var right: Int32
}

/// What a commit's patch says about one file.
struct PatchFile: Equatable {
    /// The 0-based document lines of the `diff --git` line and of the last header line before the hunks.
    var headerLine: Int
    var headerEndLine: Int
    var hunks: [PatchHunk] = []
    /// Shown instead of a diff: "Binary file. Not shown.", a rename without changes, a mode change.
    var note: String?
    var isBinary = false

    /// Lines added and removed, as `numstat` counts them; nil for a binary file.
    var lineCounts: (added: Int, removed: Int)? {
        if isBinary { return nil }
        var added = 0, removed = 0
        for h in hunks { for l in h.lines { if l.kind == .added { added += 1 } else if l.kind == .removed { removed += 1 } } }
        return (added, removed)
    }

    static func == (a: PatchFile, b: PatchFile) -> Bool {
        a.headerLine == b.headerLine && a.headerEndLine == b.headerEndLine && a.hunks == b.hunks && a.note == b.note && a.isBinary == b.isBinary
    }

    var unifiedRowCount: Int { hunks.reduce(0) { $0 + 1 + $1.lines.count } }

    /// Rows side by side: a run of removed lines and the added lines after it share rows.
    var splitRowCount: Int {
        var total = 0
        for hunk in hunks {
            total += 1
            var removed = 0, added = 0
            for line in hunk.lines {
                switch line.kind {
                case .removed: removed += 1
                case .added: added += 1
                case .context, .note:
                    total += max(removed, added) + 1
                    removed = 0
                    added = 0
                }
            }
            total += max(removed, added)
        }
        return total
    }

    func rowCount(split: Bool) -> Int { split ? splitRowCount : unifiedRowCount }

    /// The first `limit` rows. Unified, each line is a row; split, context lines sit on both sides, and a
    /// run of removed lines followed by added lines is zipped row by row, the shorter side left empty.
    func rows(split: Bool, limit: Int) -> [DiffRow] {
        var out: [DiffRow] = []
        out.reserveCapacity(min(limit, rowCount(split: split)))
        for (h, hunk) in hunks.enumerated() {
            if out.count >= limit { break }
            out.append(DiffRow(kind: .hunk, hunk: Int32(h), left: -1, right: -1))
            guard split else {
                for i in hunk.lines.indices {
                    if out.count >= limit { return out }
                    out.append(DiffRow(kind: .line, hunk: Int32(h), left: Int32(i), right: -1))
                }
                continue
            }
            var removed: [Int32] = [], added: [Int32] = []
            func flush() {
                for k in 0..<max(removed.count, added.count) where out.count < limit {
                    out.append(DiffRow(kind: .line, hunk: Int32(h), left: k < removed.count ? removed[k] : -1, right: k < added.count ? added[k] : -1))
                }
                removed.removeAll()
                added.removeAll()
            }
            var previous = PatchLine.Kind.context
            for (i, line) in hunk.lines.enumerated() {
                if out.count >= limit { return out }
                let index = Int32(i)
                switch line.kind {
                case .removed: removed.append(index)
                case .added: added.append(index)
                case .context:
                    flush()
                    if out.count < limit { out.append(DiffRow(kind: .line, hunk: Int32(h), left: index, right: index)) }
                case .note:
                    flush()
                    // "\ No newline at end of file" belongs to the side of the line before it.
                    let side: (Int32, Int32) = previous == .removed ? (index, -1) : previous == .added ? (-1, index) : (index, index)
                    if out.count < limit { out.append(DiffRow(kind: .line, hunk: Int32(h), left: side.0, right: side.1)) }
                }
                if line.kind != .note { previous = line.kind }
            }
            flush()
        }
        return out
    }

    /// Parses the `diff --git` sections of `text`, one entry per section in the order git wrote them.
    static func parse(_ text: String) -> [PatchFile] {
        let u = Array(text.utf16)
        let n = u.count
        var files: [PatchFile] = []
        var file: PatchFile?
        var hunk: PatchHunk?
        var inHunk = false
        var oldNo = 0, newNo = 0
        var renameFrom: String?, oldMode: String?, newMode: String?
        var isBinary = false, isNew = false, isDeleted = false

        func starts(_ prefix: String, _ s: Int, _ e: Int) -> Bool {
            var i = s
            for c in prefix.utf16 {
                if i >= e || u[i] != c { return false }
                i += 1
            }
            return true
        }
        func tail(_ prefix: String, _ s: Int, _ e: Int) -> String {
            String(decoding: u[(s + prefix.utf16.count)..<e], as: UTF16.self)
        }
        func number(_ i: inout Int, _ e: Int) -> Int? {
            var v = 0, any = false
            while i < e, u[i] >= 48, u[i] <= 57 { v = v * 10 + Int(u[i] - 48); i += 1; any = true }
            return any ? v : nil
        }
        func finishFile() {
            guard var f = file else { return }
            if let h = hunk { f.hunks.append(h) }
            f.isBinary = isBinary
            if f.hunks.isEmpty {
                if isBinary { f.note = "Binary file. Not shown." }
                else if let from = renameFrom { f.note = "Renamed from \(from) without changes" }
                else if let old = oldMode, let new = newMode { f.note = "File mode changed \(old) → \(new)" }
                else if isNew { f.note = "Empty file added" }
                else if isDeleted { f.note = "Empty file deleted" }
            }
            files.append(f)
            file = nil
            hunk = nil
            inHunk = false
            renameFrom = nil; oldMode = nil; newMode = nil
            isBinary = false; isNew = false; isDeleted = false
        }

        var i = 0
        var lineNo = 0
        while i < n {
            let s = i
            while i < n, u[i] != 0x0A { i += 1 }
            let e = i
            i += 1
            defer { lineNo += 1 }
            if starts("diff --git ", s, e) {
                finishFile()
                file = PatchFile(headerLine: lineNo, headerEndLine: lineNo)
                continue
            }
            guard file != nil else { continue }
            if starts("@@ ", s, e) {
                if let h = hunk { file?.hunks.append(h) }
                var p = s + 4
                let a = number(&p, e) ?? 1
                if p < e, u[p] == 0x2C { p += 1; _ = number(&p, e) }
                while p < e, u[p] == 0x20 || u[p] == 0x2B { p += 1 }
                let c = number(&p, e) ?? 1
                hunk = PatchHunk(header: NSRange(location: s, length: e - s), oldStart: a, newStart: c, lines: [])
                oldNo = a
                newNo = c
                inHunk = true
                continue
            }
            if !inHunk {
                file?.headerEndLine = lineNo
                if starts("Binary files ", s, e) || starts("GIT binary patch", s, e) { isBinary = true }
                else if starts("rename from ", s, e) { renameFrom = tail("rename from ", s, e) }
                else if starts("old mode ", s, e) { oldMode = tail("old mode ", s, e) }
                else if starts("new mode ", s, e) { newMode = tail("new mode ", s, e) }
                else if starts("new file mode ", s, e) { isNew = true }
                else if starts("deleted file mode ", s, e) { isDeleted = true }
                continue
            }
            let c: UInt16 = s < e ? u[s] : 0x20
            let text = NSRange(location: min(s + 1, e), length: max(0, e - s - 1))
            switch c {
            case 0x2B:
                hunk?.lines.append(PatchLine(kind: .added, oldNumber: 0, newNumber: Int32(newNo), range: text))
                newNo += 1
            case 0x2D:
                hunk?.lines.append(PatchLine(kind: .removed, oldNumber: Int32(oldNo), newNumber: 0, range: text))
                oldNo += 1
            case 0x5C:
                hunk?.lines.append(PatchLine(kind: .note, oldNumber: 0, newNumber: 0, range: NSRange(location: s, length: e - s)))
            default:
                hunk?.lines.append(PatchLine(kind: .context, oldNumber: Int32(oldNo), newNumber: Int32(newNo), range: text))
                oldNo += 1
                newNo += 1
            }
        }
        finishFile()
        return files
    }

    /// Files start collapsed, so opening a commit draws nothing but headers. A commit with one file opens it.
    static func defaultExpansion(_ files: [PatchFile], count: Int) -> [Bool] {
        Array(repeating: count == 1, count: count)
    }
}
