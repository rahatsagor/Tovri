import AppKit

protocol EditorViewDelegate: AnyObject {
    func editorDidFocus(_ editor: EditorView)
    func editorSelectionDidChange(_ editor: EditorView)
    func editor(_ editor: EditorView, openFindResultPath path: String, line: Int)
    func editor(_ editor: EditorView, openFiles urls: [URL])
}

/// One editing surface for a document: gutter, scrollable text view, minimap and find bar.
final class EditorView: NSView, NSTextViewDelegate, DocumentEditor {
    let document: Document
    let scrollView = EditorScrollView()
    let textView: EditorTextView
    let gutter = GutterView()
    let minimap = MinimapView()
    private let topShadow = ShadowView()
    let layoutManager = TovriLayoutManager()
    let textContainer: NSTextContainer
    private(set) var colorizer: Colorizer!
    private(set) var findBar: FindBar?
    weak var delegate: EditorViewDelegate?

    private var recolorScheduled = false
    private(set) var wordWrap = false
    private var wordWrapOverride: Bool?
    private var lastGutterWidth: CGFloat = 0
    private var isClosed = false

    override var isFlipped: Bool { true }

    init(document: Document) {
        self.document = document
        textContainer = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 6
        layoutManager.addTextContainer(textContainer)
        document.textStorage.addLayoutManager(layoutManager)
        textView = EditorTextView(document: document, frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none

        textView.delegate = self
        textView.editor = self
        gutter.textView = textView
        minimap.textView = textView
        gutter.toolTip = "Click a line number to select the line, drag to select several. Click an arrow to fold or unfold a block. Click a colored change marker to see what changed since the last commit."
        minimap.toolTip = "Overview of the file. Click or drag to scroll."

        addSubview(gutter)
        addSubview(scrollView)
        scrollView.accessory = minimap
        addSubview(topShadow)
        topShadow.isHidden = true

        colorizer = Colorizer(document: document, layoutManager: layoutManager)
        colorizer.onNeedsCatchUp = { [weak self] line in self?.scheduleCatchUp(to: line) }
        document.addEditor(self)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        nc.addObserver(self, selector: #selector(themeChanged), name: .themeDidChange, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)
        nc.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: nil)

        if document.length > 0 && hasVeryLongLines() { wordWrapOverride = true }
        applySettings()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Detaches from the document. Must be called when the tab closes.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        NotificationCenter.default.removeObserver(self)
        CompletionController.shared.hide()
        textView.delegate = nil
        document.removeEditor(self)
        document.textStorage.removeLayoutManager(layoutManager)
    }

    private func hasVeryLongLines() -> Bool {
        let starts = document.lines.starts
        var prev = 0
        for s in starts.dropFirst() {
            if s - prev > 20_000 { return true }
            prev = s
        }
        return document.length - prev > 20_000
    }

    // MARK: Layout

    var showMinimap: Bool { Settings.shared.showMinimap && bounds.width > 500 && !document.isFindResults && previewMode == .off }

    // MARK: Markdown preview

    enum PreviewMode { case off, full, split }

    private(set) var preview: MarkdownPreviewView?
    private(set) var previewMode: PreviewMode = .off
    private var previewUpdateScheduled = false
    var isPreviewing: Bool { previewMode != .off }
    var isMarkdown: Bool { document.language.id == "markdown" }

    /// Switches between the rendered document and the source.
    func toggleMarkdownPreview() { setPreviewMode(previewMode == .full ? .off : .full) }
    func toggleMarkdownPreviewSplit() { setPreviewMode(previewMode == .split ? .off : .split) }
    func setMarkdownPreview(_ on: Bool) { setPreviewMode(on ? .full : .off) }

    func setPreviewMode(_ mode: PreviewMode) {
        guard mode != previewMode, mode == .off || isMarkdown else { return }
        let old = previewMode
        // Keep the reader's place: the preview reports its top line, the editor its first visible one.
        let line = old == .full ? (preview?.topLine ?? topVisibleLine) : topVisibleLine
        previewMode = mode
        if mode == .off {
            preview?.removeFromSuperview()
            preview = nil
        } else if preview == nil {
            let p = MarkdownPreviewView(frame: bounds)
            p.onOpenFile = { [weak self] url in
                guard let self else { return }
                self.delegate?.editor(self, openFiles: [url])
            }
            p.onRequestRemoteContent = { [weak self, weak p] in
                guard let self, let p, !p.allowsRemoteContent else { return }
                let line = self.previewMode == .full ? p.topLine : self.topVisibleLine
                p.allowsRemoteContent = true
                p.loadShell(theme: ThemeManager.shared.active, fontSize: self.document.font.pointSize)
                self.renderPreview()
                p.scroll(toLine: line)
            }
            preview = p
            addSubview(p, positioned: .below, relativeTo: findBar)
            p.loadShell(theme: ThemeManager.shared.active, fontSize: document.font.pointSize)
            renderPreview()
        }
        let full = mode == .full
        gutter.isHidden = full
        scrollView.isHidden = full
        preview?.showsDivider = mode == .split
        if full, let bar = findBar, !bar.isHidden { bar.dismiss() }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if old == .full && mode != .full { scrollLineToTop(line) }
        if mode != .off { preview?.scroll(toLine: line) }
        if full {
            preview?.focus()
        } else if old == .full {
            focus()
        }
        delegate?.editorSelectionDidChange(self)
    }

    private func renderPreview() {
        guard let preview else { return }
        let theme = ThemeManager.shared.active
        var renderer = MarkdownRenderer(colors: MarkdownPreviewView.tokenColors(theme))
        let html = Perf.measure("markdown render") { renderer.render(document.string as String) }
        preview.setBody(html, baseDirectory: document.url?.deletingLastPathComponent())
    }

    private func schedulePreviewUpdate() {
        guard preview != nil, !previewUpdateScheduled else { return }
        previewUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.previewUpdateScheduled = false
            self.renderPreview()
        }
    }

