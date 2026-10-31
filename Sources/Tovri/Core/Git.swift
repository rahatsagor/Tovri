import Foundation

enum GitFileStatus {
    case modified, added, untracked, deleted, renamed, conflicted, ignored

    var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .untracked: return "U"
        case .deleted: return "D"
        case .renamed: return "R"
        case .conflicted: return "!"
        case .ignored: return "I"
        }
    }

    var label: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .untracked: return "New"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .conflicted: return "Conflict"
        case .ignored: return "Ignored"
        }
    }
}

enum DiffMark: UInt8 { case added, modified }

/// One contiguous change against HEAD, in current-text line numbers.
struct DiffHunk: Equatable {
    /// First changed line; for a pure deletion, the line that followed the removed text.
    var newStart: Int
    var newCount: Int
    var oldStart: Int
    var oldLines: [String]

    var newEnd: Int { newStart + newCount }
    var isDeletion: Bool { newCount == 0 }
    var isAddition: Bool { oldLines.isEmpty }
}

struct LineDiff {
    var marks: [Int: DiffMark] = [:]
    /// Lines after which one or more lines were deleted (index of the following line).
    var deletions = Set<Int>()
    var hunks: [DiffHunk] = []
    var isEmpty: Bool { marks.isEmpty && deletions.isEmpty }

    /// The hunk drawn on `line`. A deletion past the last line is reported on the last line.
    func hunk(at line: Int, lineCount: Int) -> DiffHunk? {
        hunks.first { h in
            h.isDeletion ? (h.newStart == line || (h.newStart >= lineCount && line == lineCount - 1))
                         : line >= h.newStart && line < h.newEnd
        }
    }

    /// The following or preceding hunk, wrapping around the file.
    func nextHunk(from line: Int, forward: Bool, lineCount: Int) -> DiffHunk? {
        guard !hunks.isEmpty else { return nil }
        // A deletion after the last line is shown, and navigated to, on the last line.
        if forward { return hunks.first { min($0.newStart, lineCount - 1) > line } ?? hunks.first }
        let ref = hunk(at: line, lineCount: lineCount)?.newStart ?? line
        return hunks.last { $0.newStart < ref } ?? hunks.last
    }
}

/// Thin, read-only Git integration: branch, file status and HEAD contents. Commands run on a
/// background queue; nothing runs unless a real git binary is installed.
final class GitRepository {
    let root: URL
    private static var cache: [String: GitRepository] = [:]
    private static let cacheLock = NSLock()
    private static let queue = DispatchQueue(label: "app.tovri.git", qos: .utility, attributes: .concurrent)

