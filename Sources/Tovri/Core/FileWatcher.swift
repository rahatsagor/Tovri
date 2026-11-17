import Foundation
import CoreServices

/// Recursive FSEvents watcher delivering changed directory paths on the main queue.
final class FileWatcher {
    private final class Box {
        let callback: ([String], Bool) -> Void
        var active = true
        init(_ callback: @escaping ([String], Bool) -> Void) { self.callback = callback }
    }

    private var stream: FSEventStreamRef?
    private let box: Box

    init?(path: String, latency: TimeInterval = 0.3, callback: @escaping ([String], Bool) -> Void) {
        let box = Box(callback)
        self.box = box
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Box>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            guard box.active else { return }
            let array = unsafeBitCast(paths, to: NSArray.self)
            var result: [String] = []
            result.reserveCapacity(count)
            var mustScanSubDirs = false
            let rescanMask = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
            for i in 0..<count {
                if let s = array[i] as? String { result.append(s) }
                if (flags[i] & rescanMask) != 0 { mustScanSubDirs = true }
            }
            box.callback(result, mustScanSubDirs)
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &context, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    func stop() {
        box.active = false
        guard let s = stream else { return }
        stream = nil
        if Thread.isMainThread {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        } else {
            DispatchQueue.main.async {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
            }
        }
    }

    deinit { stop() }
}

/// Background index of every file in a project folder, used by Go to File.
final class ProjectIndex {
    struct Entry {
        let relativePath: String
        let units: [UInt16]
        let basenameStart: Int
    }

    let root: URL
    private(set) var entries: [Entry] = []
    private(set) var isBuilding = false
    private var generation = 0
    private var pendingRebuild = false
    var onUpdate: (() -> Void)?
    static let maxFiles = 300_000

    init(root: URL) {
        self.root = root
        rebuild()
    }

    func rebuild() {
        if isBuilding { pendingRebuild = true; return }
        isBuilding = true
        generation += 1
        let gen = generation
        let root = self.root
        let excludes = Settings.shared.searchExcludes.union(Settings.shared.hiddenPatterns)
        DispatchQueue.global(qos: .utility).async {
            let files = ProjectIndex.enumerate(root: root, excludes: excludes, limit: ProjectIndex.maxFiles)
            let entries = files.map { rel -> Entry in
                let units = Array(rel.utf16)
                var base = 0
                if let slash = units.lastIndex(of: 47) { base = slash + 1 }
                return Entry(relativePath: rel, units: units, basenameStart: base)
            }
            DispatchQueue.main.async {
                if Perf.enabled { Perf.log("[perf] project index \(root.path): \(entries.count) files") }
                guard gen == self.generation else { return }
                self.entries = entries
                self.isBuilding = false
                self.onUpdate?()
                if self.pendingRebuild {
                    self.pendingRebuild = false
                    self.rebuild()
                }
            }
        }
    }

    static func enumerate(root: URL, excludes: Set<String>, limit: Int) -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        // FileManager doesn't list a folder given by a symlink, and reports paths with every
        // link resolved (/tmp as /private/tmp), so the walk starts from the real path.
        let real = root.realPathURL
        guard let en = fm.enumerator(at: URL(fileURLWithPath: real.path, isDirectory: true), includingPropertiesForKeys: keys,
                                     options: [], errorHandler: { _, _ in true }) else { return [] }
        let list = ExcludeList(excludes)
        // Standardizing also drops a leading /private, so the forms are compared as standardized paths.
        let prefixes = Set([real.standardizedFileURL.path, root.standardizedFileURL.path]).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func relative(_ url: URL) -> String? {
            let path = url.standardizedFileURL.path
            guard let p = prefixes.first(where: { path.hasPrefix($0) }), path.count > p.count else { return nil }
            return String(path.dropFirst(p.count))
        }
        var out: [String] = []
        for case let url as URL in en {
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory == true
            if list.names.contains(name) || name == ".DS_Store" {
                // skipDescendants() on a file skips the rest of its parent directory.
                if isDir { en.skipDescendants() }
                continue
            }
            if isDir {
                if list.hasPaths, let rel = relative(url), list.excludes(relativePath: rel) { en.skipDescendants() }
                continue
            }
            // Links to folders aren't followed, so a link back to a parent can't loop, and FIFOs/sockets aren't files.
            if v?.isSymbolicLink == true {
                var info = stat()
                guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            } else if v?.isRegularFile != true {
                continue
            }
            guard let rel = relative(url) else { continue }
            if list.hasPaths && list.excludes(relativePath: rel) { continue }
            out.append(rel)
            if out.count >= limit { break }
        }
        return out
    }
}

/// Names of files and folders to skip, from Settings. An entry with a slash, like
/// `vendor/bundle`, is a path: it matches that folder anywhere in the project, or only at the
/// top when it starts with a slash.
struct ExcludeList {
    let names: Set<String>
    private let anywhere: [(exact: String, prefix: String, suffix: String, inner: String)]
    private let anchored: [(exact: String, prefix: String)]
    var hasPaths: Bool { !anywhere.isEmpty || !anchored.isEmpty }

    init(_ entries: Set<String>) {
        var names = Set<String>()
        var anywhere: [(String, String, String, String)] = []
        var anchored: [(String, String)] = []
        for e in entries {
            guard e.contains("/") else { names.insert(e); continue }
            let p = e.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !p.isEmpty else { continue }
            if e.hasPrefix("/") { anchored.append((p, p + "/")) } else { anywhere.append((p, p + "/", "/" + p, "/" + p + "/")) }
        }
        self.names = names
        self.anywhere = anywhere
        self.anchored = anchored
    }

    /// Whether `rel`, a path below the project folder, is or is inside an excluded path.
    func excludes(relativePath rel: String) -> Bool {
        for p in anywhere where rel == p.exact || rel.hasPrefix(p.prefix) || rel.hasSuffix(p.suffix) || rel.contains(p.inner) { return true }
        for p in anchored where rel == p.exact || rel.hasPrefix(p.prefix) { return true }
        return false
    }
}

extension URL {
    /// The path with every symlink resolved, including /tmp as /private/tmp, which
    /// `resolvingSymlinksInPath()` leaves alone. FSEvents and FileManager report paths this way.
    var realPathURL: URL {
        guard isFileURL else { return standardizedFileURL }
        if let p = realpath(path, nil) {
            defer { free(p) }
            return URL(fileURLWithPath: String(cString: p), isDirectory: hasDirectoryPath)
        }
        var missing: [String] = []
        var dir = self
        while true {
            let name = dir.lastPathComponent
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            missing.append(name)
            if let p = realpath(parent.path, nil) {
                defer { free(p) }
                var resolved = URL(fileURLWithPath: String(cString: p), isDirectory: true)
                for part in missing.dropFirst().reversed() {
                    resolved = resolved.appendingPathComponent(part, isDirectory: true)
                }
                if let last = missing.first {
                    resolved = resolved.appendingPathComponent(last, isDirectory: hasDirectoryPath)
                }
                return resolved
            }
            dir = parent
        }
        return standardizedFileURL
    }
}
