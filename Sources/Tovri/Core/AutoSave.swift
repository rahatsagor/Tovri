import AppKit

/// Saves edited files once typing pauses for the delay chosen in Settings → Files. Only files
/// already on disk are saved, through the same non-interactive save as saving on focus loss.
final class AutoSave {
    static let shared = AutoSave()

    /// Saves a document; set by the app delegate. Without it nothing is scheduled.
    var save: ((Document) -> Void)?
    /// Replaces the delay from Settings, in seconds.
    var delayOverride: TimeInterval?

    private var lastEdit: [ObjectIdentifier: TimeInterval] = [:]
    private var waiting: Set<ObjectIdentifier> = []

    var delay: TimeInterval { delayOverride ?? TimeInterval(Settings.shared.autoSaveDelay) }

    static func canSave(_ doc: Document) -> Bool {
        guard doc.isDirty, let url = doc.url, !doc.isNewFile, !doc.isReadOnly, !doc.isTransient, !doc.fileMissing else { return false }
        // A file deleted on disk would be created again.
        return DiskStamp(url) != nil
    }

    func documentDidEdit(_ doc: Document) {
        let d = delay
        guard d > 0, save != nil, doc.url != nil, !doc.isNewFile, !doc.isReadOnly, !doc.isTransient else { return }
        let id = ObjectIdentifier(doc)
        lastEdit[id] = Date.timeIntervalSinceReferenceDate
        // One timer per document; it waits again while typing continues instead of being replaced on every key.
        guard waiting.insert(id).inserted else { return }
        schedule(doc, id: id, after: d)
    }

    private func schedule(_ doc: Document, id: ObjectIdentifier, after interval: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self, weak doc] in
            guard let self else { return }
            guard let doc else {
                self.waiting.remove(id)
                self.lastEdit[id] = nil
                return
            }
            let d = self.delay
            let idle = Date.timeIntervalSinceReferenceDate - (self.lastEdit[id] ?? 0)
            if d > 0 && idle < d - 0.005 {
                self.schedule(doc, id: id, after: d - idle)
                return
            }
            if AutoSave.isComposing(doc) {
                self.schedule(doc, id: id, after: max(d, 0.5))
                return
            }
            self.waiting.remove(id)
            self.lastEdit[id] = nil
            guard d > 0, AutoSave.canSave(doc) else { return }
            self.save?(doc)
        }
    }

    /// Saving mid-composition (Japanese, Chinese, accents) would write unfinished text.
    private static func isComposing(_ doc: Document) -> Bool {
        guard let tv = NSApp?.keyWindow?.firstResponder as? NSTextView, tv.textStorage === doc.textStorage else { return false }
        return tv.hasMarkedText()
    }
}
