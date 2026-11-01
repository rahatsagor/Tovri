import AppKit

final class FindState {
    static let shared = FindState()
    var query = ""
    var replacement = ""
    var regex = false
    var caseSensitive = false
    var wholeWord = false

    func makeRegex(query q: String? = nil) -> NSRegularExpression? {
        let q = q ?? query
        guard !q.isEmpty else { return nil }
        var pattern = regex ? q : NSRegularExpression.escapedPattern(for: q)
        if wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if !caseSensitive { opts.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: opts)
    }

    func replacementString(for match: NSTextCheckingResult, in text: String, regex re: NSRegularExpression) -> String {
        regex ? re.replacementString(for: match, in: text, offset: 0, template: replacement) : replacement
    }
}

/// Floating find & replace widget shown at the top-right of an editor.
///
/// Matching is debounced and runs off the main thread for anything but small documents, and
/// highlights are drawn by the text view for visible matches only, so typing a query stays smooth
/// even when it matches hundreds of thousands of times.
final class FindBar: NSView, NSTextFieldDelegate {
    unowned let editor: EditorView
    let findField = ThemedTextField(placeholder: "Find")
    let replaceField = ThemedTextField(placeholder: "Replace")
    private let countLabel = NSTextField(labelWithString: "")
    private lazy var toggleReplace: ToolButton = ToolButton(symbol: "chevron.right", tooltip: "Show or hide the Replace field (⌥⌘F)") { [weak self] in
        guard let self else { return }
        self.setReplaceVisible(!self.replaceVisible)
    }
    private lazy var caseButton: ToolButton = ToolButton(title: "Aa", tooltip: "Match Case (⌥⌘C)\nOnly find text with exactly the same uppercase and lowercase letters.") { [weak self] in self?.toggleOption(\.caseSensitive) }
    private lazy var wordButton: ToolButton = ToolButton(title: "ab", tooltip: "Whole Word (⌥⌘W)\nOnly match complete words, not parts of longer words.") { [weak self] in self?.toggleOption(\.wholeWord) }
    private lazy var regexButton: ToolButton = ToolButton(title: ".*", tooltip: "Regular Expression (⌥⌘R)\nTreat the search as a regular expression. Use $1, $2… in Replace to insert captured groups.") { [weak self] in self?.toggleOption(\.regex) }
    private lazy var prevButton: ToolButton = ToolButton(symbol: "chevron.up", tooltip: "Previous match (⇧↩ or ⇧⌘G)") { [weak self] in self?.step(forward: false) }
    private lazy var nextButton: ToolButton = ToolButton(symbol: "chevron.down", tooltip: "Next match (↩ or ⌘G)") { [weak self] in self?.step(forward: true) }
    private lazy var allButton: ToolButton = ToolButton(symbol: "text.cursor", tooltip: "Select all matches as multiple cursors (⌥↩)") { [weak self] in self?.selectAllMatches() }
    private lazy var closeButton: ToolButton = ToolButton(symbol: "xmark", tooltip: "Close the find bar (⎋)") { [weak self] in self?.dismiss() }
    private lazy var replaceButton: ToolButton = ToolButton(title: "Replace", tooltip: "Replace the current match and go to the next one (↩ in the Replace field)") { [weak self] in self?.replaceCurrent() }
    private lazy var replaceAllButton: ToolButton = ToolButton(title: "All", tooltip: "Replace every match in the document (⌥↩ in the Replace field). Undo with ⌘Z.") { [weak self] in self?.replaceAll() }

    private(set) var replaceVisible = false
    var preferredHeight: CGFloat { replaceVisible ? 76 : 42 }
    private var matches: [NSRange] = []
    private var current = -1
    private var generation = 0
    private var searchScheduled = false
    private var pendingSelectNearest = false
    private var origin = NSRange(location: 0, length: 0)
    private var tooMany = false
    private var searching = false
    private static let maxMatches = 200_000
    private var snapshot: NSString?
    private var snapshotVersion = -1
    private static let syncLimit = 300_000

