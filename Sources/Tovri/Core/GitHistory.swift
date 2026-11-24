import Foundation

/// Stops a running git command. Create one per request; `cancel()` may be called from any thread.
final class GitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        running?.terminate()
    }

    /// Registers the process that was just launched; false if the request was cancelled before that.
    func attach(_ p: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        process = p
        return true
    }

    func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

/// What one commit is called in the History list: a branch, remote branch, tag or the detached HEAD.
struct RefLabel: Equatable {
    enum Kind { case branch, remoteBranch, tag, detachedHead }
    var name: String
    var kind: Kind
    var isCheckedOut: Bool
}

struct LogCommit: Equatable {
    var sha: String
    var shortSHA: String
    var parents: [String]
    var author: String
    var date: Date
    var subject: String
    var refs: [RefLabel]
}

/// What the History search box holds: words that match commit messages, plus `author:` and
/// `path:` narrowing. A value with spaces is quoted: `path:"My Folder"`.
struct HistoryQuery: Equatable {
    var words = ""
    var authors: [String] = []
    var paths: [String] = []

    init() {}

    init(_ text: String) {
        var plain: [Substring] = []
        var rest = text[...]
        func skipSpace() { rest = rest.drop(while: \.isWhitespace) }
        skipSpace()
        while !rest.isEmpty {
            var handled = false
            for prefix in ["author:", "path:"] where rest.hasPrefix(prefix) {
                let after = rest.dropFirst(prefix.count)
                var value: Substring
                var remainder: Substring
                if after.first == "\"" {
                    let body = after.dropFirst()
                    if let close = body.firstIndex(of: "\"") {
                        value = body[..<close]
                        remainder = body[body.index(after: close)...]
                    } else {
                        value = body
                        remainder = ""
                    }
                } else {
                    value = after.prefix { !$0.isWhitespace }
                    remainder = after.dropFirst(value.count)
                }
                guard !value.isEmpty else { break }
                if prefix == "author:" { authors.append(String(value)) } else { paths.append(String(value)) }
                rest = remainder
                handled = true
                break
            }
            if !handled {
                let word = rest.prefix { !$0.isWhitespace }
                plain.append(word)
                rest = rest.dropFirst(word.count)
            }
            skipSpace()
        }
        words = plain.joined(separator: " ")
    }

    var isEmpty: Bool { words.isEmpty && authors.isEmpty && paths.isEmpty }

    /// The log options for this query, then the paths after `--`.
    var logArguments: [String] {
        var args = ["--regexp-ignore-case", "--fixed-strings"]
        if !words.isEmpty { args.append("--grep=" + words) }
        for a in authors { args.append("--author=" + a) }
        return args
    }
}

extension GitRepository {
    // MARK: Log

    /// One page of commits reachable from `tip`, newest first, matching `query`. `completion` runs
    /// on the main queue with nil if git failed or the request was cancelled.
    func log(from tip: String, query: HistoryQuery, skip: Int, limit: Int, topoOrder: Bool,
             cancellation: GitCancellation?, _ completion: @escaping ([LogCommit]?) -> Void) {
        var args = ["log", "-z", "--no-show-signature", "--no-color", "--decorate=full",
                    "--format=%H%x1f%h%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s", "-n", String(limit), "--skip=\(skip)"]
        if topoOrder { args.append("--topo-order") }
        args += query.logArguments
        args.append(tip)
        args.append("--")
        args += query.paths
        GitRepository.runAsync {
            let data = self.run(args, cancellation: cancellation)
            let commits = data.map(GitRepository.parseLog)
            DispatchQueue.main.async { completion(cancellation?.isCancelled == true ? nil : commits) }
        }
    }

