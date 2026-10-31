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
    /// Buffer files garbage collection may delete: ones this store wrote or found in the session it
    /// loaded. Anything else, such as backups listed in an unreadable Session.json, is left alone.
    private var ownedBuffers: Set<String> = []
    private var generation = 0
    private var pendingWrites: [String: BufferWrite] = [:]
    private var allowLarge = false
    private static let largeBuffer = 4_000_000

    lazy var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tovri", isDirectory: true)
    }()

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
        if doc.length > SessionStore.largeBuffer && !allowLarge { return available?.name }
        // A new version must not overwrite a buffer referenced by the last committed session.
        let name = "\(doc.id.uuidString)-\(doc.editVersion).txt"
        if pendingWrites[name] == nil {
            pendingWrites[name] = BufferWrite(documentID: doc.id, version: doc.editVersion, name: name,
                                              text: doc.string.copy() as! NSString)
        }
        return name
    }

    /// Synchronous callers must check the result before discarding any open documents.
    /// Asynchronous calls report successful scheduling; failed writes are retried on the next save.
    @discardableResult
    func saveNow(synchronously: Bool) -> Result<Void, Error> {
        guard let provider = stateProvider, Settings.shared.restoreSession || Settings.shared.hotExit else { return .success(()) }
        // Reserve this pass before reading cached buffer names. An older queued save must not
        // collect files that this snapshot may still need.
        writtenLock.lock()
        generation += 1
        let pass = generation
        writtenLock.unlock()
        allowLarge = synchronously
        let session = AppSession(windows: provider())
        allowLarge = false
        let data: Data
        do { data = try JSONEncoder().encode(session) } catch { return .failure(error) }
        let keep = Set(session.windows.flatMap { w in w.groups.flatMap { g in g.tabs.compactMap { $0.buffer } } })
        let writes = pendingWrites.values.filter { keep.contains($0.name) }
        pendingWrites = [:]
        let dir = bufferDirectory
        let file = sessionFile
        let work = { [self] () -> Result<Void, Error> in
            Result {
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
