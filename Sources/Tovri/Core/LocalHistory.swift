import CryptoKit
import Foundation

/// Earlier versions of files, kept only on this Mac. Before Tovri saves over a file, the text that
/// was on disk is copied into Application Support, one folder per file path with an index.json
/// listing the copies. Copying happens on a background queue, and a failure there never affects
/// the save.
final class LocalHistory {
    struct Snapshot: Codable, Equatable {
        /// The copy's file name inside the history folder of its file.
        let name: String
        /// When Tovri saved over this version.
        let date: Date
        /// When this version was written, from the file's modification time.
        let modified: Date
        let size: Int
        let hash: String
    }

    struct Limits {
        var maxFileSize = 20_000_000
        var maxSnapshotsPerFile = 50
        var maxAge: TimeInterval = 30 * 24 * 60 * 60
        var maxTotalSize = 500_000_000
        /// Checking the total means reading every index, so it's done at most this often.
        var fullPruneInterval: TimeInterval = 60 * 60
    }

    private struct Index: Codable {
        var path: String
        /// Oldest first.
        var snapshots: [Snapshot]
    }

    static var shared = LocalHistory(directory: LocalHistory.defaultDirectory)

    static var defaultDirectory: URL {
        // The tests save many files; their copies must not fill the history of the person running them.
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("TovriTests-History-\(getpid())", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tovri", isDirectory: true).appendingPathComponent("History", isDirectory: true)
    }

    let directory: URL
    let limits: Limits
    private let now: () -> Date
    private let queue = DispatchQueue(label: "app.tovri.history", qos: .utility)
    /// Only touched on `queue`.
    private var lastFullPrune: Date?

    init(directory: URL, limits: Limits = Limits(), now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.limits = limits
        self.now = now
    }

    /// The path a file's history is kept under: the same file reached through a symlink shares it.
    static func key(for url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    // MARK: Recording

    /// Keeps the current contents of `url`, if it's a regular file, before a save replaces them
    /// with `newData`. Returns at once; the copy is written in the background.
    func recordBeforeOverwrite(of url: URL, with newData: Data) {
        let path = LocalHistory.key(for: url)
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= limits.maxFileSize else {
            close(fd)
            return
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        let taken = now()
        let limit = limits.maxFileSize
        // A file with other hard links is overwritten in place, so its bytes are read before the
        // save starts. Any other file is replaced by renaming a new file over it, and the open
        // descriptor keeps the old one readable for the background copy.
        if info.st_nlink > 1 {
            let data = LocalHistory.read(fd, limit: limit)
            close(fd)
            guard let data else { return }
            queue.async { self.store(data, path: path, modified: modified, taken: taken, replacing: newData) }
        } else {
            queue.async {
                let data = LocalHistory.read(fd, limit: limit)
                close(fd)
                guard let data else { return }
                self.store(data, path: path, modified: modified, taken: taken, replacing: newData)
            }
        }
    }

    private func store(_ data: Data, path: String, modified: Date, taken: Date, replacing newData: Data) {
        defer { pruneAllIfDue() }
        guard data != newData else { return }
        let hash = LocalHistory.hex(Data(SHA256.hash(data: data)))
        let folder = folderURL(forKey: path)
        do {
            try makePrivateDirectory(directory)
            try makePrivateDirectory(folder)
            var index = loadIndex(folder) ?? Index(path: path, snapshots: [])
            // A different file whose path hashes the same; it's left alone rather than mixed in.
            guard index.path == path else { return }
            if index.snapshots.last?.hash == hash { return }
            var name = "\(Int64(taken.timeIntervalSince1970 * 1000))-\(hash.prefix(12)).snapshot"
            if index.snapshots.contains(where: { $0.name == name }) { name = "\(UUID().uuidString).snapshot" }
            try writePrivate(data, to: folder.appendingPathComponent(name))
            index.snapshots.append(Snapshot(name: name, date: taken, modified: modified, size: data.count, hash: hash))
            prune(&index, in: folder)
            try saveIndex(index, in: folder)
        } catch {
            // Best effort: the save itself already went ahead.
        }
    }

    // MARK: Reading

    /// The kept versions of `url`, newest first.
    func snapshots(for url: URL) -> [Snapshot] {
        queue.sync { snapshotsOnQueue(forKey: LocalHistory.key(for: url)) }
    }

    func snapshots(for url: URL, completion: @escaping ([Snapshot]) -> Void) {
        let key = LocalHistory.key(for: url)
        queue.async {
            let list = self.snapshotsOnQueue(forKey: key)
            DispatchQueue.main.async { completion(list) }
        }
    }

    private func snapshotsOnQueue(forKey key: String) -> [Snapshot] {
        guard let index = loadIndex(folderURL(forKey: key)), index.path == key else { return [] }
        return index.snapshots.reversed()
    }

    /// The bytes of a kept version, or nil if it has been pruned or can't be read.
    func data(of snapshot: Snapshot, for url: URL) -> Data? {
        let file = folderURL(forKey: LocalHistory.key(for: url)).appendingPathComponent(snapshot.name)
        return try? LocalHistory.readRegularFile(file, limit: Int.max)
    }

    // MARK: Clearing and pruning

    func clear(completion: (() -> Void)? = nil) {
        queue.async {
            try? FileManager.default.removeItem(at: self.directory)
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Waits for copies and pruning queued so far.
    func waitUntilIdle() { queue.sync {} }

    /// Applies every limit now, rather than when the next copy is written.
    func pruneNow() { queue.sync { pruneAll() } }

    /// Drops copies older than the age limit and the oldest beyond the count limit.
    private func prune(_ index: inout Index, in folder: URL) {
        let cutoff = now().addingTimeInterval(-limits.maxAge)
        var drop = index.snapshots.filter { $0.date < cutoff }
        var keep = index.snapshots.filter { $0.date >= cutoff }
        if keep.count > limits.maxSnapshotsPerFile {
            drop += keep.prefix(keep.count - limits.maxSnapshotsPerFile)
            keep.removeFirst(keep.count - limits.maxSnapshotsPerFile)
        }
        guard !drop.isEmpty else { return }
        for s in drop { try? FileManager.default.removeItem(at: folder.appendingPathComponent(s.name)) }
        index.snapshots = keep
    }

    private func pruneAllIfDue() {
        if let last = lastFullPrune, now().timeIntervalSince(last) < limits.fullPruneInterval { return }
        pruneAll()
    }

    /// Applies the per-file limits to every file, then removes the oldest copies of any file until
    /// the whole history fits the total size limit.
    private func pruneAll() {
        lastFullPrune = now()
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        var indexes: [(folder: URL, index: Index)] = []
        for folder in folders {
            guard var index = loadIndex(folder) else { continue }
            let before = index.snapshots.count
            prune(&index, in: folder)
            if index.snapshots.count != before { try? saveIndex(index, in: folder) }
            indexes.append((folder, index))
        }
        var total = indexes.reduce(0) { $0 + $1.index.snapshots.reduce(0) { $0 + $1.size } }
        if total > limits.maxTotalSize {
            var all = indexes.indices.flatMap { i in indexes[i].index.snapshots.map { (i, $0) } }
            all.sort { $0.1.date < $1.1.date }
            var changed = Set<Int>()
            for (i, s) in all {
                guard total > limits.maxTotalSize else { break }
                try? fm.removeItem(at: indexes[i].folder.appendingPathComponent(s.name))
                indexes[i].index.snapshots.removeAll { $0.name == s.name }
                total -= s.size
                changed.insert(i)
            }
            for i in changed { try? saveIndex(indexes[i].index, in: indexes[i].folder) }
        }
        for entry in indexes where entry.index.snapshots.isEmpty { try? fm.removeItem(at: entry.folder) }
    }

    // MARK: Storage

    private func folderURL(forKey key: String) -> URL {
        let id = LocalHistory.hex(Data(SHA256.hash(data: Data(key.utf8)))).prefix(32)
        return directory.appendingPathComponent(String(id), isDirectory: true)
    }

    private func loadIndex(_ folder: URL) -> Index? {
        guard let data = try? LocalHistory.readRegularFile(folder.appendingPathComponent("index.json"), limit: 4_000_000) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Index.self, from: data)
    }

    private func saveIndex(_ index: Index, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(try encoder.encode(index), to: folder.appendingPathComponent("index.json"))
    }

    private func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(url.path, 0o700)
    }

    /// Writes beside the target and renames into place, readable only by the user.
    private func writePrivate(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var done = 0
            while done < raw.count {
                let n = write(fd, base + done, raw.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                done += n
            }
        }
        if failure == 0 && fchmod(fd, 0o600) != 0 { failure = errno }
        close(fd)
        if failure == 0 && rename(temp, url.path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    // MARK: Reading files safely

    enum ReadProblem: Error, Equatable {
        case notAFile
        case tooLarge
        case unreadable
    }

    /// Reads a regular file of at most `limit` bytes. It's opened without waiting, so a named pipe
    /// or device that looks like a file can't hang the caller.
    static func readRegularFile(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ReadProblem.unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ReadProblem.unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ReadProblem.notAFile }
        guard Int(info.st_size) <= limit else { throw ReadProblem.tooLarge }
        guard let data = read(fd, limit: limit) else { throw ReadProblem.tooLarge }
        return data
    }

    /// Reads from the start of `fd`; nil on an error or once more than `limit` bytes arrive.
    private static func read(_ fd: Int32, limit: Int) -> Data? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        var data = Data(count: max(Int(info.st_size), 0) + 1)
        var filled = 0
        while true {
            if filled == data.count {
                guard data.count <= limit else { return nil }
                data.count += max(1 << 16, data.count / 4)
            }
            let n = data.withUnsafeMutableBytes { raw in pread(fd, raw.baseAddress! + filled, raw.count - filled, off_t(filled)) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            filled += n
        }
        guard filled <= limit else { return nil }
        data.count = filled
        return data
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