    /// Parses `log -z --format=%H%x1f%h%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s --decorate=full`. The subject is
    /// last, so it keeps any 0x1f it contains.
    static func parseLog(_ data: Data) -> [LogCommit] {
        var out: [LogCommit] = []
        for record in data.split(separator: 0) {
            let f = record.split(separator: 0x1f, maxSplits: 6, omittingEmptySubsequences: false)
            guard f.count == 7, let t = TimeInterval(String(decoding: f[4], as: UTF8.self)) else { continue }
            let sha = String(decoding: f[0], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty else { continue }
            out.append(LogCommit(sha: sha,
                                 shortSHA: String(decoding: f[1], as: UTF8.self),
                                 parents: String(decoding: f[2], as: UTF8.self).split(separator: " ").map(String.init),
                                 author: String(decoding: f[3], as: UTF8.self),
                                 date: Date(timeIntervalSince1970: t),
                                 subject: String(decoding: f[6], as: UTF8.self),
                                 refs: parseRefs(String(decoding: f[5], as: UTF8.self))))
        }
        return out
    }

    /// Reads `%D` with `--decorate=full`: `HEAD -> refs/heads/main, tag: refs/tags/v1, refs/remotes/origin/main`.
    static func parseRefs(_ decoration: String) -> [RefLabel] {
        var labels: [RefLabel] = []
        for part in decoration.components(separatedBy: ", ") {
            var item = part[...]
            var checkedOut = false
            if item == "HEAD" {
                labels.append(RefLabel(name: "HEAD", kind: .detachedHead, isCheckedOut: true))
                continue
            }
            if item.hasPrefix("HEAD -> ") {
                checkedOut = true
                item = item.dropFirst("HEAD -> ".count)
            }
            if item.hasPrefix("tag: ") {
                let name = item.dropFirst("tag: ".count)
                if name.hasPrefix("refs/tags/") {
                    labels.append(RefLabel(name: String(name.dropFirst("refs/tags/".count)), kind: .tag, isCheckedOut: false))
                }
            } else if item.hasPrefix("refs/heads/") {
                labels.append(RefLabel(name: String(item.dropFirst("refs/heads/".count)), kind: .branch, isCheckedOut: checkedOut))
            } else if item.hasPrefix("refs/remotes/") {
                let name = item.dropFirst("refs/remotes/".count)
                if name.split(separator: "/").last == "HEAD" { continue }
                labels.append(RefLabel(name: String(name), kind: .remoteBranch, isCheckedOut: false))
            }
        }
        return labels
    }

    // MARK: HEAD

    /// The commit HEAD points at, from `headToken`, when it is a full SHA-1 or SHA-256 name.
    var headCommitSHA: String? {
        guard let token = headToken, let last = token.split(separator: " ").last else { return nil }
        guard last.count == 40 || last.count == 64, last.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return String(last)
    }

    var isUnborn: Bool { headToken?.hasSuffix(" unborn") == true }

    /// A commit-graph file makes `--topo-order` cheap; without one it walks the whole history first.
    var hasCommitGraph: Bool {
        guard let info = resolvedDirs?.commonDir.appendingPathComponent("objects/info") else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: info.appendingPathComponent("commit-graph").path)
            || fm.fileExists(atPath: info.appendingPathComponent("commit-graphs/commit-graph-chain").path)
    }

    // MARK: Commit details

    /// Most files listed for one commit; the rest are counted.
    static let maxCommitFiles = 1_000

    struct CommitFile: Equatable {
        var path: String
        var originalPath: String?
        var status: GitFileStatus
        var added: Int?
        var removed: Int?

        var changedFile: ChangedFile {
            ChangedFile(path: path, status: status, added: added, removed: removed, staged: false, originalPath: originalPath)
        }
    }

    struct CommitDetail: Equatable {
        var sha: String
        var parents: [String]
        var authorName: String
        var authorEmail: String
        var authorDate: Date
        var committerName: String
        var commitDate: Date
        var message: String
        var files: [CommitFile]
        var hiddenFileCount: Int
    }

    /// The message, author and changed files of one commit, with line counts. A merge is compared
    /// with its first parent and a root commit with the empty tree.
    func commitDetail(sha: String, parents: [String], _ completion: @escaping (CommitDetail?) -> Void) {
        GitRepository.runAsync {
            let detail = self.loadCommitDetail(sha: sha, parents: parents)
            DispatchQueue.main.async { completion(detail) }
        }
    }