    init(editor: EditorView) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        shadow = NSShadow()
        layer?.cornerRadius = 10
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.borderWidth = 1
        for v: NSView in [toggleReplace, findField, countLabel, caseButton, wordButton, regexButton, prevButton, nextButton,
                          allButton, closeButton, replaceField, replaceButton, replaceAllButton] { addSubview(v) }
        findField.field.delegate = self
        replaceField.field.delegate = self
        findField.field.toolTip = "Text to find. ↩ next, ⇧↩ previous, ⌥↩ select all matches, ⎋ close."
        replaceField.field.toolTip = "Replacement text. ↩ replaces the current match, ⌥↩ replaces all."
        countLabel.toolTip = "Current match and total number of matches"
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byClipping
        prevButton.symbolSize = 11
        nextButton.symbolSize = 11
        closeButton.symbolSize = 11
        toggleReplace.symbolSize = 10
        applyTheme()
        syncFromState()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func applyTheme() {
        let theme = ThemeManager.shared.active
        layer?.backgroundColor = theme.panelBackground.cgColor
        layer?.borderColor = theme.chromeBorder.cgColor
        appearance = theme.appearance
        findField.applyTheme()
        replaceField.applyTheme()
        countLabel.textColor = theme.chromeSecondary
        subviews.forEach { $0.needsDisplay = true }
    }

    func syncFromState() {
        let st = FindState.shared
        findField.stringValue = st.query
        replaceField.stringValue = st.replacement
        caseButton.isOn = st.caseSensitive
        wordButton.isOn = st.wholeWord
        regexButton.isOn = st.regex
    }

    override func layout() {
        super.layout()
        let h: CGFloat = 26
        let pad: CGFloat = 8
        var x = bounds.width - pad
        func place(_ v: NSView, _ w: CGFloat, y: CGFloat) {
            x -= w
            v.frame = NSRect(x: x, y: y, width: w, height: h)
            x -= 2
        }
        let y1: CGFloat = 8
        place(closeButton, 24, y: y1)
        place(allButton, 24, y: y1)
        place(nextButton, 24, y: y1)
        place(prevButton, 24, y: y1)
        x -= 4
        place(regexButton, 26, y: y1)
        place(wordButton, 26, y: y1)
        place(caseButton, 26, y: y1)
        x -= 2
        place(countLabel, max(56, ceil(countLabel.intrinsicContentSize.width) + 4), y: y1 + 5)
        countLabel.frame.size.height = 16
        toggleReplace.frame = NSRect(x: 6, y: y1, width: 20, height: h)
        findField.frame = NSRect(x: 30, y: y1, width: max(80, x - 34), height: h)
        let y2 = y1 + h + 8
        replaceField.isHidden = !replaceVisible
        replaceButton.isHidden = !replaceVisible
        replaceAllButton.isHidden = !replaceVisible
        if replaceVisible {
            let allW = replaceAllButton.intrinsicWidth
            let repW = replaceButton.intrinsicWidth
            replaceAllButton.frame = NSRect(x: bounds.width - pad - allW, y: y2, width: allW, height: h)
            replaceButton.frame = NSRect(x: replaceAllButton.frame.minX - 2 - repW, y: y2, width: repW, height: h)
            replaceField.frame = NSRect(x: 30, y: y2, width: findField.frame.width, height: h)
        }
    }

    func setReplaceVisible(_ v: Bool) {
        replaceVisible = v
        toggleReplace.symbol = v ? "chevron.down" : "chevron.right"
        frame.size.height = preferredHeight
        needsLayout = true
        editor.needsLayout = true
        if v { window?.makeFirstResponder(replaceField.field) }
    }

    /// Searches again for a query set from outside the bar (Use Selection for Find), keeping focus.
    func queryDidChange() {
        syncFromState()
        search(selectNearest: false, debounce: 0)
    }

    func activate() {
        syncFromState()
        origin = editor.textView.selectedRange()
        window?.makeFirstResponder(findField.field)
        findField.field.currentEditor()?.selectAll(nil)
        search(selectNearest: false, debounce: 0)
    }

    func dismiss() {
        generation += 1
        searching = false
        pendingSelectNearest = false
        snapshot = nil
        matches = []
        current = -1
        editor.textView.setFindMatches([], current: nil)
        editor.findBarDidClose()
    }

