import AppKit

/// The page a commit tab shows in Overview mode: a card with the commit's author, message and
/// parents, then the changed files. One virtualized table, so a commit with a thousand files scrolls
/// as smoothly as one with five.
final class CommitOverviewView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Row { case card, filesHeader, file(Int), more }

    let model: CommitOverviewModel
    /// A file or the commit was acted on (open changes, open the file, compare).
    var onAction: ((HistoryAction) -> Void)?
    /// A file was chosen: show its section of the patch.
    var onShowPatch: ((Int) -> Void)?
    var onOpenParent: ((String) -> Void)?

    private let scroll = OverlayScrollView(frame: .zero)
    let table = OverviewTableView()
    private(set) var rows: [Row] = []
    private var columnWidth: CGFloat = 0
    private var cardHeights: (width: CGFloat, height: CGFloat)?

    static let maxContentWidth: CGFloat = 900
    static let fileRowHeight: CGFloat = 28

    /// The centered column inside a table `width` wide.
    static func column(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let pad: CGFloat = width < 560 ? 16 : 28
        let w = max(0, min(maxContentWidth, width - 2 * pad))
        return (floor((width - w) / 2), w)
    }

    override var isFlipped: Bool { true }

    init(model: CommitOverviewModel) {
        self.model = model
        super.init(frame: .zero)
        rows = [.card, .filesHeader] + model.detail.files.indices.map { Row.file($0) } + (model.detail.hiddenFileCount > 0 ? [.more] : [])
        let col = NSTableColumn(identifier: .init("overview"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.style = .plain
        table.focusRingType = .none
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)
        table.onReturn = { [weak self] option in
            guard let self, let i = self.selectedFileIndex else { return }
            if option { self.openChanges(i, pinned: false) } else { self.onShowPatch?(i) }
        }
        table.menuProvider = { [weak self] row in self?.menu(row: row) }
        table.onHoverChange = { [weak self] in self?.updateButtons() }
        table.setAccessibilityLabel("Changed files")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        addSubview(scroll)
        setAccessibilityElement(false)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Public

    func focus() { window?.makeFirstResponder(table) }

    var selectedFileIndex: Int? {
        let r = table.selectedRow
        guard r >= 0, r < rows.count, case .file(let i) = rows[r] else { return nil }
        return i
    }

    func selectFile(_ index: Int) {
        guard let r = rows.firstIndex(where: { if case .file(index) = $0 { return true } else { return false } }) else { return }
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    func applyTheme() {
        let theme = ThemeManager.shared.active
        scroll.backgroundColor = theme.editorBackground
        scroll.drawsBackground = !theme.translucent
        scroll.appearance = theme.appearance
        table.backgroundColor = theme.translucent ? .clear : theme.editorBackground
        cardHeights = nil
        reload()
    }

    private func reload() {
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0, selected < rows.count { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = scroll.contentSize.width
        table.tableColumns.first?.width = width
        if abs(width - columnWidth) > 0.5 {
            columnWidth = width
            cardHeights = nil
            reload()
        }
    }

    // MARK: Actions

    private func openChanges(_ index: Int, pinned: Bool) {
        guard index < model.detail.files.count else { return }
        onAction?(.openFile(model.detail.files[index], .changes, pinned: pinned))
    }

    private func clickedFileIndex() -> Int? {
        let r = table.clickedRow
        guard r >= 0, r < rows.count, case .file(let i) = rows[r] else { return nil }
        return i
    }

    @objc private func clicked() {
        guard NSApp.currentEvent?.clickCount != 2, let i = clickedFileIndex() else { return }
        onShowPatch?(i)
    }

    @objc private func doubleClicked() {
        guard let i = clickedFileIndex() else { return }
        openChanges(i, pinned: false)
    }

    private func updateButtons() {
        table.enumerateAvailableRowViews { rowView, row in
            for case let cell as CommitFileCell in rowView.subviews {
                cell.setActive(row == table.hoverRow || row == table.selectedRow)
            }
            (rowView as? OverviewRowView)?.hovered = row == table.hoverRow
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: Menu

    private func menu(row: Int) -> NSMenu? {
        guard row >= 0, row < rows.count, case .file(let i) = rows[row] else { return nil }
        let file = model.detail.files[i]
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let inWorkTree = FileManager.default.fileExists(atPath: model.repoRoot.appendingPathComponent(file.path).path)
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, enabled: Bool = true) {
            let item = m.addItem(withTitle: title, action: enabled ? sel : nil, keyEquivalent: "")
            item.target = self
            item.tag = i
        }
        add("Open Changes", #selector(menuOpenChanges(_:)))
        add("Open Changes in New Tab", #selector(menuOpenChangesPinned(_:)))
        add("Open File at This Commit", #selector(menuOpenFile(_:)), enabled: file.status != .deleted)
        add("Compare with Current File", #selector(menuCompare(_:)), enabled: inWorkTree)
        m.addItem(.separator())
        add("Copy Path", #selector(menuCopyPath(_:)))
        return m
    }

    @objc private func menuOpenChanges(_ sender: NSMenuItem) { openChanges(sender.tag, pinned: false) }
    @objc private func menuOpenChangesPinned(_ sender: NSMenuItem) { openChanges(sender.tag, pinned: true) }
    @objc private func menuOpenFile(_ sender: NSMenuItem) { onAction?(.openFile(model.detail.files[sender.tag], .file, pinned: true)) }
    @objc private func menuCompare(_ sender: NSMenuItem) { onAction?(.compareWithCurrent(model.detail.files[sender.tag])) }
    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        AppRuntime.pasteboard.clearContents()
        AppRuntime.pasteboard.setString(model.detail.files[sender.tag].path, forType: .string)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    private func cardHeight(width: CGFloat) -> CGFloat {
        let col = CommitOverviewView.column(in: width)
        if let c = cardHeights, c.width == col.width { return c.height }
        let h = CommitCardCell.layout(for: model, width: col.width).total
        cardHeights = (col.width, h)
        return h
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .card: return cardHeight(width: columnWidth) + 36
        case .filesHeader: return 40
        case .file: return CommitOverviewView.fileRowHeight
        case .more: return 36
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .file = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("overviewRow")
        let view = (tableView.makeView(withIdentifier: id, owner: nil) as? OverviewRowView) ?? OverviewRowView()
        view.identifier = id
        view.column = CommitOverviewView.column(in: columnWidth)
        view.hovered = row == table.hoverRow
        view.isFileRow = { if case .file = rows[row] { return true } else { return false } }()
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let col = CommitOverviewView.column(in: columnWidth)
        switch rows[row] {
        case .card:
            let id = NSUserInterfaceItemIdentifier("overviewCard")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitCardCell) ?? CommitCardCell()
            cell.identifier = id
            cell.onOpenParent = { [weak self] sha in self?.onOpenParent?(sha) }
            cell.configure(model, column: col)
            return cell
        case .filesHeader:
            let id = NSUserInterfaceItemIdentifier("overviewHeader")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitFilesHeaderCell) ?? CommitFilesHeaderCell()
            cell.identifier = id
            cell.configure(model.detail, column: col)
            return cell
        case .file(let i):
            let id = NSUserInterfaceItemIdentifier("overviewFile")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CommitFileCell) ?? CommitFileCell()
            cell.identifier = id
            cell.leadingInset = col.x
            cell.trailingInset = columnWidth - (col.x + col.width) + 28
            cell.configure(model.detail.files[i].changedFile)
            cell.onOpen = { [weak self] in self?.openChanges(i, pinned: false) }
            cell.setActive(row == table.hoverRow || row == table.selectedRow)
            return cell
        case .more:
            let id = NSUserInterfaceItemIdentifier("overviewMore")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? HistoryInfoCell) ?? HistoryInfoCell()
            cell.identifier = id
            cell.configure("\(model.detail.hiddenFileCount) more files. Switch to Patch to see them all.", left: col.x + 12)
            return cell
        }
    }
}

// MARK: - Table and rows

final class OverviewTableView: NSTableView {
    var onReturn: ((_ option: Bool) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?
    var onHoverChange: (() -> Void)?
    private(set) var hoverRow = -1
    private var ownTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = ownTrackingArea { removeTrackingArea(a) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        ownTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { setHover(row(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHover(-1) }

    private func setHover(_ r: Int) {
        guard r != hoverRow else { return }
        hoverRow = r
        onHoverChange?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?(event.modifierFlags.contains(.option))
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(row(at: convert(event.locationInWindow, from: nil))) }

    /// Lets a click place the caret in, or select text from, the card's labels instead of the table taking it.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField, field.isSelectable { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

/// Draws hover and selection only across the centered column.
final class OverviewRowView: ThemedRowView {
    var column: (x: CGFloat, width: CGFloat) = (0, 0) { didSet { needsDisplay = true } }
    var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    var isFileRow = false

    private var columnRect: NSRect { NSRect(x: column.x, y: 1, width: column.width, height: max(0, bounds.height - 2)) }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovered, isFileRow, !isSelected else { return }
        ThemeManager.shared.active.tabHoverBackground.setFill()
        NSBezierPath(roundedRect: columnRect, xRadius: 5, yRadius: 5).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isFileRow else { return }
        selectionColor.setFill()
        NSBezierPath(roundedRect: columnRect, xRadius: 5, yRadius: 5).fill()
    }
}

/// A changed file, with a button to open its changes while the pointer is over it or it is selected.
final class CommitFileCell: ChangeCell {
    let openButton = ToolButton(symbol: "plus.forwardslash.minus", tooltip: "Open Changes")
    var onOpen: (() -> Void)?

    override init() {
        super.init()
        openButton.symbolSize = 11
        openButton.isHidden = true
        openButton.onClick = { [weak self] in self?.onOpen?() }
        addSubview(openButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ on: Bool) { openButton.isHidden = !on }

    override func layout() {
        super.layout()
        // `trailingInset` keeps 28 points past the column for this button.
        openButton.frame = NSRect(x: bounds.width - trailingInset + 28 - 32, y: (bounds.height - 22) / 2, width: 22, height: 22)
    }
}

/// "CHANGED FILES  5" with the totals at the right.
final class CommitFilesHeaderCell: NSTableCellView {
    private var detail: GitRepository.CommitDetail?
    private var column: (x: CGFloat, width: CGFloat) = (0, 0)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ detail: GitRepository.CommitDetail, column: (x: CGFloat, width: CGFloat)) {
        self.detail = detail
        self.column = column
        let total = detail.files.count + detail.hiddenFileCount
        setAccessibilityLabel("Changed files, \(total)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let detail else { return }
        let theme = ThemeManager.shared.active
        let total = detail.files.count + detail.hiddenFileCount
        let text = NSMutableAttributedString(string: "CHANGED FILES", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: theme.chromeSecondary])
        text.append(NSAttributedString(string: "  \(total)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: theme.chromeSecondary.withAlphaComponent(0.8)]))
        let y = bounds.height - 22
        text.draw(at: NSPoint(x: column.x + 12, y: y))
        let added = detail.files.reduce(0) { $0 + ($1.added ?? 0) }
        let removed = detail.files.reduce(0) { $0 + ($1.removed ?? 0) }
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        let totals = NSMutableAttributedString(string: "+\(added)", attributes: [.font: digits, .foregroundColor: theme.color(.inserted) ?? .systemGreen])
        totals.append(NSAttributedString(string: " −\(removed)", attributes: [.font: digits, .foregroundColor: theme.color(.deleted) ?? .systemRed]))
        totals.draw(at: NSPoint(x: column.x + column.width - 12 - ceil(totals.size().width), y: y - 1))
    }
}

// MARK: - The card

final class CommitCardCell: NSTableCellView {
    struct Layout {
        var badgesY: CGFloat?
        var subjectY: CGFloat
        var subjectHeight: CGFloat
        var bodyY: CGFloat?
        var bodyHeight: CGFloat
        var parentsY: CGFloat?
        var committerY: CGFloat?
        var total: CGFloat
    }

    static let padding: CGFloat = 18
    static let subjectFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 13)

    var onOpenParent: ((String) -> Void)?
    private var model: CommitOverviewModel?
    private var column: (x: CGFloat, width: CGFloat) = (0, 0)
    private let avatar = AvatarView()
    private let name = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let pill = ShaPillView()
    private let copyButton = ToolButton(symbol: "doc.on.doc", tooltip: "Copy commit SHA")
    private let badges = RefBadgesView()
    private let subject = NSTextField(wrappingLabelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let parents = ParentsView()
    private let committer = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        meta.font = .systemFont(ofSize: 12)
        meta.lineBreakMode = .byTruncatingTail
        committer.font = .systemFont(ofSize: 12)
        for f in [subject, body] {
            f.isSelectable = true
            f.allowsEditingTextAttributes = false
        }
        subject.font = CommitCardCell.subjectFont
        body.font = CommitCardCell.bodyFont
        copyButton.symbolSize = 11.5
        copyButton.onClick = { [weak self] in
            guard let sha = self?.model?.commit.sha else { return }
            AppRuntime.pasteboard.clearContents()
            AppRuntime.pasteboard.setString(sha, forType: .string)
            (self?.window?.windowController as? MainWindowController)?.statusBar.flash("Copied \(self?.model?.commit.shortSHA ?? "")")
        }
        parents.onOpen = { [weak self] sha in self?.onOpenParent?(sha) }
        [avatar, name, meta, pill, copyButton, badges, subject, body, parents, committer].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// What follows the first paragraph of a commit message.
    static func messageBody(_ detail: GitRepository.CommitDetail) -> String {
        guard let r = detail.message.range(of: "\n\n") else { return "" }
        return String(detail.message[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func subjectText(_ commit: LogCommit) -> String { commit.subject.isEmpty ? "(no message)" : commit.subject }

    static func hasCommitterLine(_ detail: GitRepository.CommitDetail) -> Bool {
        detail.committerName != detail.authorName || abs(detail.commitDate.timeIntervalSince(detail.authorDate)) > 60
    }

    private static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin], attributes: [.font: font]).height)
    }

    /// Where each part sits in a card `width` wide; the same numbers give the row its height.
    static func layout(for model: CommitOverviewModel, width: CGFloat) -> Layout {
        let pad = padding
        let inner = max(0, width - 2 * pad)
        var y = pad + 40
        var badgesY: CGFloat?
        if !model.commit.refs.isEmpty {
            y += 12
            badgesY = y
            y += 16
        }
        y += 14
        let subjectY = y
        let subjectH = max(22, height(of: subjectText(model.commit), font: subjectFont, width: inner - 4) + 2)
        y += subjectH
        var bodyY: CGFloat?
        var bodyH: CGFloat = 0
        let bodyText = messageBody(model.detail)
        if !bodyText.isEmpty {
            y += 10
            bodyY = y
            bodyH = height(of: bodyText, font: bodyFont, width: inner - 4) + 2
            y += bodyH
        }
        var parentsY: CGFloat?
        if !model.commit.parents.isEmpty {
            y += 16
            parentsY = y
            y += 16
        }
        var committerY: CGFloat?
        if hasCommitterLine(model.detail) {
            y += parentsY == nil ? 16 : 4
            committerY = y
            y += 16
        }
        return Layout(badgesY: badgesY, subjectY: subjectY, subjectHeight: subjectH, bodyY: bodyY, bodyHeight: bodyH,
                      parentsY: parentsY, committerY: committerY, total: y + pad)
    }

    func configure(_ model: CommitOverviewModel, column: (x: CGFloat, width: CGFloat)) {
        self.model = model
        self.column = column
        let theme = ThemeManager.shared.active
        let d = model.detail
        avatar.configure(name: d.authorName, email: d.authorEmail, palette: HistoryStyle.palette(for: theme))
        name.stringValue = d.authorName.isEmpty ? d.authorEmail : d.authorName
        name.textColor = theme.chromeForeground
        let when = "\(HistoryView.absoluteDate(d.authorDate)) · \(HistoryView.relativeDate(d.authorDate))"
        meta.stringValue = d.authorEmail.isEmpty ? when : "\(d.authorEmail) · \(when)"
        meta.textColor = theme.chromeSecondary
        pill.sha = model.commit.shortSHA
        badges.refs = model.commit.refs
        badges.isHidden = model.commit.refs.isEmpty
        subject.stringValue = CommitCardCell.subjectText(model.commit)
        subject.textColor = theme.chromeForeground
        let bodyText = CommitCardCell.messageBody(d)
        body.stringValue = bodyText
        body.isHidden = bodyText.isEmpty
        body.textColor = theme.chromeForeground.withAlphaComponent(0.85)
        parents.configure(parents: model.commit.parents)
        parents.isHidden = model.commit.parents.isEmpty
        let committed = CommitCardCell.hasCommitterLine(d)
        committer.isHidden = !committed
        committer.stringValue = "Committed by \(d.committerName) · \(HistoryView.absoluteDate(d.commitDate))"
        committer.textColor = theme.chromeSecondary
        setAccessibilityLabel("\(CommitCardCell.subjectText(model.commit)), \(d.authorName), \(HistoryView.absoluteDate(d.authorDate)), commit \(model.commit.shortSHA)")
        needsLayout = true
        needsDisplay = true
    }

    private var cardRect: NSRect { NSRect(x: column.x, y: 20, width: column.width, height: max(0, bounds.height - 36)) }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        let path = NSBezierPath(roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        theme.chromeBackground.setFill()
        path.fill()
        theme.chromeBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        guard let model else { return }
        let card = cardRect
        let pad = CommitCardCell.padding
        let l = CommitCardCell.layout(for: model, width: card.width)
        let x = card.minX + pad
        let inner = max(0, card.width - 2 * pad)
        let top = card.minY
        avatar.frame = NSRect(x: x, y: top + pad, width: 40, height: 40)
        copyButton.frame = NSRect(x: card.maxX - pad - 22, y: top + pad - 1, width: 22, height: 22)
        let pillWidth = pill.preferredWidth
        pill.frame = NSRect(x: copyButton.frame.minX - 6 - pillWidth, y: top + pad, width: pillWidth, height: 20)
        let textX = x + 40 + 12
        let textRight = pill.frame.minX - 10
        name.frame = NSRect(x: textX, y: top + pad + 1, width: max(0, textRight - textX), height: 18)
        meta.frame = NSRect(x: textX, y: top + pad + 22, width: max(0, card.maxX - pad - textX), height: 16)
        if let y = l.badgesY { badges.frame = NSRect(x: x, y: top + y, width: inner, height: 16) }
        subject.frame = NSRect(x: x - 2, y: top + l.subjectY, width: inner + 4, height: l.subjectHeight)
        if let y = l.bodyY { body.frame = NSRect(x: x - 2, y: top + y, width: inner + 4, height: l.bodyHeight) }
        if let y = l.parentsY { parents.frame = NSRect(x: x, y: top + y, width: inner, height: 16) }
        if let y = l.committerY { committer.frame = NSRect(x: x, y: top + y, width: inner, height: 16) }
    }
}

/// A circle with the author's initials, colored by a hash of their email so it stays the same.
final class AvatarView: NSView {
    private var initials = ""
    private var color = NSColor.systemBlue

    override var isFlipped: Bool { true }

    static func initials(name: String, email: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = words.prefix(2).compactMap(\.first)
        if !letters.isEmpty { return String(letters).uppercased() }
        return email.first.map { String($0).uppercased() } ?? "?"
    }

    /// FNV-1a, because `hashValue` changes from one launch to the next.
    static func stableIndex(_ text: String, count: Int) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.lowercased().utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % UInt64(max(1, count)))
    }

    func configure(name: String, email: String, palette: [NSColor]) {
        initials = AvatarView.initials(name: name, email: email)
        color = palette[AvatarView.stableIndex(email.isEmpty ? name : email, count: palette.count)]
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
        let s = initials as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: round((bounds.width - size.width) / 2), y: round((bounds.height - size.height) / 2)), withAttributes: attrs)
    }
}

final class ShaPillView: NSView {
    var sha = "" { didSet { needsDisplay = true } }
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override var isFlipped: Bool { true }

    var preferredWidth: CGFloat { ceil((sha as NSString).size(withAttributes: [.font: ShaPillView.font]).width) + 18 }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        theme.chromeBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: ShaPillView.font, .foregroundColor: theme.chromeSecondary]
        let size = (sha as NSString).size(withAttributes: attrs)
        (sha as NSString).draw(at: NSPoint(x: 9, y: round((bounds.height - size.height) / 2)), withAttributes: attrs)
    }
}

final class RefBadgesView: NSView {
    var refs: [RefLabel] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        _ = RefBadges.drawRow(refs, at: 0, y: 0, right: bounds.width, theme: ThemeManager.shared.active)
    }
}

/// "Parent ab23a35", or "Parents ab23a35, 80ca6ab · merge, changes compared with the first parent", with
/// each SHA a link that opens that commit.
final class ParentsView: NSView {
    var onOpen: ((String) -> Void)?
    private var shas: [String] = []
    private var links: [(rect: NSRect, sha: String)] = []
    private static let font = NSFont.systemFont(ofSize: 12)

    override var isFlipped: Bool { true }

    func configure(parents: [String]) {
        shas = parents
        links = []
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(parents.count > 1 ? "Parents" : "Parent")
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        let plain: [NSAttributedString.Key: Any] = [.font: ParentsView.font, .foregroundColor: theme.chromeSecondary]
        let link: [NSAttributedString.Key: Any] = [.font: ParentsView.font, .foregroundColor: theme.accent]
        var x: CGFloat = 0
        var found: [(NSRect, String)] = []
        func put(_ s: String, _ attrs: [NSAttributedString.Key: Any]) -> NSRect {
            let size = (s as NSString).size(withAttributes: attrs)
            let r = NSRect(x: x, y: round((bounds.height - size.height) / 2), width: ceil(size.width), height: ceil(size.height))
            (s as NSString).draw(at: r.origin, withAttributes: attrs)
            x = r.maxX
            return r
        }
        _ = put(shas.count > 1 ? "Parents " : "Parent ", plain)
        for (i, sha) in shas.enumerated() {
            if i > 0 { _ = put(", ", plain) }
            found.append((put(String(sha.prefix(7)), link).insetBy(dx: -1, dy: -1), sha))
        }
        if shas.count > 1 { _ = put(" · merge, changes compared with the first parent", plain) }
        links = found
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        for l in links { addCursorRect(l.rect, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = links.first(where: { $0.rect.contains(p) }) { onOpen?(hit.sha) }
    }

    override func accessibilityChildren() -> [Any]? {
        links.map { l in
            let e = DrawnAccessibilityElement(in: self, role: .button) { l.rect }
            e.setAccessibilityLabel("Open commit \(l.sha.prefix(7))")
            e.onPress = { [weak self] in self?.onOpen?(l.sha) }
            return e
        }
    }
}
