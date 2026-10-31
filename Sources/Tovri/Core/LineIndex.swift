import Foundation

/// UTF-16 offsets of the start of every line. Updated incrementally on each edit so
/// line lookups (gutter, goto line, syntax states) stay O(log n).
final class LineIndex {
    private(set) var starts: [Int] = [0]

    var count: Int { starts.count }

    func rebuild(from text: NSString) {
        var result: [Int] = [0]
        result.reserveCapacity(max(16, text.length / 40))
        scanNewlines(text, in: NSRange(location: 0, length: text.length)) { result.append($0 + 1) }
        starts = result
    }

    /// Index of the line containing `location` (the last line if past the end).
    func line(containing location: Int) -> Int {
        var lo = 0
        var hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if starts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    @inline(__always) func start(of line: Int) -> Int { starts[min(max(line, 0), starts.count - 1)] }

    /// Range of the line content, excluding the trailing newline.
    func range(of line: Int, textLength: Int) -> NSRange {
        let s = start(of: line)
        let e = line + 1 < starts.count ? starts[line + 1] - 1 : textLength
        return NSRange(location: s, length: max(0, e - s))
    }

    /// Range of the line including its trailing newline (if any).
    func fullRange(of line: Int, textLength: Int) -> NSRange {
        let s = start(of: line)
        let e = line + 1 < starts.count ? starts[line + 1] : textLength
        return NSRange(location: s, length: max(0, e - s))
    }

    /// Applies an edit. `editedRange` is the range of the new text, `delta` the change in length.
    /// Returns the first affected line, the number of line starts removed and inserted after it.
    @discardableResult
    func update(editedRange: NSRange, delta: Int, text: NSString) -> (firstLine: Int, removed: Int, inserted: Int) {
        let loc = editedRange.location
        let oldEnd = loc + editedRange.length - delta
        let first = line(containing: loc)

        var removeEnd = first + 1
        while removeEnd < starts.count && starts[removeEnd] <= oldEnd { removeEnd += 1 }
        let removed = removeEnd - (first + 1)

        var newStarts: [Int] = []
        scanNewlines(text, in: editedRange) { newStarts.append($0 + 1) }

        if delta != 0 && removeEnd < starts.count {
            starts.withUnsafeMutableBufferPointer { buf in
                for k in removeEnd..<buf.count { buf[k] += delta }
            }
        }
        starts.replaceSubrange((first + 1)..<removeEnd, with: newStarts)
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
