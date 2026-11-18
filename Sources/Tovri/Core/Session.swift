import AppKit

struct TabSession: Codable {
    var path: String?
    var untitledName: String?
    var buffer: String?
    var selection: Int
    var selectionLength: Int
    var scrollX: Double
    var scrollY: Double
    var language: String?
    var encoding: String?
    var lineEnding: String?
    var isNewFile: Bool? = nil
    /// The file as it was when the backup was taken, so a file changed since then is noticed
    /// before the backup is saved over it.
    var diskStamp: DiskStamp? = nil
    /// The document and edit version the tab showed, so an older backup of the same buffer from
    /// another window never replaces newer text.
    var documentID: String? = nil
    var editVersion: Int? = nil
    /// The encoding was detected rather than chosen, so the file is detected again on restore.
    var encodingDetected: Bool? = nil
    /// Bookmarked lines, counted from 0.
    var bookmarks: [Int]? = nil

    var backupSource: Document.BackupSource? {
        if let id = documentID.flatMap(UUID.init(uuidString:)), let editVersion {
            return Document.BackupSource(id: id, version: editVersion)
        }
        return buffer.flatMap(SessionStore.backupSource(ofBufferNamed:))
    }
}

struct GroupSession: Codable {
    var tabs: [TabSession]
    var selected: Int
}

struct WindowSession: Codable {
    var frame: String
    var folder: String?
    var sidebarVisible: Bool
    var sidebarWidth: Double
    var layout: String
    var groups: [GroupSession]
    var activeGroup: Int
    var fullScreen: Bool
    /// Closed with the close button and kept only so it can be reopened.
    var closed: Bool? = nil

    /// Hot exit stores a buffer only for edits that aren't saved to disk.
    var hasUnsavedChanges: Bool { groups.contains { $0.tabs.contains { $0.buffer != nil } } }
}

struct AppSession: Codable {
    var version = 1
    var windows: [WindowSession]
}

/// Persists open windows, tabs and (with hot exit) unsaved buffers. Saves are debounced and
/// incremental: a buffer file is rewritten only when its document changed since the last write,
/// and file I/O happens off the main thread except when the app quits.
final class SessionStore {
    static let shared = SessionStore()

    /// Supplies the windows to persist; set by the app delegate.
    var stateProvider: (() -> [WindowSession])?

    private let queue = DispatchQueue(label: "app.tovri.session", qos: .utility)
    private var scheduled = false
    private struct BufferWrite {
        let documentID: UUID
        let version: Int
        let name: String
        let text: NSString
    }
    private struct WrittenBuffer {
        let version: Int
        let name: String
    }
    private let writtenLock = NSLock()
    private var writtenVersions: [UUID: WrittenBuffer] = [:]
    private var inFlightBuffers: [UUID: String] = [:]
    /// Buffer files garbage collection may delete: ones this store wrote or found in the session it
    /// loaded. Anything else, such as backups listed in an unreadable Session.json, is left alone.
    private var ownedBuffers: Set<String> = []
    private var generation = 0
    private var pendingWrites: [String: BufferWrite] = [:]
    private var allowLarge = false
    private static let largeBuffer = 4_000_000
    private var lastLargeWrite: [UUID: TimeInterval] = [:]

    lazy var directory: URL = AppRuntime.supportDirectory

    lazy var bufferDirectory: URL = {
        directory.appendingPathComponent("Buffers", isDirectory: true)
    }()

    var sessionFile: URL { directory.appendingPathComponent("Session.json") }

