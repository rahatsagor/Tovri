import Foundation

/// Tracks documents opened by \`tovri --wait\`. The CLI blocks until its marker file is removed,
/// which happens when the last tab showing the document closes or the app quits.
final class WaitRegistry {
    static let shared = WaitRegistry()
    private let lock = NSLock()
    private var markers: [ObjectIdentifier: [String]] = [:]

    private var directory: URL {
        AppRuntime.supportDirectory.appendingPathComponent("Wait", isDirectory: true)
    }

    func register(_ id: String, for doc: Document) {
        guard UUID(uuidString: id) != nil else { return }
        lock.lock()
        markers[ObjectIdentifier(doc), default: []].append(id)
        lock.unlock()
    }

    func isWaiting(on doc: Document) -> Bool {
        lock.lock()
        let waiting = !(markers[ObjectIdentifier(doc)]?.isEmpty ?? true)
        lock.unlock()
        return waiting
    }

    /// Call after a tab closes; releases waiters if no tab in any window still shows the document.
    func documentMayHaveClosed(_ doc: Document, stillOpen: Bool) {
        guard !stillOpen else { return }
        lock.lock()
        let ids = markers.removeValue(forKey: ObjectIdentifier(doc))
        lock.unlock()
        guard let ids else { return }
        for id in ids { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id)) }
    }

    func release(_ id: String) {
        guard UUID(uuidString: id) != nil else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id))
    }

    func releaseAll() {
        lock.lock()
        let all = markers.values
        markers.removeAll()
        lock.unlock()
        for ids in all {
            for id in ids { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id)) }
        }
    }
}