    static let executable: String? = {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git"]
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                candidates.append(s + "/usr/bin/git")
            }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }()

    private init(root: URL) { self.root = root }

    /// Finds the repository containing `url` by walking up to the nearest `.git`. The `.git` is
    /// checked every time, so a repository that was deleted or moved stops being found.
    static func find(for url: URL) -> GitRepository? {
        var dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<64 {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                let key = dir.standardizedFileURL.path
                cacheLock.lock()
                defer { cacheLock.unlock() }
                if let r = cache[key] { return r }
                let r = GitRepository(root: dir.standardizedFileURL)
                cache[key] = r
                return r
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private var gitDir: URL {
        let dotGit = root.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir), !isDir.boolValue,
           let s = try? String(contentsOf: dotGit, encoding: .utf8), s.hasPrefix("gitdir:") {
            let path = s.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
        }
        return dotGit
    }

    var branch: String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("ref: refs/heads/") { return String(t.dropFirst("ref: refs/heads/".count)) }
        return t.isEmpty ? nil : String(t.prefix(7))
    }

    func relativePath(_ url: URL) -> String? {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let r = root.resolvingSymlinksInPath().path
        guard p.hasPrefix(r + "/") else { return nil }
        return String(p.dropFirst(r.count + 1))
    }

    /// Settings that let a repository run programs. A cloned or downloaded `.git` folder is
    /// untrusted, and Tovri runs git on its own whenever files change, so these are always off.
    private static let safetyOptions = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]

    private func run(_ args: [String]) -> Data? {
        // `git config` only reads settings, so it can safely list the filters to neutralize.
        let filters = rawRun(["config", "-z", "--get-regexp", "^filter\\."]).map(GitRepository.filterOverrides) ?? []
        return rawRun(filters + args)
    }

    /// Empty commands for every configured clean/smudge/process filter, so `status` can't run them.
    static func filterOverrides(_ configOutput: Data) -> [String] {
        var names = Set<String>()
        for entry in configOutput.split(separator: 0) {
            let key = String(decoding: entry.prefix { $0 != 10 }, as: UTF8.self)
            guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."), dot > key.index(key.startIndex, offsetBy: 6) else { continue }
            names.insert(String(key[key.index(key.startIndex, offsetBy: 7)..<dot]))
        }
        return names.sorted().flatMap { name in
            ["clean=", "smudge=", "process=", "required=false"].flatMap { ["-c", "filter.\(name).\($0)"] }
        }
    }

    private func rawRun(_ args: [String]) -> Data? {
        guard let git = GitRepository.executable else { return nil }
        return GitRepository.runProcess(URL(fileURLWithPath: git), ["-C", root.path] + GitRepository.safetyOptions + args,
                                        environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1", "LC_ALL": "C", "PATH": "/usr/bin:/bin"])
    }

    /// Longest a git command may run before it is stopped.
    static let timeout: TimeInterval = 30

    /// Standard output of a successful run, or nil if it failed or ran past `timeout`. The
    /// output is read on another thread, so a stalled network volume, or a child process
    /// that keeps the pipe open, can't hold the caller past the timeout.
    static func runProcess(_ executable: URL, _ args: [String], environment: [String: String], timeout: TimeInterval = GitRepository.timeout) -> Data? {
        final class Output: @unchecked Sendable { var data = Data() }
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let output = Output()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
            return nil
        }
        return p.terminationReason == .exit && p.terminationStatus == 0 ? output.data : nil
    }

    func status(_ completion: @escaping ([String: GitFileStatus]) -> Void) {
        GitRepository.queue.async {
            let data = self.run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all"])
            let result = data.map(GitRepository.parseStatus) ?? [:]
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Parses `git status --porcelain=v1 -z`. Renames and copies, in the index or (for
    /// intent-to-add files) the work tree, are followed by an extra field holding the old path.
    static func parseStatus(_ data: Data) -> [String: GitFileStatus] {
        var result: [String: GitFileStatus] = [:]
        let parts = data.split(separator: 0, omittingEmptySubsequences: true)
        var i = 0
        while i < parts.count {
            let entry = parts[i]
            i += 1
            guard entry.count > 3 else { continue }
            let x = Character(Unicode.Scalar(entry[entry.startIndex]))
            let y = Character(Unicode.Scalar(entry[entry.startIndex + 1]))
            let path = String(decoding: entry.dropFirst(3), as: UTF8.self)
            if "RC".contains(x) || "RC".contains(y) { i += 1 }
            let s: GitFileStatus
            switch (x, y) {
            case ("?", "?"): s = .untracked
            case ("!", "!"): s = .ignored
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): s = .conflicted
            case ("R", _), (_, "R"): s = .renamed
            case ("A", _), ("C", _), (_, "C"): s = .added
            case ("D", _), (_, "D"): s = .deleted
            default: s = .modified
            }
            result[path] = s
        }
        return result
    }

    /// Tracked and untracked files under `dir` that `.gitignore` doesn't exclude, relative to
    /// `dir`, or nil if git can't list them. Runs on the calling thread.
    func unignoredFiles(in dir: URL) -> [String]? {
        guard let data = run(["-C", dir.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]) else { return nil }
        var seen = Set<String>()
        var out: [String] = []
        for part in data.split(separator: 0) {
            let path = String(decoding: part, as: UTF8.self)
            // Untracked nested repositories are listed as folders; merge conflicts list a file once per stage.
            if path.hasSuffix("/") || !seen.insert(path).inserted { continue }
            out.append(path)
        }
        return out
    }

    /// Ignored files and directories (directories collapsed, with a trailing slash removed).
    func ignored(_ completion: @escaping ([String]) -> Void) {
        GitRepository.queue.async {
            var out: [String] = []
            if let data = self.run(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]) {
                for part in data.split(separator: 0) {
                    var s = String(decoding: part, as: UTF8.self)
                    if s.hasSuffix("/") { s.removeLast() }
                    out.append(s)
                }
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// Raw bytes of the file at HEAD, or nil if it isn't tracked. The caller decodes them with the
    /// document's encoding, since UTF-16 or Windows-1252 bytes read as UTF-8 would be garbage.
    func headContents(of url: URL, _ completion: @escaping (Data?) -> Void) {
        guard let rel = relativePath(url) else { completion(nil); return }
        GitRepository.queue.async {
            let data = self.run(["show", "HEAD:" + rel])
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// A unified diff with `context` lines around each change, or "" when the texts match.
    static func unifiedDiff(old: String, new: String, path: String, context: Int = 3) -> String {
        // A last line without a newline is marked so it differs from the same text with one,
        // and is printed with git's "No newline at end of file" note.
        let noNewline: Character = "\u{1}"
        func lines(_ s: String) -> [Substring] {
            var l = s.split(separator: "\n", omittingEmptySubsequences: false)
            if l.last == "" { l.removeLast() } else if let last = l.last { l[l.count - 1] = Substring(last + String(noNewline)) }
            return l
        }
        let o = lines(old)
        let n = lines(new)
        let hunks = diff(old: o, new: n).hunks
        guard !hunks.isEmpty else { return "" }
        func span(_ start: Int, _ count: Int) -> String {
            count == 0 ? "\(start),0" : count == 1 ? "\(start + 1)" : "\(start + 1),\(count)"
        }
        var out = "--- a/\(path)\n+++ b/\(path)\n"
        var i = 0
        while i < hunks.count {
            var j = i
            while j + 1 < hunks.count && hunks[j + 1].newStart - hunks[j].newEnd <= context * 2 { j += 1 }
            let newFrom = max(0, hunks[i].newStart - context)
            let newTo = min(n.count, hunks[j].newEnd + context)
            let oldFrom = newFrom + hunks[i].oldStart - hunks[i].newStart
            var body = ""
            var oldCount = 0
            var line = newFrom
            for h in hunks[i...j] {
                while line < h.newStart { body += " \(n[line])\n"; line += 1; oldCount += 1 }
                for l in h.oldLines { body += "-\(l)\n"; oldCount += 1 }
                while line < h.newEnd { body += "+\(n[line])\n"; line += 1 }
            }
            while line < newTo { body += " \(n[line])\n"; line += 1; oldCount += 1 }
            body = body.replacingOccurrences(of: "\(noNewline)\n", with: "\n\\ No newline at end of file\n")
            out += "@@ -\(span(oldFrom, oldCount)) +\(span(newFrom, newTo - newFrom)) @@\n" + body
            i = j + 1
        }
        return out
    }

    /// Line-level diff of `new` against `old`, reduced to gutter markers.
    static func diff(old: [Substring], new: [Substring]) -> LineDiff {
        var prefix = 0
        while prefix < old.count && prefix < new.count && old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix && suffix < new.count - prefix && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let o = old[prefix..<(old.count - suffix)]
        let n = new[prefix..<(new.count - suffix)]
        var result = LineDiff()
        if o.isEmpty && n.isEmpty { return result }
        let oldLines = Array(o)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        if o.count * n.count > 40_000_000 {
            for k in 0..<n.count { inserted.insert(k) }
            for k in 0..<o.count { removed.insert(k) }
        } else {
            for change in Array(n).difference(from: oldLines) {
                switch change {
                case .insert(let off, _, _): inserted.insert(off)
                case .remove(let off, _, _): removed.insert(off)
                }
            }
        }
        var i = 0, j = 0
        while i < o.count || j < n.count {
            if removed.contains(i) || inserted.contains(j) {
                var r = 0
                while removed.contains(i + r) { r += 1 }
                var a = 0
                while inserted.contains(j + a) { a += 1 }
                for k in 0..<a { result.marks[prefix + j + k] = k < r ? .modified : .added }
                if a == 0 && r > 0 { result.deletions.insert(prefix + j) }
                result.hunks.append(DiffHunk(newStart: prefix + j, newCount: a, oldStart: prefix + i,
                                             oldLines: oldLines[i..<(i + r)].map(String.init)))
                i += r
                j += a
            } else {
                i += 1
                j += 1
            }
        }
        return result
    }
}
