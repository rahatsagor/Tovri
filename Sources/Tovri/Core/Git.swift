import Foundation

enum GitFileStatus: Equatable {
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

    var sortRank: Int {
        switch self {
        case .conflicted: return 0
        case .modified: return 1
        case .renamed: return 2
        case .added: return 3
        case .deleted: return 4
        case .untracked: return 5
        case .ignored: return 6
        }
    }
}

/// Which uncommitted changes the sidebar's Changes list loads and displays.
enum ChangeFilter: String, CaseIterable {
    case all, tracked, untracked, staged, unstaged, modified, deleted

    var title: String {
        switch self {
        case .all: return "All Changes"
        case .tracked: return "Tracked"
        case .untracked: return "Untracked"
        case .staged: return "Staged"
        case .unstaged: return "Unstaged"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: return "No uncommitted changes"
        case .tracked: return "No tracked changes"
        case .untracked: return "No untracked files"
        case .staged: return "No staged changes"
        case .unstaged: return "No unstaged changes"
        case .modified: return "No modified files"
        case .deleted: return "No deleted files"
        }
    }

    /// When false, `git status` passes `--untracked-files=no` and skips scanning untracked folders.
    var includesUntracked: Bool {
        switch self {
        case .all, .untracked, .unstaged: return true
        case .tracked, .staged, .modified, .deleted: return false
        }
    }

    var includesStaged: Bool {
        switch self {
        case .all, .tracked, .staged, .modified, .deleted: return true
        case .untracked, .unstaged: return false
        }
    }

    var includesTrackedUnstaged: Bool {
        switch self {
        case .all, .tracked, .unstaged, .modified, .deleted: return true
        case .untracked, .staged: return false
        }
    }

    func matches(_ file: GitRepository.ChangedFile) -> Bool {
        switch self {
        case .all: return true
        case .tracked: return file.status != .untracked
        case .untracked: return file.status == .untracked
        case .staged: return file.staged
        case .unstaged: return !file.staged
        case .modified: return file.status == .modified || file.status == .renamed
        case .deleted: return file.status == .deleted
        }
    }

    /// Whether a change list fetched with `self` already holds every file and line count `other` needs.
    func covers(_ other: ChangeFilter) -> Bool {
        switch self {
        case .all: return true
        case .tracked: return !other.includesUntracked
        case .unstaged: return other == .unstaged || other == .untracked
        default: return self == other
        }
    }
}

/// How files are ordered within each section of the sidebar's Changes list.
enum ChangeSort: String, CaseIterable {
    case path, name, status, changes

    var title: String {
        switch self {
        case .path: return "Path"
        case .name: return "Name"
        case .status: return "Status"
        case .changes: return "Lines Changed"
        }
    }

    func sorted(_ files: [GitRepository.ChangedFile]) -> [GitRepository.ChangedFile] {
        guard files.count > 1 else { return files }
        switch self {
        case .path:
            return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        case .name:
            let keyed = files.map { f -> (name: Substring, file: GitRepository.ChangedFile) in
                let name = f.path.lastIndex(of: "/").map { f.path[f.path.index(after: $0)...] } ?? f.path[...]
                return (name, f)
            }
            return keyed.sorted { a, b in
                let cmp = a.name.localizedStandardCompare(b.name)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return a.file.path.localizedStandardCompare(b.file.path) == .orderedAscending
            }.map(\.file)
        case .status:
            return files.sorted { a, b in
                if a.status.sortRank != b.status.sortRank { return a.status.sortRank < b.status.sortRank }
                return a.path.localizedStandardCompare(b.path) == .orderedAscending
            }
        case .changes:
            return files.sorted { a, b in
                let ca = a.added.map { $0 + (a.removed ?? 0) } ?? -1
                let cb = b.added.map { $0 + (b.removed ?? 0) } ?? -1
                if ca != cb { return ca > cb }
                return a.path.localizedStandardCompare(b.path) == .orderedAscending
            }
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

/// Thin Git integration: branch, file status and HEAD contents, and staging or discarding from the
/// Changes list. Commands run on a background queue; nothing runs unless a real git binary is installed.
final class GitRepository {
    let root: URL
    private static var cache: [String: GitRepository] = [:]
    private static let cacheLock = NSLock()
    /// Caps concurrent background git processes (e.g. when restoring dozens of tabs at launch).
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "app.tovri.git"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 4
        return q
    }()
    private static func runAsync(_ work: @escaping () -> Void) { queue.addOperation(work) }

    /// Maximum bytes read from a committed blob (`headContents` / `contents(of:at:)`).
    static let maxBlobSize = 20_000_000

    private struct FilterCacheStamp: Equatable {
        let env: [String: String]
        let files: [DiskStamp?]
    }
    private let filterLock = NSLock()
    private var cachedFilters: (stamp: FilterCacheStamp, expiresAt: TimeInterval, names: Set<String>)?

    private struct CachedLineCount {
        let stamp: DiskStamp
        let count: Int?
    }
    private let lineCountLock = NSLock()
    private var lineCountCache: [String: CachedLineCount] = [:]
    /// Caps untracked file bytes read per status pass so huge unignored trees never stall Git.
    private static let untrackedReadBudget = 64_000_000

    static let executable: String? = {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git"]
        if let data = runProcess(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], environment: ProcessInfo.processInfo.environment, timeout: 5),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            candidates.append(s + "/usr/bin/git")
        }
        return candidates.first { path in
            fm.isExecutableFile(atPath: path)
                && runProcess(URL(fileURLWithPath: path), ["--version"], environment: ["LC_ALL": "C", "PATH": "/usr/bin:/bin"], timeout: 5)
                    .map { isSupported(version: String(decoding: $0, as: UTF8.self)) } == true
        }
    }()

