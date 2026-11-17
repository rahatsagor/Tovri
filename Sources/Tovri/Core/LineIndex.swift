import Foundation

/// UTF-16 offsets of the start of every line. Stored as a gap buffer with a post-gap delta so
/// localized typing, line lookups and edits stay fast even in multi-million-line files.
final class LineIndex {
    private var buf: [Int] = [0]
    private var gapStart = 1
    private var gapEnd = 1
    private var gapDelta = 0

    var count: Int { buf.count - (gapEnd - gapStart) }

    var starts: [Int] {
        let shift = gapEnd - gapStart
        var out: [Int] = []
        out.reserveCapacity(buf.count - shift)
        out.append(contentsOf: buf[..<gapStart])
        if gapEnd < buf.count {
            for i in gapEnd..<buf.count { out.append(buf[i] + gapDelta) }
        }
        return out
    }

    func rebuild(from text: NSString) {
        var result: [Int] = [0]
        result.reserveCapacity(max(16, text.length / 40))
        scanNewlines(text, in: NSRange(location: 0, length: text.length)) { result.append($0 + 1) }
        buf = result
        gapStart = result.count
        gapEnd = result.count
        gapDelta = 0
    }

    /// Index of the line containing `location` (the last line if past the end).
    func line(containing location: Int) -> Int {
        let total = count
        let shift = gapEnd - gapStart
        let gs = gapStart
        let gd = gapDelta
        return buf.withUnsafeBufferPointer { b in
            var lo = 0
            var hi = total - 1
            while lo < hi {
                let mid = (lo + hi + 1) >> 1
                let val = mid < gs ? b[mid] : b[mid + shift] + gd
                if val <= location { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }
    }

    @inline(__always) func start(of line: Int) -> Int {
        let total = count
        let i = min(max(line, 0), total - 1)
        return i < gapStart ? buf[i] : buf[i + (gapEnd - gapStart)] + gapDelta
    }

    /// Range of the line content, excluding the trailing newline.
    func range(of line: Int, textLength: Int) -> NSRange {
        let s = start(of: line)
        let e = line + 1 < count ? start(of: line + 1) - 1 : textLength
        return NSRange(location: s, length: max(0, e - s))
    }

    /// Range of the line including its trailing newline (if any).
    func fullRange(of line: Int, textLength: Int) -> NSRange {
        let s = start(of: line)
        let e = line + 1 < count ? start(of: line + 1) : textLength
        return NSRange(location: s, length: max(0, e - s))
    }

    private func moveGap(to pos: Int) {
        if pos < gapStart {
            let k = gapStart - pos
            for i in stride(from: k - 1, through: 0, by: -1) {
                buf[gapEnd - k + i] = buf[pos + i] - gapDelta
            }
            gapStart = pos
            gapEnd -= k
        } else if pos > gapStart {
            let k = pos - gapStart
            for i in 0..<k {
                buf[gapStart + i] = buf[gapEnd + i] + gapDelta
            }
            gapStart = pos
            gapEnd += k
        }
    }

    /// Applies an edit. `editedRange` is the range of the new text, `delta` the change in length.
    /// Returns the first affected line, the number of line starts removed and inserted after it.
    @discardableResult
    func update(editedRange: NSRange, delta: Int, text: NSString) -> (firstLine: Int, removed: Int, inserted: Int) {
        let loc = editedRange.location
        let oldEnd = loc + editedRange.length - delta
        let first = line(containing: loc)
        let total = count

        var removeEnd = first + 1
        while removeEnd < total && start(of: removeEnd) <= oldEnd { removeEnd += 1 }
        let removed = removeEnd - (first + 1)

        moveGap(to: first + 1)
        gapEnd += removed
        gapDelta += delta

        var newStarts: [Int] = []
        scanNewlines(text, in: editedRange) { newStarts.append($0 + 1) }

        if !newStarts.isEmpty {
            let needed = newStarts.count
            let avail = gapEnd - gapStart
            if avail < needed {
                let add = max(64, max(needed * 2, min(65_536, buf.count / 8)))
                let tailCount = buf.count - gapEnd
                buf.append(contentsOf: repeatElement(0, count: add))
                if tailCount > 0 {
                    let newGapEnd = gapEnd + add
                    for i in stride(from: tailCount - 1, through: 0, by: -1) {
                        buf[newGapEnd + i] = buf[gapEnd + i]
                    }
                    gapEnd = newGapEnd
                } else {
                    gapEnd += add
                }
            }
            for s in newStarts {
                buf[gapStart] = s
                gapStart += 1
            }
        }
        return (first, removed, newStarts.count)
    }

    private func scanNewlines(_ text: NSString, in range: NSRange, _ found: (Int) -> Void) {
        let chunk = 64 * 1024
        guard range.length > 0 else { return }
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: min(chunk, range.length))
        defer { buffer.deallocate() }
        var pos = range.location
        let end = NSMaxRange(range)
        while pos < end {
            let len = min(chunk, end - pos)
            text.getCharacters(buffer, range: NSRange(location: pos, length: len))
            var k = 0
            while k < len {
                if buffer[k] == 10 { found(pos + k) }
                k += 1
            }
            pos += len
        }
    }
}