    private func loadCommitDetail(sha: String, parents: [String]) -> CommitDetail? {
        guard let header = run(["log", "-1", "--no-show-signature", "--no-color",
                                "--format=%an%x1f%ae%x1f%at%x1f%cn%x1f%ct%x1f%B", sha, "--"]) else { return nil }
        let f = header.split(separator: 0x1f, maxSplits: 5, omittingEmptySubsequences: false)
        guard f.count == 6, let authored = TimeInterval(String(decoding: f[2], as: UTF8.self)),
              let committed = TimeInterval(String(decoding: f[4], as: UTF8.self)) else { return nil }
        let tree = GitRepository.diffTreeArguments(sha: sha, parent: parents.first)
        guard let names = run(["diff-tree", "-r", "-z", "--no-commit-id", "--name-status", "-M",
                               "--no-ext-diff", "--no-textconv"] + tree),
              let counts = run(["diff-tree", "-r", "-z", "--no-commit-id", "--numstat", "-M",
                                "--no-ext-diff", "--no-textconv"] + tree) else { return nil }
        var files = GitRepository.parseNameStatus(names)
        let hidden = max(0, files.count - GitRepository.maxCommitFiles)
        if hidden > 0 { files.removeLast(hidden) }
        let numbers = GitRepository.parseNumstat(counts)
        for i in files.indices {
            if let n = numbers[files[i].path] { (files[i].added, files[i].removed) = (n.added, n.removed) }
        }
        let message = String(decoding: f[5], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return CommitDetail(sha: sha, parents: parents,
                            authorName: String(decoding: f[0], as: UTF8.self),
                            authorEmail: String(decoding: f[1], as: UTF8.self),
                            authorDate: Date(timeIntervalSince1970: authored),
                            committerName: String(decoding: f[3], as: UTF8.self),
                            commitDate: Date(timeIntervalSince1970: committed),
                            message: message, files: files, hiddenFileCount: hidden)
    }

    private static func diffTreeArguments(sha: String, parent: String?) -> [String] {
        parent.map { [$0, sha, "--"] } ?? ["--root", sha, "--"]
    }

    /// Parses `diff-tree --name-status -z`: a status, then one path, or two for a rename or copy.
    static func parseNameStatus(_ data: Data) -> [CommitFile] {
        var files: [CommitFile] = []
        let parts = data.split(separator: 0, omittingEmptySubsequences: true)
        var i = 0
        while i < parts.count {
            let code = String(decoding: parts[i], as: UTF8.self)
            i += 1
            let letter = code.first ?? "M"
            let twoPaths = letter == "R" || letter == "C"
            guard i < parts.count, !twoPaths || i + 1 < parts.count else { break }
            let first = String(decoding: parts[i], as: UTF8.self)
            let second = twoPaths ? String(decoding: parts[i + 1], as: UTF8.self) : nil
            i += twoPaths ? 2 : 1
            let status: GitFileStatus
            switch letter {
            case "A", "C": status = .added
            case "D": status = .deleted
            case "R": status = .renamed
            default: status = .modified
            }
            files.append(CommitFile(path: second ?? first, originalPath: letter == "R" ? first : nil, status: status))
        }
        return files
    }

    // MARK: Patches

    /// The commit's changes as a unified diff, limited to `paths` when given. For a renamed file pass
    /// both its old and new path, or the rename reads as an added file. Nil if git failed or the
    /// diff is larger than `maxBlobSize`.
    func commitPatch(sha: String, parent: String?, paths: [String]?, _ completion: @escaping (String?) -> Void) {
        var args = ["diff-tree", "-p", "-r", "-M", "--no-commit-id", "--no-ext-diff", "--no-textconv", "--no-color"]
        args += parent.map { [$0, sha] } ?? ["--root", sha]
        args.append("--")
        args += paths ?? []
        GitRepository.runAsync {
            let data = self.run(args, maxOutputBytes: GitRepository.maxBlobSize)
            let text = data.map { String(decoding: $0, as: UTF8.self) }
            DispatchQueue.main.async { completion(text) }
        }
    }
}

/// Lane layout for the History graph, assigned the way `git log --graph` does: a commit takes the
/// lane waiting for it, its first parent inherits the lane, and other parents open or join lanes to
/// the right. Rows are laid out a page at a time; `State` carries the open lanes between pages.
enum CommitGraph {
    enum Half: Equatable { case top, bottom }

    struct Edge: Equatable {
        var from: Int
        var to: Int
        var half: Half
    }

    struct Row: Equatable {
        var lane: Int
        var laneCount: Int
        /// Line segments in the row's top half (into the commit) and bottom half (toward its parents).
        var edges: [Edge]
        var isMerge: Bool
        /// Lanes that carry on below this row, which a row expanded under it draws as straight lines.
        var continuing: [Int]
    }

    struct State: Equatable {
        var lanes: [String?] = []
    }

    static func layout(_ commits: [LogCommit], state: inout State) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(commits.count)
        var lanes = state.lanes
        state.lanes = []
        for commit in commits {
            var edges: [Edge] = []
            let node: Int
            if let waiting = lanes.firstIndex(where: { $0 == commit.sha }) {
                node = waiting
            } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                node = free
            } else {
                node = lanes.count
                lanes.append(nil)
            }
            for (index, sha) in lanes.enumerated() {
                guard let sha else { continue }
                edges.append(Edge(from: index, to: sha == commit.sha ? node : index, half: .top))
            }
            for index in lanes.indices where lanes[index] == commit.sha { lanes[index] = nil }

            var parentLanes: [Int] = []
            for (offset, parent) in commit.parents.enumerated() {
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    parentLanes.append(existing)
                } else if offset == 0, lanes[node] == nil {
                    lanes[node] = parent
                    parentLanes.append(node)
                } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                    lanes[free] = parent
                    parentLanes.append(free)
                } else {
                    lanes.append(parent)
                    parentLanes.append(lanes.count - 1)
                }
            }
            for target in parentLanes { edges.append(Edge(from: node, to: target, half: .bottom)) }
            var continuing: [Int] = []
            for (index, sha) in lanes.enumerated() where sha != nil {
                continuing.append(index)
                if !parentLanes.contains(index) { edges.append(Edge(from: index, to: index, half: .bottom)) }
            }
            let laneCount = max(lanes.count, node + 1)
            while let last = lanes.last, last == nil { lanes.removeLast() }
            rows.append(Row(lane: node, laneCount: laneCount, edges: edges, isMerge: commit.parents.count > 1, continuing: continuing))
        }
        state.lanes = lanes
        return rows
    }
}