    func setNeedsSave() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.saveNow(synchronously: false)
        }
    }

    /// Returns the buffer file name that holds `doc`'s contents, queueing a write if it changed.
    func bufferName(for doc: Document) -> String? {
        writtenLock.lock()
        let written = writtenVersions[doc.id]
        writtenLock.unlock()
        let available = written.flatMap { buffer in
            FileManager.default.fileExists(atPath: bufferDirectory.appendingPathComponent(buffer.name).path) ? buffer : nil
        }
        if let available, available.version == doc.editVersion { return available.name }
        // A new version must not overwrite a buffer referenced by the last committed session.
        let name = "\(doc.id.uuidString)-\(doc.editVersion).txt"
        if pendingWrites[name] != nil { return name }
        writtenLock.lock()
        let sameInFlight = inFlightBuffers[doc.id] == name
        writtenLock.unlock()
        if sameInFlight { return name }
        if doc.length > SessionStore.largeBuffer && !allowLarge {
            // Copying a huge buffer stalls typing, so between quits it is backed up less often,
            // reusing the buffer currently being written on `queue` or already on disk.
            let now = Date.timeIntervalSinceReferenceDate
            let interval = max(60, Double(doc.length) / 1_000_000 * 3)
            writtenLock.lock()
            let last = lastLargeWrite[doc.id]
            let inFlight = inFlightBuffers[doc.id]
            if let last, now - last < interval {
                writtenLock.unlock()
                return inFlight ?? available?.name
            }
            lastLargeWrite[doc.id] = now
            writtenLock.unlock()
        }
        pendingWrites[name] = BufferWrite(documentID: doc.id, version: doc.editVersion, name: name,
                                          text: doc.string.copy() as! NSString)
        return name
    }

    /// Reads the document and version back out of a buffer name, for sessions saved before tabs
    /// recorded them.
    static func backupSource(ofBufferNamed name: String) -> Document.BackupSource? {
        guard name.hasSuffix(".txt"), name.count > 41 else { return nil }
        let base = name.dropLast(4)
        guard let id = UUID(uuidString: String(base.prefix(36))), base.dropFirst(36).first == "-",
              let version = Int(base.dropFirst(37)) else { return nil }
        return Document.BackupSource(id: id, version: version)
    }

    /// When "Restore windows and tabs on launch" is off while hot exit is on, keeps only tabs
    /// carrying unsaved hot-exit buffers.
    static func hotExitOnlyWindows(from windows: [WindowSession]) -> [WindowSession] {
        windows.compactMap { w in
            var copy = w
            copy.folder = nil
            var groups: [GroupSession] = []
            for g in w.groups {
                let dirtyTabs = g.tabs.filter { $0.buffer != nil }
                guard !dirtyTabs.isEmpty else { continue }
                let oldSel = (g.selected >= 0 && g.selected < g.tabs.count) ? g.tabs[g.selected] : nil
                let newSel = oldSel.flatMap { s in
                    dirtyTabs.firstIndex { $0.buffer == s.buffer && $0.path == s.path && $0.untitledName == s.untitledName }
                } ?? 0
                groups.append(GroupSession(tabs: dirtyTabs, selected: newSel))
            }
            guard !groups.isEmpty else { return nil }
            copy.groups = groups
            copy.activeGroup = min(max(0, w.activeGroup), groups.count - 1)
            if groups.count == 1 { copy.layout = LayoutMode.single.rawValue }
            return copy
        }
    }

    /// Synchronous callers must check the result before discarding any open documents.
    /// Asynchronous calls report successful scheduling; failed writes are retried on the next save.
    @discardableResult
    func saveNow(synchronously: Bool) -> Result<Void, Error> {
        let dir = bufferDirectory
        let file = sessionFile
        guard let provider = stateProvider else { return .success(()) }
        guard Settings.shared.restoreSession || Settings.shared.hotExit else {
            pendingWrites = [:]
            writtenLock.lock()
            generation += 1
            let pass = generation
            writtenLock.unlock()
            let purge = { [self] () -> Result<Void, Error> in
                let fm = FileManager.default
                try? fm.removeItem(at: file)
                let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                writtenLock.lock()
                if generation == pass {
                    for f in existing where ownedBuffers.contains(f) {
                        if (try? fm.removeItem(at: dir.appendingPathComponent(f))) != nil { ownedBuffers.remove(f) }
                    }
                    writtenVersions.removeAll()
                }
                writtenLock.unlock()
                return .success(())
            }
            if synchronously { return queue.sync(execute: purge) }
            queue.async { _ = purge() }
            return .success(())
        }
        // Reserve this pass before reading cached buffer names. An older queued save must not
        // collect files that this snapshot may still need.
        writtenLock.lock()
        generation += 1
        let pass = generation
        writtenLock.unlock()
        allowLarge = synchronously
        var windows = provider()
        allowLarge = false
        if !Settings.shared.restoreSession && Settings.shared.hotExit {
            windows = SessionStore.hotExitOnlyWindows(from: windows)
        }
        let fm = FileManager.default
        let pendingNames = Set(pendingWrites.keys)
        writtenLock.lock()
        let inFlightNames = Set(inFlightBuffers.values)
        writtenLock.unlock()
        for wi in windows.indices where windows[wi].closed == true {
            for gi in windows[wi].groups.indices {
                for ti in windows[wi].groups[gi].tabs.indices {
                    if let buf = windows[wi].groups[gi].tabs[ti].buffer,
                       !pendingNames.contains(buf),
                       !inFlightNames.contains(buf),
                       !fm.fileExists(atPath: dir.appendingPathComponent(buf).path) {
                        windows[wi].groups[gi].tabs[ti].buffer = nil
                    }
                }
            }
        }
        let session = AppSession(windows: windows)
        let data: Data
        do { data = try JSONEncoder().encode(session) } catch { return .failure(error) }
        let keep = Set(session.windows.flatMap { w in w.groups.flatMap { g in g.tabs.compactMap { $0.buffer } } })
        let writes = pendingWrites.values.filter { keep.contains($0.name) }
        pendingWrites = [:]
        writtenLock.lock()
        for write in writes { inFlightBuffers[write.documentID] = write.name }
        writtenLock.unlock()
        let work = { [self] () -> Result<Void, Error> in
            let result = Result {
                let fm = FileManager.default
                // Unsaved buffers can hold secrets, so only this user may read them.
                let privateFolder: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: privateFolder)
                for folder in [dir, file.deletingLastPathComponent()] { try? fm.setAttributes(privateFolder, ofItemAtPath: folder.path) }
                for write in writes {
                    let url = dir.appendingPathComponent(write.name)
                    try (write.text as String).write(to: url, atomically: true, encoding: .utf8)
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    writtenLock.lock()
                    writtenVersions[write.documentID] = WrittenBuffer(version: write.version, name: write.name)
                    if inFlightBuffers[write.documentID] == write.name { inFlightBuffers.removeValue(forKey: write.documentID) }
                    ownedBuffers.insert(write.name)
                    writtenLock.unlock()
                }
                // Closed-window snapshots can reference buffers without queueing new writes.
                for name in keep {
                    let buffer = dir.appendingPathComponent(name)
                    guard fm.fileExists(atPath: buffer.path) else {
                        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: buffer.path])
                    }
                }
                try data.write(to: file, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                // Garbage collection is safe only after the manifest and all its buffers exist.
                let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                writtenLock.lock()
                if generation == pass {
                    for f in existing where !keep.contains(f) && ownedBuffers.contains(f) {
                        if (try? fm.removeItem(at: dir.appendingPathComponent(f))) != nil { ownedBuffers.remove(f) }
                    }
                    writtenVersions = writtenVersions.filter { keep.contains($0.value.name) }
                }
                writtenLock.unlock()
            }
            if case .failure = result {
                writtenLock.lock()
                for write in writes {
                    if inFlightBuffers[write.documentID] == write.name { inFlightBuffers.removeValue(forKey: write.documentID) }
                    lastLargeWrite.removeValue(forKey: write.documentID)
                }
                writtenLock.unlock()
            }
            return result
        }
        if synchronously { return queue.sync(execute: work) }
        queue.async { _ = work() }
        return .success(())
    }

    func load() -> AppSession? {
        guard let data = try? Data(contentsOf: sessionFile),
              let session = try? JSONDecoder().decode(AppSession.self, from: data) else { return nil }
        writtenLock.lock()
        ownedBuffers.formUnion(session.windows.flatMap { w in w.groups.flatMap { g in g.tabs.compactMap { $0.buffer } } })
        writtenLock.unlock()
        return session
    }
}
