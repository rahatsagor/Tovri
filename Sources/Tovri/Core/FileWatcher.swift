import Foundation
import CoreServices

/// Recursive FSEvents watcher delivering changed directory paths on the main queue.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let callback: ([String]) -> Void

    init?(path: String, latency: TimeInterval = 0.3, callback: @escaping ([String]) -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var result: [String] = []
            result.reserveCapacity(count)
            for i in 0..<count { if let s = array[i] as? String { result.append(s) } }
            watcher.callback(result)
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &context, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
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
                if Perf.enabled { FileHandle.standardError.write("[perf] project index \(root.path): \(entries.count) files\n".data(using: .utf8)!) }
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
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return [] }
        let rootPath = root.standardizedFileURL.path
        let prefixLen = rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1
        var out: [String] = []
        for case let url as URL in en {
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory == true
            if excludes.contains(name) || name == ".DS_Store" {
                // skipDescendants() on a file skips the rest of its parent directory.
                if isDir { en.skipDescendants() }
                continue
            }
            if isDir { continue }
            let path = url.standardizedFileURL.path
            guard path.count > prefixLen else { continue }
            out.append(String(path.dropFirst(prefixLen)))
            if out.count >= limit { break }
        }
        return out
    }
}
