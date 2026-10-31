import AppKit
import Quartz
import UniformTypeIdentifiers

/// Images, PDFs, media and office documents open in Quick Look instead of as text.
extension MainWindowController: QLPreviewPanelDataSource {
    static func prefersQuickLook(_ url: URL) -> Bool {
        // Source files can share extensions with media types (.ts is also MPEG transport stream).
        if LanguageRegistry.shared.language(forFileName: url.lastPathComponent) !== LanguageRegistry.shared.plain { return false }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        if type.conforms(to: .svg) || type.conforms(to: .text) { return false }
        let kinds: [UTType] = [.image, .pdf, .audiovisualContent, .font, .spreadsheet, .presentation, .archive, .diskImage]
        // .key is also the usual name for a PEM private key; only a zipped Keynote file previews.
        if ext == "key" { return isZipOrPackage(url) }
        if kinds.contains(where: { type.conforms(to: $0) }) { return true }
        return ["doc", "docx", "pages", "numbers", "epub"].contains(ext)
    }

    private static func isZipOrPackage(_ url: URL) -> Bool {
        if NSWorkspace.shared.isFilePackage(atPath: url.path) { return true }
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    func quickLook(_ url: URL) {
        quickLookItems = [url]
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.updateController()
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !quickLookItems.isEmpty }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookItems[index] as NSURL
    }
}