    /// Tovri's safety settings reach git in GIT_CONFIG_COUNT variables, which git ignores before
    /// 2.31. An older git would run with the repository's own settings, so it isn't used at all.
    static func isSupported(version output: String) -> Bool {
        // "git version 2.39.5 (Apple Git-154)"
        let words = output.split(separator: " ")
        guard words.count >= 3, words[0] == "git", words[1] == "version" else { return false }
        let parts = words[2].split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else { return false }
        return major > 2 || (major == 2 && minor >= 31)
    }

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

    /// Identifies the commit HEAD points at by reading .git directly, without running git. Nil when
    /// it can't be worked out cheaply; callers then treat HEAD as changed.
    var headToken: String? {
        let dir = gitDir
        guard let head = try? String(contentsOf: dir.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        guard head.hasPrefix("ref: ") else { return head }
        let ref = String(head.dropFirst(5))
        // Linked worktrees keep their HEAD here but share refs with the main repository.
        var refDirs = [dir]
        if let common = try? String(contentsOf: dir.appendingPathComponent("commondir"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
            refDirs.append(URL(fileURLWithPath: common, relativeTo: dir).standardizedFileURL)
        }
        for d in refDirs {
            if let sha = try? String(contentsOf: d.appendingPathComponent(ref), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty { return head + " " + sha }
        }
        for d in refDirs {
            guard let packed = try? String(contentsOf: d.appendingPathComponent("packed-refs"), encoding: .utf8) else { continue }
            for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
                return head + " " + line.prefix { $0 != " " }
            }
        }
        // An unborn branch has no commit yet.
        return refDirs.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(ref).path) } ? nil : head + " unborn"
    }

    func relativePath(_ url: URL) -> String? {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let r = root.resolvingSymlinksInPath().path
        guard p.hasPrefix(r + "/") else { return nil }
        return String(p.dropFirst(r.count + 1))
    }

    typealias ConfigSetting = (key: String, value: String)

    /// Settings that let a repository run programs. A cloned or downloaded `.git` folder is
    /// untrusted, and Tovri runs git on its own whenever files change, so these are always off.
    static let safetySettings: [ConfigSetting] = [
        ("core.fsmonitor", "false"),
        ("core.hooksPath", "/dev/null"),
        // Showing a signed commit runs the signature program, which the repository can name.
        ("log.showSignature", "false"),
        ("gpg.program", "false"),
        ("gpg.openpgp.program", "false"),
        ("gpg.ssh.program", "false"),
        ("gpg.x509.program", "false"),
        ("protocol.allow", "never"),
    ]

    /// The user's home and config folders, so git reads their global config and ignore file the
    /// way it does in Terminal. That config is the user's own; the safety settings and filter
    /// overrides take precedence over it as they do over the repository's.
    static var userEnvironment: [String: String] = {
        var env = ["HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()]
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty { env["XDG_CONFIG_HOME"] = xdg }
        return env
    }()

    /// The environment for every git command. Settings are passed in GIT_CONFIG_KEY_<n> and
    /// GIT_CONFIG_VALUE_<n> rather than `-c`, which splits at the first `=`: for a filter named
    /// `x=y`, `-c filter.x=y.clean=` sets `filter.x` instead and leaves the filter running.
    static func environment(_ settings: [ConfigSetting]) -> [String: String] {
        var env = userEnvironment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // No fetch may run, including the lazy fetch of a partial clone's missing objects.
        // GIT_NO_LAZY_FETCH needs git 2.44; an empty GIT_ALLOW_PROTOCOL refuses every transport
        // on any version and, unlike protocol.allow, can't be relaxed by protocol.<name>.allow.
        env["GIT_NO_LAZY_FETCH"] = "1"
        env["GIT_ALLOW_PROTOCOL"] = ""
        // Paths are file names, not patterns, so `[ab].txt` or `:x` mean only that file.
        env["GIT_LITERAL_PATHSPECS"] = "1"
        env["LC_ALL"] = "C"
        env["PATH"] = "/usr/bin:/bin"
        env["GIT_CONFIG_COUNT"] = String(settings.count)
        for (i, s) in settings.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = s.key
            env["GIT_CONFIG_VALUE_\(i)"] = s.value
        }
        return env
    }

    private func run(_ args: [String], acceptedStatuses: Set<Int32> = [0], maxOutputBytes: Int? = nil) -> Data? {
        guard let filters = configuredFilters() else { return nil }
        return rawRun(args, GitRepository.safetySettings + GitRepository.filterSettings(names: filters),
                      acceptedStatuses: acceptedStatuses, maxOutputBytes: maxOutputBytes)
    }

