import Foundation

extension Notification.Name {
    /// Posted with the document whose bookmarks were added, removed or cleared by a command.
    static let bookmarksDidChange = Notification.Name("TovriBookmarksDidChange")
}

/// A document's bookmarked lines, sorted. Edits move each bookmark with the text of its line, and
/// a bookmark goes away with the line it marks.
final class Bookmarks {
    private(set) var lines: [Int] = []

    var isEmpty: Bool { lines.isEmpty }

    func contains(_ line: Int) -> Bool {
        var lo = 0, hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid] == line { return true }
            if lines[mid] < line { lo = mid + 1 } else { hi = mid - 1 }
        }
        return false
    }

    func set(_ new: [Int], lineCount: Int) {
        lines = Array(Set(new.filter { $0 >= 0 && $0 < lineCount })).sorted()
    }

    /// Bookmarks every line, or removes them when every line already has one. Returns whether
    /// bookmarks were added.
    @discardableResult
    func toggle(_ toggled: [Int]) -> Bool {
        let set = Set(toggled)
        guard !set.isEmpty else { return false }
        if set.allSatisfy(contains) {
            lines.removeAll { set.contains($0) }
            return false
        }
        lines = Array(Set(lines).union(set)).sorted()
        return true
    }

    func clear() { lines = [] }

    /// The first bookmark after `line`, wrapping to the first one in the file.
    func next(after line: Int) -> Int? { lines.first { $0 > line } ?? lines.first }

    /// The last bookmark before `line`, wrapping to the last one in the file.
    func previous(before line: Int) -> Int? { lines.last { $0 < line } ?? lines.last }

    func clamp(lineCount: Int) {
        if let last = lines.last, last >= lineCount { lines.removeAll { $0 >= lineCount } }
    }

    /// Moves bookmarks for an edit that moved whole lines, such as Move Line Up.
    func remap(_ transform: (Int) -> Int) {
        guard !lines.isEmpty else { return }
        lines = Array(Set(lines.map(transform))).sorted()
    }

    /// Adjusts `lines` through multiple disjoint sorted edits in pre-edit coordinates.
    static func adjustedForEdits(_ lines: [Int], edits: [(range: NSRange, replacement: String)],
                                 index: LineIndex, textLength: Int) -> [Int] {
        guard !lines.isEmpty, !edits.isEmpty else { return lines }
        struct Step {
            let firstLine: Int
            let removed: Int
            let inserted: Int
            let editStartsLine: Bool
            let lastLineKeepsText: Bool
        }
        var steps: [Step] = []
        steps.reserveCapacity(edits.count)
        for e in edits {
            let f = index.line(containing: e.range.location)
            let endLoc = NSMaxRange(e.range)
            let lastLine = index.line(containing: endLoc)
            let removed = lastLine - f
            var inserted = 0
            for u in e.replacement.utf16 where u == 10 { inserted += 1 }
            let editStartsLine = e.range.location == index.start(of: f)
            let lastRange = index.range(of: lastLine, textLength: textLength)
            let lastLineKeepsText = endLoc < NSMaxRange(lastRange)
            steps.append(Step(firstLine: f, removed: removed, inserted: inserted,
                              editStartsLine: editStartsLine, lastLineKeepsText: lastLineKeepsText))
        }
        var current = lines
        for step in steps.reversed() {
            current = adjusted(current, firstLine: step.firstLine, removed: step.removed, inserted: step.inserted,
                               editStartsLine: step.editStartsLine, lastLineKeepsText: step.lastLineKeepsText)
            if current.isEmpty { break }
        }
        return current
    }

    /// Follows an edit, after `lines` was updated for it. `change` is what `LineIndex.update` returned.
    func adjust(editedRange: NSRange, delta: Int, change: (firstLine: Int, removed: Int, inserted: Int),
                lines index: LineIndex, textLength: Int) {
        guard !lines.isEmpty, let last = lines.last, last >= change.firstLine else { return }
        let oldEnd = editedRange.location + editedRange.length - delta
        let next = change.firstLine + change.inserted + 1
        let lastLineEnd = (next < index.count ? index.start(of: next) - 1 : textLength) - delta
        lines = Bookmarks.adjusted(lines, firstLine: change.firstLine, removed: change.removed, inserted: change.inserted,
                                   editStartsLine: editedRange.location == index.start(of: change.firstLine),
                                   lastLineKeepsText: oldEnd < lastLineEnd)
    }

    /// Bookmarks after an edit that replaced text from `firstLine` on, where `removed` line breaks
    /// were deleted and `inserted` added. `editStartsLine`: the edit began at the start of
    /// `firstLine`. `lastLineKeepsText`: part of the last line the edit reached was left over.
    static func adjusted(_ lines: [Int], firstLine f: Int, removed: Int, inserted: Int,
                         editStartsLine: Bool, lastLineKeepsText: Bool) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(lines.count)
        for l in lines {
            if l < f || (l == f && !editStartsLine) {
                out.append(l)
            } else if l > f + removed {
                out.append(l + inserted - removed)
            } else if removed == inserted {
                // Lines replaced one for one, as sorting, trimming or changing case does.
                out.append(l)
            } else if l == f && removed == 0 {
                // Text inserted before the line's own text pushes it down.
                out.append(f + inserted)
            } else if l == f + removed && l != f && lastLineKeepsText {
                out.append(f + inserted)
            }
        }
        var unique: [Int] = []
        unique.reserveCapacity(out.count)
        for l in out where unique.last != l { unique.append(l) }
        return unique
    }
}
