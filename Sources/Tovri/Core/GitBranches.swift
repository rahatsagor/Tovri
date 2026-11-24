import Foundation

/// What git wrote to standard error, keeping the first 64 KB. The rest is read and dropped, so a
/// command that writes a lot can't stall on a full pipe.
final class GitErrorCapture: @unchecked Sendable {
    static let limit = 64 * 1024
    private let lock = NSLock()
    private var data = Data()

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.readData(ofLength: 16 * 1024)
            if chunk.isEmpty { break }
            lock.lock()
            if data.count < GitErrorCapture.limit { data.append(chunk.prefix(GitErrorCapture.limit - data.count)) }
            lock.unlock()
        }
    }
}

extension GitRepository {
    // MARK: Listing

    struct Branch: Equatable {
        var refName: String
        var name: String
        var isRemote: Bool
        var isCurrent: Bool
        var date: Date?
        var shortSHA: String
        var upstream: String?
        var subject: String

        /// The local branch a remote-tracking branch would create: "origin/x" gives "x".
        var localName: String {
            guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
            return String(name[name.index(after: slash)...])
        }
    }

    /// Local and remote-tracking branches, newest commit first.
    func branches(_ completion: @escaping ([Branch]?) -> Void) {
        GitRepository.runAsync {
            let data = self.run(["for-each-ref", "--sort=-committerdate",
                                 "--format=%(refname)%00%(refname:short)%00%(HEAD)%00%(committerdate:unix)%00%(objectname:short)%00%(upstream:short)%00%(subject)",
                                 "refs/heads", "refs/remotes"])
            let list = data.map(GitRepository.parseBranches)
            DispatchQueue.main.async { completion(list) }
        }
    }

    static func parseBranches(_ data: Data) -> [Branch] {
        var out: [Branch] = []
        for line in data.split(separator: 0x0A) {
            let f = line.split(separator: 0, maxSplits: 6, omittingEmptySubsequences: false)
            guard f.count == 7 else { continue }
            let ref = String(decoding: f[0], as: UTF8.self)
            let remote = ref.hasPrefix("refs/remotes/")
            guard remote || ref.hasPrefix("refs/heads/"), !(remote && ref.hasSuffix("/HEAD")) else { continue }
            let upstream = String(decoding: f[5], as: UTF8.self)
            out.append(Branch(refName: ref, name: String(decoding: f[1], as: UTF8.self), isRemote: remote,
                              isCurrent: f[2].first == UInt8(ascii: "*"),
                              date: TimeInterval(String(decoding: f[3], as: UTF8.self)).map(Date.init(timeIntervalSince1970:)),
                              shortSHA: String(decoding: f[4], as: UTF8.self),
                              upstream: upstream.isEmpty ? nil : upstream,
                              subject: String(decoding: f[6], as: UTF8.self)))
        }
        return out
    }

    // MARK: Switching

    enum BranchTarget: Equatable {
        case local(String)
        /// A remote-tracking branch such as "origin/x".
        case remote(String)
        case create(String)
    }

    enum SwitchRefusal: Equatable {
        case invalidName, alreadyExists, alreadyOn
        case unsaved([String]), uncommitted([String]), untracked([String]), filtered([String])
    }

    enum SwitchOutcome: Equatable {
        case switched(String), created(String), refused(SwitchRefusal), failed(String)
    }

    /// The branch HEAD points at, read from `headToken`; nil when detached.
    var currentBranchName: String? {
        guard let token = headToken, token.hasPrefix("ref: refs/heads/") else { return nil }
        return token.dropFirst("ref: refs/heads/".count).split(separator: " ").first.map(String.init)
    }

    private func refExists(_ ref: String) -> Bool {
        run(["show-ref", "--verify", "--quiet", ref]) != nil
    }

    /// Switches branches the way `git switch` does, after checking that nothing would be lost. Runs on
    /// the calling thread. `unsavedPaths` are repository-relative paths with unsaved edits in the editor.
    func switchBranch(to target: BranchTarget, unsavedPaths: Set<String>) -> SwitchOutcome {
        switch target {
        case .create(let name):
            guard !name.isEmpty, !name.hasPrefix("-"),
                  let normalized = run(["check-ref-format", "--branch", name]).map({ String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }),
                  !normalized.isEmpty, !normalized.hasPrefix("-") else { return .refused(.invalidName) }
            if refExists("refs/heads/" + normalized) { return .refused(.alreadyExists) }
            let errors = GitErrorCapture()
            guard run(["switch", "-q", "-c", normalized], standardError: errors) != nil else { return .failed(errors.text) }
            return .created(normalized)
        case .local(let name):
            guard !name.isEmpty, !name.hasPrefix("-") else { return .refused(.invalidName) }
            if name == currentBranchName { return .refused(.alreadyOn) }
            return switchChecked(ref: "refs/heads/" + name, arguments: [name], result: name, unsavedPaths: unsavedPaths)
        case .remote(let name):
            guard !name.isEmpty, !name.hasPrefix("-"), let slash = name.firstIndex(of: "/"),
                  case let local = String(name[name.index(after: slash)...]), !local.isEmpty else { return .refused(.invalidName) }
            if refExists("refs/heads/" + local) { return .refused(.alreadyExists) }
            return switchChecked(ref: "refs/remotes/" + name, arguments: ["--track", name], result: local, unsavedPaths: unsavedPaths)
        }
    }