    func scrollLineToTop(_ line: Int) {
        let loc = document.lines.start(of: line)
        let range = NSRange(location: loc, length: 0)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: loc, length: min(1, document.length - loc)))
        // Let NSTextView resolve the target viewport before positioning its first line;
        // laying out only the target character leaves surrounding estimates unresolved.
        textView.scrollRangeToVisible(range)
        textView.sizeToFit()
        let r = textView.caretRect(at: loc)
        let clip = scrollView.contentView
        clip.scroll(to: textView.constrainedScrollPosition(NSPoint(x: clip.bounds.minX, y: r.minY - textView.textContainerInset.height)))
        scrollView.reflectScrolledClipView(clip)
    }

    var topVisibleLine: Int { document.lines.line(containing: textView.visibleCharacterRange.location) }

    override func layout() {
        super.layout()
        let gw = gutter.requiredWidth
        lastGutterWidth = gw
        let mw: CGFloat = showMinimap ? 100 : 0
        let pw: CGFloat = previewMode == .full ? bounds.width : previewMode == .split ? floor(bounds.width * 0.5) : 0
        let textWidth = bounds.width - pw
        gutter.frame = NSRect(x: 0, y: 0, width: gw, height: bounds.height)
        scrollView.accessoryWidth = mw
        scrollView.frame = NSRect(x: gw, y: 0, width: max(0, textWidth - gw), height: bounds.height)
        scrollView.tile()
        preview?.frame = NSRect(x: max(0, textWidth), y: 0, width: pw, height: bounds.height)
        topShadow.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 6)
        if wordWrap {
            textView.frame.size.width = scrollView.textViewportWidth
        }
        textView.minSize = NSSize(width: scrollView.textViewportWidth, height: scrollView.contentSize.height)
        textView.setFrameSize(textView.frame.size)
        textView.constrainScrollPosition()
        layoutFindBar()
        colorizeVisible()
    }

    private func layoutFindBar() {
        guard let bar = findBar else { return }
        let width = min(560, scrollView.textViewportWidth - 24)
        let h = bar.preferredHeight
        bar.frame = NSRect(x: scrollView.frame.minX + scrollView.textViewportWidth - width - 14, y: 8, width: width, height: h)
    }

    private func checkGutterWidth() {
        if gutter.requiredWidth != lastGutterWidth { needsLayout = true }
    }

    // MARK: Settings and theme

    @objc private func settingsChanged() { applySettings() }

    func applySettings() {
        let s = Settings.shared
        textView.applyFontMetrics()
        layoutManager.showInvisibles = s.showInvisibles
        textView.scrollPastEnd = s.scrollPastEnd
        gutter.showsNumbers = s.showLineNumbers
        gutter.updateStyle()
        setWordWrap(wordWrapOverride ?? s.wordWrap)
        updateSpellChecking()
        layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: document.length))
        needsLayout = true
        textView.needsDisplay = true
        minimap.needsDisplay = true
    }

    @objc private func themeChanged() { applyTheme() }

    func applyTheme() {
        let theme = ThemeManager.shared.active
        textView.applyTheme(theme)
        scrollView.backgroundColor = theme.editorBackground
        scrollView.drawsBackground = !theme.translucent
        scrollView.contentView.drawsBackground = !theme.translucent
        scrollView.appearance = theme.appearance
        gutter.updateStyle()
        colorizer.updateTheme()
        colorizeVisible()
        findBar?.applyTheme()
        minimap.needsDisplay = true
        gutter.needsDisplay = true
        if let p = preview {
            let line = previewMode == .full ? p.topLine : topVisibleLine
            p.loadShell(theme: theme, fontSize: document.font.pointSize)
            renderPreview()
            p.scroll(toLine: line)
            p.needsDisplay = true
        }
    }

    func setWordWrap(_ on: Bool) {
        wordWrap = on
        if on {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textContainer.widthTracksTextView = true
            let w = max(100, scrollView.textViewportWidth)
            textContainer.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = w
            scrollView.hasHorizontalScroller = false
        } else {
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            scrollView.hasHorizontalScroller = true
        }
        textView.sizeToFit()
    }

    func toggleWordWrap() {
        wordWrapOverride = !wordWrap
        setWordWrap(!wordWrap)
        needsLayout = true
    }

    @objc private func windowKeyChanged(_ n: Notification) {
        guard (n.object as? NSWindow) === window else { return }
        textView.needsDisplay = true
    }

    // MARK: Coloring

    func colorizeVisible() {
        guard !isClosed else { return }
        let r = textView.visibleCharacterRange
        let extra = max(3000, r.length / 2)
        let start = max(0, r.location - extra)
        let end = min(document.length, NSMaxRange(r) + extra)
        Perf.measure("colorize \(document.displayName)") {
            colorizer.colorize(NSRange(location: start, length: end - start))
        }
    }

    private func scheduleRecolor() {
        guard !recolorScheduled else { return }
        recolorScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.recolorScheduled = false
            self.colorizeVisible()
            self.minimap.needsDisplay = true
        }
    }

    private var catchUpTarget = -1

    /// Lexes toward `line` in ~6 ms slices so the UI never blocks, then recolors exactly.
    func scheduleCatchUp(to line: Int) {
        let running = catchUpTarget >= 0
        catchUpTarget = max(catchUpTarget, line)
        guard !running else { return }
        func step() {
            guard !isClosed else { return }
            let done = document.syntax.advance(toward: catchUpTarget, text: document.string, lines: document.lines, budget: 0.006)
            if done {
                catchUpTarget = -1
                colorizer.invalidateAll()
                colorizeVisible()
                minimap.needsDisplay = true
            } else {
                DispatchQueue.main.async(execute: step)
            }
        }
        DispatchQueue.main.async(execute: step)
    }

    @objc private func scrolled() {
        if previewMode == .split { preview?.scroll(toLine: topVisibleLine) }
        let scrolledDown = scrollView.contentView.bounds.minY > 1
        if topShadow.isHidden == scrolledDown { topShadow.isHidden = !scrolledDown }
        colorizeVisible()
        gutter.needsDisplay = true
        minimap.needsDisplay = true
        textView.updateOccurrences()
        CompletionController.shared.hide()
    }

    // MARK: DocumentEditor

    func documentDidEdit(range: NSRange, delta: Int) {
        adjustFolds(editedRange: range, delta: delta)
        schedulePreviewUpdate()
        colorizer.invalidateAll()
        scheduleRecolor()
        checkGutterWidth()
        gutter.needsDisplay = true
        findBar?.documentChanged(range: range, delta: delta)
    }

    func documentDidReload() {
        layoutManager.setFoldsStorage([])
        colorizer.clearAll()
        let len = document.length
        let sel = textView.selectedRange()
        textView.setAllSelections([NSRange(location: min(sel.location, len), length: 0)], scroll: false)
        findBar?.documentDidReload()
        textView.applyFontMetrics()
        textView.sizeToFit()
        textView.constrainScrollPosition()
        colorizeVisible()
        schedulePreviewUpdate()
        checkGutterWidth()
        gutter.needsDisplay = true
        minimap.needsDisplay = true
    }

    func documentGitDiffDidChange() {
        gutter.needsDisplay = true
    }

    /// Code is full of identifiers that aren't words, so only prose is checked.
    func updateSpellChecking() {
        let on = Settings.shared.spellCheckProse && document.isProse && !document.isReadOnly && document.length < 2_000_000
        if textView.isContinuousSpellCheckingEnabled != on { textView.isContinuousSpellCheckingEnabled = on }
    }

    func documentLanguageDidChange() {
        updateSpellChecking()
        if !isMarkdown { setMarkdownPreview(false) }
        colorizer.clearAll()
        colorizeVisible()
        minimap.needsDisplay = true
        delegate?.editorSelectionDidChange(self)
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { document.undoManager }

    func textDidChange(_ notification: Notification) {
        textView.setFrameSize(textView.frame.size)
        textView.constrainScrollPosition()
        colorizeVisible()
        gutter.needsDisplay = true
        minimap.needsDisplay = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionDidChange()
    }

    func selectionDidChange() {
        if !folds.isEmpty { revealFolds(containing: textView.selectedRange()) }
        gutter.needsDisplay = true
        textView.updateBracketMatch()
        textView.updateOccurrences()
        if Settings.shared.highlightCurrentLine { textView.invalidateCurrentLineHighlights() }
        delegate?.editorSelectionDidChange(self)
    }

    func textViewDidBecomeFirstResponder() {
        delegate?.editorDidFocus(self)
    }

    func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let m = NSMenu()
        addSpellingItems(to: m, at: charIndex)
        m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Toggle Comment", action: #selector(EditorTextView.toggleComment(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Select All Occurrences", action: #selector(EditorTextView.selectAllOccurrences(_:)), keyEquivalent: "")
        m.addItem(.separator())
        let caseMenu = NSMenu()
        caseMenu.addItem(withTitle: "Upper Case", action: #selector(EditorTextView.upperCase(_:)), keyEquivalent: "")
        caseMenu.addItem(withTitle: "Lower Case", action: #selector(EditorTextView.lowerCase(_:)), keyEquivalent: "")
        caseMenu.addItem(withTitle: "Title Case", action: #selector(EditorTextView.titleCase(_:)), keyEquivalent: "")
        let ci = NSMenuItem(title: "Convert Case", action: nil, keyEquivalent: "")
        ci.submenu = caseMenu
        m.addItem(ci)
        if document.url != nil {
            m.addItem(.separator())
            m.addItem(withTitle: "Reveal in Finder", action: #selector(MainWindowController.revealInFinder(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Copy File Path", action: #selector(MainWindowController.copyFilePath(_:)), keyEquivalent: "")
        }
        return m
    }

    // MARK: Spelling

    /// Suggestions, Learn and Ignore for a misspelled word under the pointer.
    private func addSpellingItems(to m: NSMenu, at charIndex: Int) {
        guard textView.isContinuousSpellCheckingEnabled, charIndex < document.length else { return }
        let range = textView.selectionRange(forProposedRange: NSRange(location: charIndex, length: 0), granularity: .selectByWord)
        guard range.length > 0, range.length < 100 else { return }
        let word = document.string.substring(with: range)
        let checker = NSSpellChecker.shared
        let tag = textView.spellCheckerDocumentTag
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: nil, wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
        guard miss.location != NSNotFound else { return }
        let guesses = checker.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word, language: nil, inSpellDocumentWithTag: tag) ?? []
        if guesses.isEmpty {
            m.addItem(NSMenuItem(title: "No Guesses Found", action: nil, keyEquivalent: ""))
        }
        for guess in guesses.prefix(6) {
            let item = NSMenuItem(title: guess, action: #selector(replaceMisspelling(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [NSValue(range: range), guess, word] as [Any]
            m.addItem(item)
        }
        m.addItem(.separator())
        for (title, action) in [("Learn Spelling", #selector(learnSpelling(_:))), ("Ignore Spelling", #selector(ignoreSpelling(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = word
            m.addItem(item)
        }
        m.addItem(.separator())
    }

    @objc private func replaceMisspelling(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [Any], let range = (info[0] as? NSValue)?.rangeValue,
              let guess = info[1] as? String, let word = info[2] as? String,
              NSMaxRange(range) <= document.length, document.string.substring(with: range) == word else { return }
        textView.performEdits([TextEdit(range, guess)], actionName: "Correct Spelling")
    }

    @objc private func learnSpelling(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        NSSpellChecker.shared.learnWord(word)
        recheckSpelling()
    }

    @objc private func ignoreSpelling(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: textView.spellCheckerDocumentTag)
        recheckSpelling()
    }

    private func recheckSpelling() {
        textView.isContinuousSpellCheckingEnabled = false
        updateSpellChecking()
    }

    // MARK: Navigation

    func goTo(line: Int, column: Int = 0) {
        let lines = document.lines
        let l = min(max(0, line &- 1), lines.count - 1)
        let r = lines.range(of: l, textLength: document.length)
        let loc = r.location + min(max(0, column), r.length)
        revealFolds(containing: NSRange(location: loc, length: 0))
        textView.setAllSelections([NSRange(location: loc, length: 0)], scroll: false)
        scrollToCenter(NSRange(location: loc, length: 0))
    }

    func select(_ range: NSRange, center: Bool = true) {
        revealFolds(containing: range)
        textView.setAllSelections([range], scroll: !center)
        if center { scrollToCenter(range) }
    }

    /// Scrolls only if the range isn't already visible.
    func reveal(_ range: NSRange) {
        let vis = textView.visibleCharacterRange
        if range.location >= vis.location && NSMaxRange(range) <= NSMaxRange(vis) {
            let r = textView.rects(for: range).first ?? .zero
            if textView.visibleRect.insetBy(dx: 0, dy: textView.lineHeight).contains(r) { return }
        }
        scrollToCenter(range)
    }

    func scrollToCenter(_ range: NSRange) {
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: range.location, length: min(range.length, 1)))
        textView.scrollRangeToVisible(range)
        centerOn(range)
        DispatchQueue.main.async { [weak self] in self?.centerOn(range) }
    }

    private func centerOn(_ range: NSRange) {
        guard NSMaxRange(range) <= document.length else { return }
        let rect = range.length > 0 ? (textView.rects(for: range).first ?? textView.caretRect(at: range.location)) : textView.caretRect(at: range.location)
        let clip = scrollView.contentView
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        let y = min(max(0, rect.midY - clip.bounds.height * 0.4), maxY)
        var x = clip.bounds.minX
        if rect.minX < x || rect.maxX > x + clip.bounds.width { x = max(0, rect.minX - clip.bounds.width / 2) }
        clip.scroll(to: NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    var scrollPosition: CGPoint {
        get { scrollView.contentView.bounds.origin }
        set {
            textView.sizeToFit()
            scrollView.contentView.scroll(to: textView.constrainedScrollPosition(newValue))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    // MARK: Find

    func showFindBar(replace: Bool) {
        // Find works on the source, so bring it back beside the rendered view.
        if previewMode == .full { setPreviewMode(.split) }
        if findBar == nil {
            let bar = FindBar(editor: self)
            findBar = bar
            addSubview(bar)
        }
        guard let bar = findBar else { return }
        bar.isHidden = false
        bar.setReplaceVisible(replace)
        let sel = textView.selectedRange()
        if sel.length > 0 && sel.length < 500 {
            let s = document.string.substring(with: sel)
            if !s.contains("\n") { FindState.shared.query = s; if FindState.shared.regex { FindState.shared.query = NSRegularExpression.escapedPattern(for: s) } }
        }
        layoutFindBar()
        bar.activate()
    }

    @discardableResult
    func closeFindBarIfVisible() -> Bool {
        guard let bar = findBar, !bar.isHidden else { return false }
        bar.dismiss()
        return true
    }

    func findBarDidClose() {
        findBar?.isHidden = true
        focus()
    }

    func cancelOperationFallback() {}

    func findNext(forward: Bool) {
        if let bar = findBar, !bar.isHidden {
            bar.step(forward: forward)
            return
        }
        guard let re = FindState.shared.makeRegex() else { NSSound.beep(); return }
        let text = document.string as String
        let len = document.length
        let sel = textView.selectedRange()
        let options: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        var found: NSRange?
        if forward {
            var from = NSMaxRange(sel)
            if sel.length == 0, re.firstMatch(in: text, options: options, range: sel)?.range == sel {
                from = sel.location < len ? NSMaxRange(document.string.rangeOfComposedCharacterSequence(at: sel.location)) : len + 1
            }
            if from <= len {
                found = re.firstMatch(in: text, options: options, range: NSRange(location: from, length: len - from))?.range
            }
            if found == nil { found = re.firstMatch(in: text, range: NSRange(location: 0, length: len))?.range }
        } else {
            found = re.matches(in: text, options: options, range: NSRange(location: 0, length: sel.location))
                .last(where: { $0.range.location < sel.location })?.range
            if found == nil { found = re.matches(in: text, range: NSRange(location: 0, length: len)).last?.range }
        }
        if let r = found, r.location != NSNotFound { select(r) } else { NSSound.beep() }
    }

    func useSelectionForFind() {
        let sel = textView.selectedRange()
        var r = sel
        if r.length == 0, let w = textView.wordRange(at: sel.location) { r = w }
        guard r.length > 0 else { return }
        let s = document.string.substring(with: r)
        FindState.shared.query = FindState.shared.regex ? NSRegularExpression.escapedPattern(for: s) : s
        findBar?.syncFromState()
    }

    // MARK: Find results

    func openFindResult(at index: Int) {
        let lines = document.lines
        let s = document.string
        let len = document.length
        let l = lines.line(containing: index)
        let lineText = s.substring(with: lines.range(of: l, textLength: len))
        let trimmed = lineText.trimmingCharacters(in: .whitespaces)
        guard lineText.hasPrefix(" "), let colon = trimmed.firstIndex(of: ":"), let number = Int(trimmed[..<colon]) else { return }
        var k = l - 1
        while k >= 0 {
            let t = s.substring(with: lines.range(of: k, textLength: len))
            if !t.hasPrefix(" ") && t.hasSuffix(":") && !t.isEmpty {
                delegate?.editor(self, openFindResultPath: String(t.dropLast()), line: number)
                return
            }
            k -= 1
        }
    }

    /// Marks query matches inside the result lines of a Find Results buffer.
    func highlightFindResults(_ re: NSRegularExpression) {
        let s = document.string
        let len = document.length
        let lines = document.lines
        let color = ThemeManager.shared.active.findMatch
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: len))
        let str = s as String
        var marked = 0
        for line in 0..<lines.count {
            let r = lines.range(of: line, textLength: len)
            guard r.length > 8, s.character(at: r.location) == 32 else { continue }
            let colon = s.range(of: ": ", options: .literal, range: r)
            guard colon.location != NSNotFound else { continue }
            let content = NSRange(location: NSMaxRange(colon), length: NSMaxRange(r) - NSMaxRange(colon))
            for m in re.matches(in: str, range: content) where m.range.length > 0 {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: m.range)
                marked += 1
            }
            if marked > 50_000 { break }
        }
    }

    func openDroppedFiles(_ urls: [URL]) {
        delegate?.editor(self, openFiles: urls)
    }

    // MARK: Symbols

    struct Symbol {
        let name: String
        let line: Int
        let range: NSRange
    }

    func symbols() -> [Symbol] { document.symbols() }
}

/// Soft shadow under the tab bar while the editor is scrolled.
final class ShadowView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let dark = ThemeManager.shared.active.isDark
        NSGradient(starting: NSColor.black.withAlphaComponent(dark ? 0.35 : 0.12), ending: NSColor.black.withAlphaComponent(0))?
            .draw(in: bounds, angle: 90)
    }
}

/// Editor scroll view. The minimap lives inside it at the right edge, so the text viewport stops
/// before the minimap while the vertical scroller sits at the far right, over the minimap's edge.
final class EditorScrollView: OverlayScrollView {
    var accessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let a = accessory { addSubview(a, positioned: .below, relativeTo: verticalScroller) }
            tile()
        }
    }
    var accessoryWidth: CGFloat = 0 { didSet { if oldValue != accessoryWidth { tile() } } }

    /// Width available to the text, excluding the minimap.
    var textViewportWidth: CGFloat { contentView.frame.width }

    override func tile() {
        super.tile()
        let w = accessory == nil ? 0 : accessoryWidth
        accessory?.isHidden = w == 0
        guard w > 0 else { return }
        var clip = contentView.frame
        clip.size.width = max(0, bounds.width - w - clip.minX)
        contentView.frame = clip
        accessory?.frame = NSRect(x: bounds.width - w, y: 0, width: w, height: bounds.height)
        if let h = horizontalScroller, !h.isHidden {
            var f = h.frame
            f.size.width = clip.maxX - f.minX
            h.frame = f
        }
    }
}