    private static let defaultSystemConfigPaths: [URL] = {
        guard let git = executable else { return [URL(fileURLWithPath: "/etc/gitconfig")] }
        var urls: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let std = url.standardizedFileURL
            if seen.insert(std.path).inserted { urls.append(std) }
        }
        if let data = runProcess(URL(fileURLWithPath: git), ["var", "GIT_CONFIG_SYSTEM"],
                                 environment: ["LC_ALL": "C", "PATH": "/usr/bin:/bin"], timeout: 5),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            add(URL(fileURLWithPath: s))
        }
        let execURL = URL(fileURLWithPath: git)
        for bin in [execURL, execURL.resolvingSymlinksInPath()] {
            let prefix = bin.deletingLastPathComponent().deletingLastPathComponent()
            add(prefix.appendingPathComponent("etc/gitconfig"))
        }
        add(URL(fileURLWithPath: "/etc/gitconfig"))
        add(URL(fileURLWithPath: "/opt/homebrew/etc/gitconfig"))
        add(URL(fileURLWithPath: "/usr/local/etc/gitconfig"))
        add(URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/etc/gitconfig"))
        return urls
    }()

    private func filterCacheStamp() -> FilterCacheStamp {
        let env = GitRepository.userEnvironment
        let dir = gitDir
        var paths = GitRepository.defaultSystemConfigPaths
        if let sys = env["GIT_CONFIG_SYSTEM"], !sys.isEmpty {
            paths.append(URL(fileURLWithPath: sys))
        }
        if let global = env["GIT_CONFIG_GLOBAL"], !global.isEmpty {
            paths.append(URL(fileURLWithPath: global))
        }
        if let explicit = env["GIT_CONFIG"], !explicit.isEmpty {
            paths.append(URL(fileURLWithPath: explicit))
        }
        paths.append(dir.appendingPathComponent("config"))
        paths.append(dir.appendingPathComponent("config.worktree"))
        if let common = try? String(contentsOf: dir.appendingPathComponent("commondir"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
            let commonDir = URL(fileURLWithPath: common, relativeTo: dir).standardizedFileURL
            paths.append(commonDir.appendingPathComponent("config"))
            paths.append(commonDir.appendingPathComponent("config.worktree"))
        }
        if let home = env["HOME"], !home.isEmpty {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            paths.append(homeURL.appendingPathComponent(".gitconfig"))
            let xdg = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? homeURL.appendingPathComponent(".config", isDirectory: true)
            paths.append(xdg.appendingPathComponent("git/config"))
        }
        return FilterCacheStamp(env: env, files: paths.map { DiskStamp($0) })
    }

    /// Names of the filter drivers in the repository's and the user's config. `git config` only
    /// reads settings, so it can safely list them. It exits with 1 when there are none; any other
    /// failure returns nil, and no command runs. Cached only when no `include` or `includeIf`
    /// directive is active, because included files can change without touching `.git/config`.
    private func configuredFilters() -> Set<String>? {
        let stamp = filterCacheStamp()
        let now = Date.timeIntervalSinceReferenceDate
        filterLock.lock()
        if let hit = cachedFilters, hit.stamp == stamp, now < hit.expiresAt {
            filterLock.unlock()
            return hit.names
        }
        filterLock.unlock()
        guard let parsed = rawRun(["config", "-z", "--get-regexp", "^(filter|include|includeif)\\."],
                                  GitRepository.safetySettings, acceptedStatuses: [0, 1])
            .flatMap(GitRepository.parseConfigFilters) else { return nil }
        filterLock.lock()
        cachedFilters = parsed.hasIncludes ? nil : (stamp, Date.timeIntervalSinceReferenceDate + 2.0, parsed.names)
        filterLock.unlock()
        return parsed.names
    }

    private static let includePrefix = Data("include.".utf8)
    private static let includeIfPrefix = Data("includeif.".utf8)

    private static func parseConfigFilters(_ configOutput: Data) -> (names: Set<String>, hasIncludes: Bool)? {
        var names = Set<String>()
        var hasIncludes = false
        for entry in configOutput.split(separator: 0) {
            let keyBytes = entry.prefix { $0 != 10 }
            if keyBytes.starts(with: includePrefix) || keyBytes.starts(with: includeIfPrefix) {
                hasIncludes = true
                continue
            }
            guard let key = String(bytes: keyBytes, encoding: .utf8) else { return nil }
            guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."), dot >= key.index(key.startIndex, offsetBy: 7) else { continue }
            names.insert(String(key[key.index(key.startIndex, offsetBy: 7)..<dot]))
        }
        return (names, hasIncludes)
    }

    /// Filter names in `git config -z --get-regexp ^filter\.` output. Each entry is the key, a
    /// newline and the value. A key can't contain a newline, but a filter's name can contain dots,
    /// `=`, spaces and quotes, so it ends at the key's last dot. Nil when a name isn't UTF-8 and
    /// so can't be passed to git to switch the filter off.
    static func filterNames(_ configOutput: Data) -> Set<String>? {
        var names = Set<String>()
        for entry in configOutput.split(separator: 0) {
            guard let key = String(bytes: entry.prefix { $0 != 10 }, encoding: .utf8) else { return nil }
            guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."), dot >= key.index(key.startIndex, offsetBy: 7) else { continue }
            names.insert(String(key[key.index(key.startIndex, offsetBy: 7)..<dot]))
        }
        return names
    }

    /// Empty commands for every configured clean/smudge/process filter, so `status` can't run them.
    static func filterSettings(_ configOutput: Data) -> [ConfigSetting]? {
        filterNames(configOutput).map { filterSettings(names: $0) }
    }

    static func filterSettings(names: Set<String>) -> [ConfigSetting] {
        names.sorted().flatMap { name in
            [("clean", ""), ("smudge", ""), ("process", ""), ("required", "false")].map { ("filter.\(name).\($0.0)", $0.1) }
        }
    }

    private func rawRun(_ args: [String], _ settings: [ConfigSetting], acceptedStatuses: Set<Int32> = [0],
                        maxOutputBytes: Int? = nil) -> Data? {
        guard let git = GitRepository.executable else { return nil }
        // A repository's core.worktree could point git at another folder, so a restore would
        // write files outside the one shown. The work tree is always the folder holding `.git`.
        return GitRepository.runProcess(URL(fileURLWithPath: git), ["-C", root.path, "--work-tree=" + root.path] + args,
                                        environment: GitRepository.environment(settings), acceptedStatuses: acceptedStatuses,
                                        maxOutputBytes: maxOutputBytes)
    }

    /// Longest a git command may run before it is stopped.
    static let timeout: TimeInterval = 30

    /// Standard output of a run that exited with one of `acceptedStatuses`, or nil if it failed,
    /// exceeded `maxOutputBytes`, or ran past `timeout`. The output is read on another thread, so a
    /// stalled network volume, or a child process that keeps the pipe open, can't hold the caller past the timeout.
    static func runProcess(_ executable: URL, _ args: [String], environment: [String: String], timeout: TimeInterval = GitRepository.timeout,
                           acceptedStatuses: Set<Int32> = [0], maxOutputBytes: Int? = nil) -> Data? {
        final class Output: @unchecked Sendable {
            var data = Data()
            var tooLarge = false
        }
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        // waitUntilExit() on a background thread can miss the exit and wait out the whole
        // timeout, so the exit is signaled by the termination handler instead.
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }
        let output = Output()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            if let limit = maxOutputBytes {
                let data = (try? out.fileHandleForReading.read(upToCount: limit + 1)) ?? Data()
                if data.count > limit {
                    output.tooLarge = true
                    p.terminate()
                    try? out.fileHandleForReading.close()
                } else {
                    output.data = data
                }
            } else {
                output.data = out.fileHandleForReading.readDataToEndOfFile()
            }
            exited.wait()
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
        if output.tooLarge { return nil }
        return p.terminationReason == .exit && acceptedStatuses.contains(p.terminationStatus) ? output.data : nil
    }

    static let statusArguments = statusArguments(includeUntracked: true)

    static func statusArguments(includeUntracked: Bool) -> [String] {
        ["status", "--porcelain=v1", "-z", includeUntracked ? "--untracked-files=all" : "--untracked-files=no", "--ignore-submodules=all"]
    }

    func status(_ completion: @escaping ([String: GitFileStatus]) -> Void) {
        GitRepository.runAsync {
            let data = self.run(GitRepository.statusArguments)
            let result = data.map(GitRepository.parseStatus) ?? [:]
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Reads `git status` once and, when `changesFilter` is given, builds the filtered Changes
    /// list from the same parsed entries without spawning a second `git status` process.
    func statusAndChanges(includeUntracked: Bool = true, changesFilter: ChangeFilter?,
                          _ completion: @escaping ([String: GitFileStatus], [StatusEntry], [ChangedFile]?) -> Void) {
        GitRepository.runAsync {
            let entries = self.run(GitRepository.statusArguments(includeUntracked: includeUntracked))
                .map(GitRepository.parseStatusEntries) ?? []
            let status = GitRepository.status(from: entries)
            let changes = changesFilter.map { self.changeList(entries, filter: $0) }
            DispatchQueue.main.async { completion(status, entries, changes) }
        }
    }

    /// One entry of `git status --porcelain=v1`: the file's state in the index (X) and in the work
    /// tree (Y).
    struct StatusEntry: Equatable {
        var path: String
        /// The path before a rename or copy.
        var originalPath: String?
        var index: Character
        var workTree: Character

        var isConflicted: Bool {
            index == "U" || workTree == "U" || (index == "A" && workTree == "A") || (index == "D" && workTree == "D")
        }

        /// The change a commit would record, or nil when nothing is staged.
        var staged: GitFileStatus? {
            guard !isConflicted else { return nil }
            switch index {
            case "M", "T": return .modified
            case "A", "C": return .added
            case "D": return .deleted
            case "R": return .renamed
            default: return nil
            }
        }

        /// The change in the work tree that isn't staged, or nil when there is none.
        var unstaged: GitFileStatus? {
            if isConflicted { return .conflicted }
            switch (index, workTree) {
            case ("?", "?"): return .untracked
            case ("!", _): return nil
            case (_, "M"), (_, "T"): return .modified
            case (_, "D"): return .deleted
            // An intent-to-add file (`git add -N`) is added, or renamed, in the work tree only.
            case (_, "A"): return .added
            case (_, "R"), (_, "C"): return .renamed
            default: return nil
            }
        }

        /// The file's state as a whole, as the sidebar colors it.
        var status: GitFileStatus {
            switch (index, workTree) {
            case ("?", "?"): return .untracked
            case ("!", "!"): return .ignored
            case _ where isConflicted: return .conflicted
            case ("R", _), (_, "R"): return .renamed
            case ("A", _), ("C", _), (_, "C"): return .added
            case ("D", _), (_, "D"): return .deleted
            default: return .modified
            }
        }
    }

    /// Parses `git status --porcelain=v1 -z`. Renames and copies, in the index or (for
    /// intent-to-add files) the work tree, are followed by an extra field holding the old path.
    static func parseStatusEntries(_ data: Data) -> [StatusEntry] {
        var result: [StatusEntry] = []
        let parts = data.split(separator: 0, omittingEmptySubsequences: true)
        var i = 0
        while i < parts.count {
            let entry = parts[i]
            i += 1
            guard entry.count > 3 else { continue }
            let x = Character(Unicode.Scalar(entry[entry.startIndex]))
            let y = Character(Unicode.Scalar(entry[entry.startIndex + 1]))
            var e = StatusEntry(path: String(decoding: entry.dropFirst(3), as: UTF8.self), index: x, workTree: y)
            if "RC".contains(x) || "RC".contains(y) {
                if i < parts.count { e.originalPath = String(decoding: parts[i], as: UTF8.self) }
                i += 1
            }
            result.append(e)
        }
        return result
    }

    static func status(from entries: [StatusEntry]) -> [String: GitFileStatus] {
        var result: [String: GitFileStatus] = [:]
        result.reserveCapacity(entries.count)
        for e in entries { result[e.path] = e.status }
        return result
    }

    static func parseStatus(_ data: Data) -> [String: GitFileStatus] {
        status(from: parseStatusEntries(data))
    }

    struct ChangedFile: Equatable {
        var path: String
        var status: GitFileStatus
        var added: Int?
        var removed: Int?
        /// In the Changes list, whether this is the file's staged change rather than its work-tree change.
        var staged = false
        var originalPath: String?
    }

    /// Files with uncommitted changes and their line counts against HEAD. Untracked files count
    /// every line as added; binary and very large files have no counts. Pass a `status` that was
    /// just read to skip running `git status` again.
    func changedFiles(status known: [String: GitFileStatus]? = nil, _ completion: @escaping ([ChangedFile]) -> Void) {
        GitRepository.runAsync {
            let status = known ?? self.run(GitRepository.statusArguments).map(GitRepository.parseStatus) ?? [:]
            let hasTracked = status.contains { $0.value != .ignored && $0.value != .untracked }
            let counts = !hasTracked ? [:] : (self.run(["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--numstat", "-z", "HEAD", "--"]).map(GitRepository.parseNumstat) ?? [:])
            var remainingBytes = GitRepository.untrackedReadBudget
            var out: [ChangedFile] = []
            out.reserveCapacity(status.count)
            for (path, st) in status where st != .ignored {
                var f = ChangedFile(path: path, status: st)
                if let c = counts[path] {
                    (f.added, f.removed) = (c.added, c.removed)
                } else if st == .untracked, let n = self.cachedLineCount(for: path, remainingBytes: &remainingBytes) {
                    (f.added, f.removed) = (n, 0)
                }
                out.append(f)
            }
            out.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// The Changes list: each file's staged change, counted against HEAD, and its unstaged change,
    /// counted against the staged copy. A file with both is listed twice. When `filter` excludes
    /// untracked, staged or unstaged changes, the corresponding Git and disk work is skipped.
    func changeList(filter: ChangeFilter = .all, _ completion: @escaping ([ChangedFile]) -> Void) {
        GitRepository.runAsync {
            let entries = self.run(GitRepository.statusArguments(includeUntracked: filter.includesUntracked))
                .map(GitRepository.parseStatusEntries) ?? []
            let out = self.changeList(entries, filter: filter)
            DispatchQueue.main.async { completion(out) }
        }
    }

    private func changeList(_ entries: [StatusEntry], filter: ChangeFilter = .all) -> [ChangedFile] {
        let diff = ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--numstat", "-z"]
        let needsStagedDiff = filter.includesStaged && entries.contains { e in
            guard let st = e.staged else { return false }
            return filter.matches(ChangedFile(path: e.path, status: st, staged: true))
        }
        let needsUnstagedDiff = filter.includesTrackedUnstaged && entries.contains { e in
            guard let st = e.unstaged, st != .untracked else { return false }
            return filter.matches(ChangedFile(path: e.path, status: st))
        }
        let stagedCounts = needsStagedDiff ? run(diff + ["--cached", "--"]).map(GitRepository.parseNumstat) ?? [:] : [:]
        let unstagedCounts = needsUnstagedDiff ? run(diff + ["--"]).map(GitRepository.parseNumstat) ?? [:] : [:]
        var remainingBytes = GitRepository.untrackedReadBudget
        var out: [ChangedFile] = []
        out.reserveCapacity(entries.count)
        for e in entries {
            if filter.includesStaged, let st = e.staged {
                var f = ChangedFile(path: e.path, status: st, staged: true, originalPath: e.originalPath)
                if filter.matches(f) {
                    if let c = stagedCounts[e.path] { (f.added, f.removed) = (c.added, c.removed) }
                    out.append(f)
                }
            }
            if let st = e.unstaged {
                if st == .untracked && !filter.includesUntracked { continue }
                if st != .untracked && !filter.includesTrackedUnstaged { continue }
                var f = ChangedFile(path: e.path, status: st, originalPath: e.staged == nil ? e.originalPath : nil)
                if filter.matches(f) {
                    if let c = unstagedCounts[e.path] {
                        (f.added, f.removed) = (c.added, c.removed)
                    } else if st == .untracked, let n = cachedLineCount(for: e.path, remainingBytes: &remainingBytes) {
                        (f.added, f.removed) = (n, 0)
                    }
                    out.append(f)
                }
            }
        }
        out.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return out
    }

    /// Parses `git diff --numstat -z`. Binary files report "-" and get no counts.
    static func parseNumstat(_ data: Data) -> [String: (added: Int, removed: Int)] {
        var result: [String: (added: Int, removed: Int)] = [:]
        let parts = data.split(separator: 0, omittingEmptySubsequences: false)
        var i = 0
        while i < parts.count {
            let fields = parts[i].split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            i += 1
            guard fields.count == 3 else { continue }
            var path = String(decoding: fields[2], as: UTF8.self)
            // A rename leaves the path field empty and is followed by the old and new paths.
            if path.isEmpty {
                guard i + 1 < parts.count else { break }
                path = String(decoding: parts[i + 1], as: UTF8.self)
                i += 2
            }
            guard let a = Int(String(decoding: fields[0], as: UTF8.self)),
                  let r = Int(String(decoding: fields[1], as: UTF8.self)) else { continue }
            result[path] = (a, r)
        }
        return result
    }

    private func cachedLineCount(for relativePath: String, remainingBytes: inout Int) -> Int? {
        let limit = 4_000_000
        let url = root.appendingPathComponent(relativePath)
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else { return nil }
        let stamp = DiskStamp(info: info)
        lineCountLock.lock()
        if let hit = lineCountCache[relativePath], hit.stamp == stamp {
            lineCountLock.unlock()
            return hit.count
        }
        lineCountLock.unlock()
        let bytes = max(0, Int(info.st_size))
        guard remainingBytes >= bytes else { return nil }
        remainingBytes -= max(1, bytes)
        let count = GitRepository.lineCount(of: url)
        lineCountLock.lock()
        if lineCountCache.count >= 4096 { lineCountCache.removeAll(keepingCapacity: true) }
        lineCountCache[relativePath] = CachedLineCount(stamp: stamp, count: count)
        lineCountLock.unlock()
        return count
    }

    /// Lines in a regular file of up to 4 MB that isn't binary, following a symlink to its target.
    static func lineCount(of url: URL) -> Int? {
        let limit = 4_000_000
        // O_NONBLOCK keeps a FIFO from blocking the open, and fstat checks what was actually
        // opened, so a link to /dev/zero or a huge file is refused before anything is read.
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else { return nil }
        let data: Data
        do { data = try file.read(upToCount: limit + 1) ?? Data() } catch { return nil }
        guard data.count <= limit else { return nil }
        guard !data.isEmpty else { return 0 }
        var newlines = 0
        let hasNull = data.withUnsafeBytes { buf -> Bool in
            for b in buf {
                if b == 0 { return true }
                if b == 10 { newlines += 1 }
            }
            return false
        }
        guard !hasNull else { return nil }
        return newlines + (data.last == 10 ? 0 : 1)
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
        GitRepository.runAsync {
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

    // MARK: Staging and discarding

    /// What staging, unstaging or discarding did, file by file.
    struct ActionResult {
        enum Refusal: Equatable { case filtered, conflicted, notBackedUp }
        var done: [String] = []
        /// Files left as they were, and why.
        var refused: [(path: String, reason: Refusal)] = []
        /// Files git reported an error for.
        var failed: [String] = []
    }

    /// Stage, unstage and discard each take git's index lock, so they run one at a time.
    private static let actionQueue = DispatchQueue(label: "app.tovri.git-actions", qos: .userInitiated)

    func perform(_ action: @escaping (GitRepository) -> ActionResult, completion: @escaping (ActionResult) -> Void) {
        GitRepository.actionQueue.async {
            let result = action(self)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func moveToTrash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }

    /// The files among `paths` whose `filter` attribute names a filter driver in the repository's
    /// or the user's config, such as Git LFS. Tovri switches filters off, so `git add` would store
    /// such a file without its clean step, and `git restore` would write what is stored (an LFS
    /// pointer) without its smudge step. `check-attr` only reads attribute files. Nil if git failed.
    func filteredPaths(_ paths: [String]) -> Set<String>? {
        guard !paths.isEmpty else { return [] }
        guard let drivers = configuredFilters() else { return nil }
        guard !drivers.isEmpty else { return [] }
        let settings = GitRepository.safetySettings + GitRepository.filterSettings(names: drivers)
        var out = Set<String>()
        for chunk in GitRepository.chunks(paths) {
            guard let data = rawRun(["check-attr", "-z", "filter", "--"] + chunk, settings) else { return nil }
            // Each answer is the path, the attribute and its value, in the order the paths were given.
            let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count >= chunk.count * 3 else { return nil }
            for (k, path) in chunk.enumerated() where drivers.contains(String(decoding: fields[k * 3 + 2], as: UTF8.self)) {
                out.insert(path)
            }
        }
        return out
    }

    /// `git add` for the files' work-tree changes, deletions included. Runs on the calling thread.
    func stage(_ files: [ChangedFile]) -> ActionResult {
        var result = ActionResult()
        let paths = GitRepository.unique(files.map(\.path))
        // Staging a deletion stores no content, so no filter would run for it.
        let deleted = Set(files.filter { $0.status == .deleted }.map(\.path))
        guard let filtered = filteredPaths(paths.filter { !deleted.contains($0) }) else {
            result.failed = paths
            return result
        }
        result.refused = paths.filter(filtered.contains).map { ($0, .filtered) }
        runInChunks(["add", "-A", "--"], paths.filter { !filtered.contains($0) }, into: &result)
        return result
    }

    /// Puts the staged copies of the files back to HEAD's, leaving the work tree alone. Runs on the
    /// calling thread. Plain paths are batched in chunks; staged renames reset both new and old paths.
    func unstage(_ files: [ChangedFile]) -> ActionResult {
        var result = ActionResult()
        let unique = GitRepository.unique(files, by: \.path)
        let plain = unique.filter { $0.originalPath == nil }.map(\.path)
        for chunk in GitRepository.chunks(plain) {
            if run(["reset", "-q", "--"] + chunk) != nil {
                result.done += chunk
            } else {
                for path in chunk {
                    if run(["reset", "-q", "--", path]) != nil { result.done.append(path) } else { result.failed.append(path) }
                }
            }
        }
        for f in unique where f.originalPath != nil {
            // A staged rename is undone at both its new and its old path. `reset` also works
            // before the first commit, where `restore --staged` has no HEAD to restore from.
            let paths = [f.path] + (f.originalPath.map { [$0] } ?? [])
            if run(["reset", "-q", "--"] + paths) != nil { result.done.append(f.path) } else { result.failed.append(f.path) }
        }
        return result
    }

    /// Throws away the files' work-tree changes. New files are moved to the Trash. Changed and
    /// deleted files are restored from their staged copy, which is the last commit's when nothing
    /// is staged, after a copy of each as it is now has been put in the Trash. Nothing is restored
    /// unless that copy is safely there. Runs on the calling thread.
    func discard(_ files: [ChangedFile], trash: (URL) throws -> Void = GitRepository.moveToTrash) -> ActionResult {
        var result = ActionResult()
        var tracked: [String] = []
        var untracked: [String] = []
        for f in GitRepository.unique(files, by: \.path) {
            switch f.status {
            case .conflicted: result.refused.append((f.path, .conflicted))
            case .untracked: untracked.append(f.path)
            default: tracked.append(f.path)
            }
        }
        if let filtered = filteredPaths(tracked) {
            result.refused += tracked.filter(filtered.contains).map { ($0, .filtered) }
            tracked.removeAll(where: filtered.contains)
        } else {
            result.failed += tracked
            tracked = []
        }
        if !tracked.isEmpty && !backUp(tracked, trash: trash) {
            result.refused += tracked.map { ($0, .notBackedUp) }
            tracked = []
        }
        for path in untracked {
            do {
                try trash(root.appendingPathComponent(path))
                result.done.append(path)
            } catch {
                result.refused.append((path, .notBackedUp))
            }
        }
        runInChunks(["restore", "--worktree", "--"], tracked, into: &result)
        return result
    }

    private static let backupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// Copies the files as they are now into one folder and moves it to the Trash. Deleted files
    /// have nothing to keep. False if any copy couldn't be made or the Trash refused the folder.
    private func backUp(_ paths: [String], trash: (URL) throws -> Void) -> Bool {
        let fm = FileManager.default
        var present: [(path: String, url: URL)] = []
        for p in paths {
            let url = root.appendingPathComponent(p)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            // Copying a FIFO or a device would block or read without end.
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFLNK else { return false }
            present.append((p, url))
        }
        guard !present.isEmpty else { return true }
        // On the repository's volume, so copies are clones and the folder goes to that volume's Trash.
        let parent = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root, create: true))
            ?? fm.temporaryDirectory.appendingPathComponent("Tovri-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: parent) }
        let stamp = GitRepository.backupDateFormatter.string(from: Date())
        let folder = parent.appendingPathComponent("Discarded changes in \(root.lastPathComponent) \(stamp)")
        do {
            for (p, url) in present {
                let copy = folder.appendingPathComponent(p)
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: copy)
            }
            try trash(folder)
            return true
        } catch {
            return false
        }
    }

    private func runInChunks(_ command: [String], _ paths: [String], into result: inout ActionResult) {
        for chunk in GitRepository.chunks(paths) {
            if run(command + chunk) != nil { result.done += chunk } else { result.failed += chunk }
        }
    }

    /// Keeps each command line well under the system's argument limit.
    private static func chunks(_ paths: [String], size: Int = 500) -> [[String]] {
        stride(from: 0, to: paths.count, by: size).map { Array(paths[$0..<min($0 + size, paths.count)]) }
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func unique(_ files: [ChangedFile], by key: KeyPath<ChangedFile, String>) -> [ChangedFile] {
        var seen = Set<String>()
        return files.filter { seen.insert($0[keyPath: key]).inserted }
    }

    /// The files' changes as `git diff` writes them: staged changes against HEAD, the others
    /// against the staged copy, and new files in full.
    func patch(for files: [ChangedFile], _ completion: @escaping (String) -> Void) {
        GitRepository.runAsync {
            let diff = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--ignore-submodules=all"]
            var out = Data()
            let staged = GitRepository.unique(files.filter(\.staged).flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
            for chunk in GitRepository.chunks(staged) { out += self.run(diff + ["--cached", "--"] + chunk) ?? Data() }
            let unstaged = GitRepository.unique(files.filter { !$0.staged && $0.status != .untracked }.map(\.path))
            for chunk in GitRepository.chunks(unstaged) { out += self.run(diff + ["--"] + chunk) ?? Data() }
            for f in GitRepository.unique(files.filter { !$0.staged && $0.status == .untracked }, by: \.path) {
                var info = stat()
                let type = lstat(self.root.appendingPathComponent(f.path).path, &info) == 0 ? info.st_mode & S_IFMT : 0
                guard type == S_IFREG || type == S_IFLNK else { continue }
                // Exits with 1 when the files differ, which a new file always does.
                out += self.run(diff + ["--no-index", "--", "/dev/null", f.path], acceptedStatuses: [0, 1]) ?? Data()
            }
            let text = String(decoding: out, as: UTF8.self)
            DispatchQueue.main.async { completion(text) }
        }
    }

    struct Commit: Equatable {
        var sha: String
        var shortSHA: String
        var author: String
        var date: Date
        var subject: String
        /// The file's path in this commit, which differs from today's after a rename.
        var path: String
    }

    /// Commits that changed the file, newest first, following renames.
    func history(of url: URL, limit: Int = 200, _ completion: @escaping ([Commit]) -> Void) {
        guard let rel = relativePath(url) else { completion([]); return }
        GitRepository.runAsync {
            // -z writes each path as-is, ending in NUL; without it git quotes and escapes
            // non-ASCII names, tabs, quotes and newlines.
            let data = self.run(["log", "--no-show-signature", "--no-ext-diff", "--no-textconv", "--follow", "-z", "-n", String(limit), "--format=%x1e%H%x1f%h%x1f%an%x1f%at%x1f%s", "--name-only", "--", rel])
            let commits = data.map { GitRepository.parseHistory($0, fallbackPath: rel) } ?? []
            DispatchQueue.main.async { completion(commits) }
        }
    }

    /// Parses `log -z --format=%x1e%H%x1f%h%x1f%an%x1f%at%x1f%s --name-only`: each record is the
    /// header, NUL, a newline, then the path ending in NUL. Paths are kept byte for byte.
    static func parseHistory(_ data: Data, fallbackPath: String) -> [Commit] {
        data.split(separator: 0x1e).compactMap { record in
            let parts = record.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
            guard let headerBytes = parts.first else { return nil }
            let f = String(decoding: headerBytes, as: UTF8.self)
                .split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, !f[0].isEmpty, let t = TimeInterval(f[3]) else { return nil }
            var path = fallbackPath
            if parts.count > 1 {
                var rest = parts[1]
                if rest.first == 10 { rest = rest.dropFirst() }
                if let end = rest.firstIndex(of: 0) { rest = rest[rest.startIndex..<end] }
                if !rest.isEmpty { path = String(decoding: rest, as: UTF8.self) }
            }
            return Commit(sha: f[0], shortSHA: f[1], author: f[2], date: Date(timeIntervalSince1970: t), subject: f[4], path: path)
        }
    }

    /// Raw bytes of `path` (relative to the repository) in `commit`, or nil if it isn't a blob
    /// or exceeds `maxBlobSize`. `cat-file blob` refuses trees, commits and tags and runs no filters.
    func contents(of path: String, at commit: String, maxBytes: Int = GitRepository.maxBlobSize,
                  _ completion: @escaping (Data?) -> Void) {
        GitRepository.runAsync {
            let data = self.run(["cat-file", "blob", commit + ":" + path], maxOutputBytes: maxBytes)
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// Raw bytes of the file at HEAD, or nil if it isn't a tracked blob or exceeds `maxBytes`. The
    /// caller decodes them with the document's encoding, since UTF-16 or Windows-1252 bytes read as
    /// UTF-8 would be garbage.
    func headContents(of url: URL, maxBytes: Int = GitRepository.maxBlobSize,
                      _ completion: @escaping (Data?) -> Void) {
        guard let rel = relativePath(url) else { completion(nil); return }
        GitRepository.runAsync {
            let data = self.run(["cat-file", "blob", "HEAD:" + rel], maxOutputBytes: maxBytes)
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
