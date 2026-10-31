import Foundation

/// Tracks documents opened by \`tovri --wait\`. The CLI blocks until its marker file is removed,
/// which happens when the last tab showing the document closes or the app quits.
final class WaitRegistry {
    static let shared = WaitRegistry()
    private var markers: [ObjectIdentifier: [String]] = [:]

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tovri/Wait", isDirectory: true)
    }

    func register(_ id: String, for doc: Document) {
        guard UUID(uuidString: id) != nil else { return }
        markers[ObjectIdentifier(doc), default: []].append(id)
    }

    /// Call after a tab closes; releases waiters if no tab in any window still shows the document.
    func documentMayHaveClosed(_ doc: Document, stillOpen: Bool) {
        guard !stillOpen, let ids = markers.removeValue(forKey: ObjectIdentifier(doc)) else { return }
        for id in ids { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id)) }
    }

    func release(_ id: String) {
        guard UUID(uuidString: id) != nil else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id))
    }

    func releaseAll() {
        for ids in markers.values {
            for id in ids { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id)) }
        }
        markers.removeAll()
    }
}