    /// ⌥⌘C / ⌥⌘W / ⌥⌘R toggle options while typing in the bar (they mean other things elsewhere).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHidden, let fr = window?.firstResponder as? NSTextView,
              fr.delegate === findField.field || fr.delegate === replaceField.field else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods == [.command, .option] else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": toggleOption(\.caseSensitive); return true
        case "w": toggleOption(\.wholeWord); return true
        case "r": toggleOption(\.regex); return true
        case "f": setReplaceVisible(!replaceVisible); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    private func toggleOption(_ key: ReferenceWritableKeyPath<FindState, Bool>) {
        FindState.shared[keyPath: key].toggle()
        syncFromState()
        search(selectNearest: true, debounce: 0)
    }

    // MARK: Text field delegate

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === findField.field {
            FindState.shared.query = f.stringValue
            search(selectNearest: true, debounce: 0.05)
        } else {
            FindState.shared.replacement = f.stringValue
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        switch sel {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if control === replaceField.field {
                if flags.contains(.command) || flags.contains(.option) { replaceAll() } else { replaceCurrent() }
            } else if flags.contains(.option) {
                selectAllMatches()
            } else {
                step(forward: !flags.contains(.shift))
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.insertTab(_:)):
            if replaceVisible { window?.makeFirstResponder(control === findField.field ? replaceField.field : findField.field) }
            return true
        default:
            return false
        }
    }

    // MARK: Matching

    /// Reloads replace the whole buffer, so neither cached matches nor an in-flight search is valid.
    func documentDidReload() {
        snapshot = nil
        snapshotVersion = -1
        matches = []
        current = -1
        pendingSelectNearest = false
        origin = editor.textView.selectedRange()
        editor.textView.setFindMatches([], current: nil)
        generation += 1
        searching = false
        guard !isHidden else { return }
        search(selectNearest: false, debounce: 0)
    }

    /// Keeps highlights roughly in place while the user edits, then re-searches when they pause.
    func documentChanged(range: NSRange, delta: Int) {
        guard !isHidden else { return }
        if !matches.isEmpty {
            let oldEnd = range.location + range.length - delta
            matches = matches.compactMap { m in
                if NSMaxRange(m) <= range.location { return m }
                if m.location >= oldEnd { return NSRange(location: m.location + delta, length: m.length) }
                return nil
            }
            current = -1
            editor.textView.setFindMatches(matches, current: nil)
        }
        search(selectNearest: false, debounce: 0.3)
    }

