import Foundation

/// Definitions (functions, types, …) found in every source file of a project. Nothing is built
/// until the first Goto Symbol in Project or Goto Definition; later refreshes only rescan files
/// whose size or modification date changed.
final class ProjectSymbolIndex {
    struct Symbol {
        let name: String
        let units: [UInt16]
        let path: String  // relative to root
        let line: Int     // 0-based
        let column: Int   // 0-based, UTF-16
    }

    private struct FileSymbols {
        let stamp: Stamp
        let symbols: [(name: String, line: Int, column: Int)]
    }

    private struct Stamp: Equatable {
        let size: Int64
        let mtime: Int
    }

    let root: URL
    private(set) var symbols: [Symbol] = []
    private(set) var isReady = false
    private var isBuilding = false
    private var queuedFiles: [String]?
    private var waiters: [() -> Void] = []
    /// Only touched on `queue`.
    private var cache: [String: FileSymbols] = [:]
    private let queue = DispatchQueue(label: "app.tovri.project-symbols", qos: .userInitiated)

    static let maxFileSize: Int64 = 1_000_000
    static let maxFiles = 40_000
    static let maxSymbols = 400_000

    init(root: URL) { self.root = root }

    /// Brings the index up to date with `files`; `completion` runs on the main thread afterwards.
    func refresh(files: [String], completion: (() -> Void)? = nil) {
        if let completion { waiters.append(completion) }
        if isBuilding { queuedFiles = files; return }
        isBuilding = true
        let regexes = ProjectSymbolIndex.symbolRegexes()
        let root = self.root
        let t0 = CFAbsoluteTimeGetCurrent()
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.scan(files: files, root: root, regexes: regexes)
            DispatchQueue.main.async {
                if Perf.enabled {
                    FileHandle.standardError.write("[perf] project symbols: \(result.count) in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms\n".data(using: .utf8)!)
                }
                self.symbols = result
                self.isReady = true
                self.isBuilding = false
                if let next = self.queuedFiles {
                    self.queuedFiles = nil
                    self.refresh(files: next)
                    return
                }
                let w = self.waiters
                self.waiters = []
                w.forEach { $0() }
            }
        }
    }

    /// `Language.symbolRegex` is lazy and not thread-safe, so regexes are resolved on the main thread.
    private static var regexCache: [String: NSRegularExpression]?
    private static func symbolRegexes() -> [String: NSRegularExpression] {
        if let c = regexCache { return c }
        var out: [String: NSRegularExpression] = [:]
        for lang in LanguageRegistry.shared.all where lang.style == .code {
            if let re = lang.symbolRegex { out[lang.id] = re }
        }
        regexCache = out
        return out
    }

    private func scan(files: [String], root: URL, regexes: [String: NSRegularExpression]) -> [Symbol] {
        let registry = LanguageRegistry.shared
        var work: [(path: String, regex: NSRegularExpression)] = []
        for rel in files {
            let lang = registry.language(forFileName: (rel as NSString).lastPathComponent)
            guard let re = regexes[lang.id] else { continue }
            work.append((rel, re))
            if work.count >= ProjectSymbolIndex.maxFiles { break }
        }
        let old = cache
        var results = [FileSymbols?](repeating: nil, count: work.count)
        let rootPath = root.path
        results.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: work.count) { i in
                let item = work[i]
                let full = rootPath + "/" + item.path
                var st = stat()
                guard stat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= ProjectSymbolIndex.maxFileSize else { return }
                let stamp = Stamp(size: Int64(st.st_size), mtime: Int(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int(st.st_mtimespec.tv_nsec))
                if let cached = old[item.path], cached.stamp == stamp { buf[i] = cached; return }
                guard let data = FileManager.default.contents(atPath: full) else { return }
                if data.prefix(4096).contains(0) { buf[i] = FileSymbols(stamp: stamp, symbols: []); return }
                guard let text = NSString(data: data, encoding: NSUTF8StringEncoding) ?? NSString(data: data, encoding: NSISOLatin1StringEncoding) else { return }
                buf[i] = FileSymbols(stamp: stamp, symbols: ProjectSymbolIndex.extract(text, item.regex))
            }
        }
        var newCache: [String: FileSymbols] = [:]
        newCache.reserveCapacity(work.count)
        var out: [Symbol] = []
        for (i, r) in results.enumerated() {
            guard let r else { continue }
            let path = work[i].path
            newCache[path] = r
            for s in r.symbols where out.count < ProjectSymbolIndex.maxSymbols {
                out.append(Symbol(name: s.name, units: Array(s.name.utf16), path: path, line: s.line, column: s.column))
            }
        }
        cache = newCache
        return out
    }

    static func extract(_ ns: NSString, _ re: NSRegularExpression) -> [(name: String, line: Int, column: Int)] {
        let text = ns as String
        var out: [(String, Int, Int)] = []
        var line = 0
        var lineStart = 0
        var scanned = 0
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m, m.numberOfRanges > 1 else { return }
            let r = m.range(at: 1)
            guard r.location != NSNotFound, r.length > 0 else { return }
            while scanned < r.location {
                if ns.character(at: scanned) == 10 { line += 1; lineStart = scanned + 1 }
                scanned += 1
            }
            let name = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out.append((name, line, r.location - lineStart)) }
            if out.count > 5_000 { stop.pointee = true }
        }
        return out
    }
}

/// A definition from the project index or from an open document.
struct WorkspaceSymbol {
    enum Target {
        case document(Document, NSRange)
        case file(root: URL, relativePath: String)
    }

    let name: String
    let units: [UInt16]
    let target: Target
    let line: Int    // 0-based
    let column: Int  // 0-based, UTF-16
    let displayPath: String

    func isDefinition(in doc: Document, at range: NSRange) -> Bool {
        switch target {
        case .document(let d, let r):
            return d === doc && NSLocationInRange(range.location, NSRange(location: r.location, length: r.length + 1))
        case .file(let root, let rel):
            guard doc.url?.standardizedFileURL.path == root.appendingPathComponent(rel).standardizedFileURL.path else { return false }
            let line = doc.lines.line(containing: range.location)
            let col = range.location - doc.lines.start(of: line)
            return line == self.line && col >= column && col <= column + units.count
        }
    }

    func belongs(to doc: Document) -> Bool {
        switch target {
        case .document(let d, _): return d === doc
        case .file(let root, let rel): return doc.url?.standardizedFileURL.path == root.appendingPathComponent(rel).standardizedFileURL.path
        }
    }
}