    private func switchChecked(ref: String, arguments: [String], result: String, unsavedPaths: Set<String>) -> SwitchOutcome {
        guard refExists(ref) else { return .failed("That branch no longer exists.") }
        switch refusal(switchingTo: ref, unsavedPaths: unsavedPaths) {
        case .failure(let failure): return .failed(failure.message)
        case .success(let refusal?): return .refused(refusal)
        case .success(nil): break
        }
        // Never `-f`, `--discard-changes` or `--merge`: git itself refuses whatever the checks missed.
        let errors = GitErrorCapture()
        guard run(["switch", "-q", "--no-guess"] + arguments, standardError: errors) != nil else { return .failed(errors.text) }
        return .switched(result)
    }

    private struct CheckFailure: Error { var message: String }

    private func refusal(switchingTo ref: String, unsavedPaths: Set<String>) -> Result<SwitchRefusal?, CheckFailure> {
        var changed: [GitRepository.CommitFile] = []
        if isUnborn {
            guard let data = run(["ls-tree", "-r", "-z", "--name-only", ref]) else { return .failure(CheckFailure(message: "Couldn’t read the branch")) }
            changed = data.split(separator: 0).map { CommitFile(path: String(decoding: $0, as: UTF8.self), originalPath: nil, status: .added) }
        } else {
            guard let data = run(["diff-tree", "-r", "-z", "--name-status", "--no-renames", "HEAD", ref, "--"]) else {
                return .failure(CheckFailure(message: "Couldn’t compare the branches"))
            }
            changed = GitRepository.parseNameStatus(data)
        }
        let paths = Set(changed.map(\.path))
        guard !paths.isEmpty else { return .success(nil) }

        let unsaved = paths.intersection(unsavedPaths)
        if !unsaved.isEmpty { return .success(.unsaved(unsaved.sorted())) }

        guard let status = run(GitRepository.statusArguments(includeUntracked: true)) else {
            return .failure(CheckFailure(message: "Couldn’t read the repository’s status"))
        }
        let entries = GitRepository.parseStatusEntries(status)
        var tracked = Set<String>(), untracked = Set<String>()
        for e in entries {
            if e.index == "?" { untracked.insert(e.path); continue }
            if e.index == "!" { continue }
            tracked.insert(e.path)
            if let old = e.originalPath { tracked.insert(old) }
        }
        let uncommitted = paths.intersection(tracked)
        if !uncommitted.isEmpty { return .success(.uncommitted(uncommitted.sorted())) }

        var blocking = paths.intersection(untracked)
        // Git overwrites an ignored file where the target tracks one, so anything on disk counts.
        for file in changed where file.status == .added && !blocking.contains(file.path) {
            var info = stat()
            if lstat(root.appendingPathComponent(file.path).path, &info) == 0 { blocking.insert(file.path) }
        }
        if !blocking.isEmpty { return .success(.untracked(blocking.sorted())) }

        if let drivers = configuredOverrides()?.filters, !drivers.isEmpty {
            guard let filtered = filteredPaths(Array(paths), includeIndex: true) else {
                return .failure(CheckFailure(message: "Couldn’t check the files’ Git attributes"))
            }
            if !filtered.isEmpty { return .success(.filtered(filtered.sorted())) }
            var viaTarget: [String] = []
            for file in changed where file.status != .deleted && (file.path as NSString).lastPathComponent == ".gitattributes" {
                guard let blob = run(["cat-file", "blob", ref + ":" + file.path], maxOutputBytes: 1_000_000) else { continue }
                if GitRepository.attributes(String(decoding: blob, as: UTF8.self), useAny: drivers) { viaTarget.append(file.path) }
            }
            if !viaTarget.isEmpty { return .success(.filtered(viaTarget.sorted())) }
        }
        return .success(nil)
    }

    /// Whether a .gitattributes file sets `filter=<driver>` for one of `drivers`.
    static func attributes(_ text: String, useAny drivers: Set<String>) -> Bool {
        for line in text.split(whereSeparator: \.isNewline) {
            for word in line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst() where word.hasPrefix("filter=") {
                if drivers.contains(String(word.dropFirst("filter=".count))) { return true }
            }
        }
        return false
    }

    /// `switchBranch` on the serial queue shared with stage, unstage and discard; completes on main.
    func performSwitch(to target: BranchTarget, unsavedPaths: Set<String>, completion: @escaping (SwitchOutcome) -> Void) {
        GitRepository.actionQueue.async {
            let outcome = self.switchBranch(to: target, unsavedPaths: unsavedPaths)
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