    private func search(selectNearest: Bool, debounce: TimeInterval) {
        generation += 1
        searching = false
        let gen = generation
        pendingSelectNearest = pendingSelectNearest || selectNearest
        if debounce > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.runSearch(gen)
            }
        } else {
            runSearch(gen)
        }
    }

    private func runSearch(_ gen: Int) {
        let selectNearest = pendingSelectNearest
        pendingSelectNearest = false
        guard let re = FindState.shared.makeRegex() else {
            apply([], selectNearest: false)
            updateCount(invalid: !FindState.shared.query.isEmpty)
            return
        }
        let doc = editor.document
        if doc.length <= FindBar.syncLimit {
            apply(FindBar.collect(re, in: doc.string as String, length: doc.length), selectNearest: selectNearest)
            return
        }
        searching = true
        updateCount()
        if snapshotVersion != doc.editVersion || self.snapshot == nil {
            self.snapshot = Perf.measure("find snapshot") { doc.string.copy() as? NSString }
            snapshotVersion = doc.editVersion
        }
        guard let snapshot = self.snapshot else { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let ms = FindBar.collect(re, in: snapshot as String, length: snapshot.length)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.searching = false
                self.apply(ms, selectNearest: selectNearest)
            }
        }
    }

    private static func collect(_ re: NSRegularExpression, in text: String, length: Int) -> [NSRange] {
        var out: [NSRange] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: length)) { m, _, stop in
            guard let r = m?.range, r.location != NSNotFound else { return }
            out.append(r)
            if out.count >= FindBar.maxMatches { stop.pointee = true }
        }
        return out
    }

    private func apply(_ ms: [NSRange], selectNearest: Bool) {
        Perf.measure("find apply \(ms.count)") { applyMatches(ms, selectNearest: selectNearest) }
    }

    private func applyMatches(_ ms: [NSRange], selectNearest: Bool) {
        matches = ms
        tooMany = ms.count >= FindBar.maxMatches
        let sel = editor.textView.selectedRange()
        if selectNearest && !ms.isEmpty {
            current = firstIndex(atOrAfter: origin.location) ?? 0
            let m = matches[current]
            editor.revealFolds(containing: m)
            editor.textView.setAllSelections([m], scroll: false)
            editor.reveal(m)
        } else {
            current = index(of: sel) ?? -1
        }
        editor.textView.setFindMatches(matches, current: current >= 0 ? matches[current] : nil)
        updateCount()
    }

    private func firstIndex(atOrAfter loc: Int) -> Int? {
        var lo = 0, hi = matches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if matches[mid].location < loc { lo = mid + 1 } else { hi = mid }
        }
        return lo < matches.count ? lo : nil
    }

    private func index(of r: NSRange) -> Int? {
        guard let i = firstIndex(atOrAfter: r.location), matches[i] == r else { return nil }
        return i
    }

    private func updateCount(invalid: Bool = false) {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let total = fmt.string(from: NSNumber(value: matches.count)) ?? "\(matches.count)"
        if invalid {
            countLabel.stringValue = "Invalid"
        } else if searching && matches.isEmpty {
            countLabel.stringValue = "Searching…"
        } else if matches.isEmpty {
            countLabel.stringValue = FindState.shared.query.isEmpty ? "" : "No results"
        } else if current >= 0 {
            countLabel.stringValue = "\(current + 1) of \(total)\(tooMany ? "+" : "")"
        } else {
            countLabel.stringValue = "\(total)\(tooMany ? "+" : "") found"
        }
        needsLayout = true
    }

    func step(forward: Bool) {
        guard !matches.isEmpty else { NSSound.beep(); return }
        let sel = editor.textView.selectedRange()
        if forward {
            let i = firstIndex(atOrAfter: NSMaxRange(sel)) ?? 0
            current = (i < matches.count && matches[i] == sel) ? (i + 1) % matches.count : i
        } else {
            let i = (firstIndex(atOrAfter: sel.location) ?? matches.count) - 1
            current = i >= 0 ? i : matches.count - 1
        }
        let m = matches[current]
        editor.revealFolds(containing: m)
        editor.textView.setAllSelections([m], scroll: false)
        editor.reveal(m)
        origin = m
        editor.textView.setFindMatches(matches, current: m)
        updateCount()
    }

    func selectAllMatches() {
        guard !matches.isEmpty else { NSSound.beep(); return }
        let ms = matches
        dismiss()
        editor.textView.setAllSelections(ms, primaryLocation: ms.first?.location)
    }

    func replaceCurrent() {
        guard let re = FindState.shared.makeRegex() else { return }
        let tv = editor.textView
        let sel = tv.selectedRange()
        let text = editor.document.string as String
        let options: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        if let m = re.firstMatch(in: text, options: options, range: sel), m.range == sel {
            let rep = FindState.shared.replacementString(for: m, in: text, regex: re)
            origin = NSRange(location: sel.location + rep.utf16.count, length: 0)
            tv.performEdits([TextEdit(sel, rep)], actionName: "Replace")
            if sel.length == 0 {
                // Skip the original character after an insertion, including a whole emoji,
                // so a lookahead doesn't keep replacing the same position forever.
                let updated = editor.document.string
                origin.location += origin.location < updated.length
                    ? updated.rangeOfComposedCharacterSequence(at: origin.location).length : 1
            }
            search(selectNearest: true, debounce: 0)
        } else {
            step(forward: true)
        }
    }

    func replaceAll() {
        guard let re = FindState.shared.makeRegex() else { return }
        let text = editor.document.string as String
        var edits: [TextEdit] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: editor.document.length)) { m, _, _ in
            guard let m, m.range.location != NSNotFound else { return }
            edits.append(TextEdit(m.range, FindState.shared.replacementString(for: m, in: text, regex: re)))
        }
        guard !edits.isEmpty else { NSSound.beep(); return }
        editor.textView.performEdits(edits, selection: .preserve, actionName: "Replace All")
        search(selectNearest: false, debounce: 0)
        countLabel.stringValue = "Replaced \(edits.count)"
        needsLayout = true
    }
}
