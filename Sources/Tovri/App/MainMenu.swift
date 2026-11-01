import AppKit

/// Builds the main menu. Editor commands target the first responder (the focused text view),
/// window commands the key window's controller.
enum MainMenu {
    private static let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    private static let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    private static let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    private static let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
    private static let f5 = String(Character(UnicodeScalar(NSF5FunctionKey)!))
    private static let f12 = String(Character(UnicodeScalar(NSF12FunctionKey)!))

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0, hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = target
        item.tag = tag
        if hidden {
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        menu.addItem(item)
        return item
    }

    private static func submenu(_ parent: NSMenu, _ title: String) -> NSMenu {
        let m = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = m
        parent.addItem(item)
        return m
    }

    static func build(recentMenu: NSMenu) -> NSMenu {
        let main = NSMenu(title: "Main")
        let app = NSApp.delegate as? AppDelegate

        // Tovri
        let appMenu = submenu(main, "Tovri")
        add(appMenu, "About Tovri", #selector(AppDelegate.showAbout(_:)), target: app)
        add(appMenu, "Check for Updates…", #selector(Updater.checkForUpdates(_:)), target: Updater.shared)
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: app)
        add(appMenu, "Install “tovri” Command…", #selector(AppDelegate.installCommandLineTool(_:)), target: app)
        add(appMenu, "Make Tovri the Default Editor…", #selector(AppDelegate.makeDefaultEditor(_:)), target: app)
        appMenu.addItem(.separator())
        let services = submenu(appMenu, "Services")
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        add(appMenu, "Hide Tovri", #selector(NSApplication.hide(_:)), "h")
        add(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(appMenu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        add(appMenu, "Quit Tovri", #selector(NSApplication.terminate(_:)), "q")

        // File
        let file = submenu(main, "File")
        add(file, "New File", #selector(AppDelegate.newDocument(_:)), "n", target: app)
        add(file, "New Window", #selector(AppDelegate.newWindowAction(_:)), "n", [.command, .shift], target: app)
        file.addItem(.separator())
        add(file, "Open…", #selector(AppDelegate.openDocument(_:)), "o", target: app)
        add(file, "Open Folder…", #selector(AppDelegate.openFolderAction(_:)), "o", [.command, .option], target: app)
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        file.addItem(recentItem)
        add(file, "Reopen Closed Tab", #selector(MainWindowController.reopenClosedTab(_:)), "t", [.command, .shift])
        file.addItem(.separator())
        add(file, "Save", #selector(MainWindowController.saveDocument(_:)), "s")
        add(file, "Save As…", #selector(MainWindowController.saveDocumentAs(_:)), "s", [.command, .shift])
        add(file, "Save All", #selector(MainWindowController.saveAllDocuments(_:)), "s", [.command, .option])
        add(file, "Revert to Saved", #selector(MainWindowController.revertDocumentToSaved(_:)))
        file.addItem(.separator())
        add(file, "Compare with Last Commit", #selector(MainWindowController.compareWithLastCommit(_:)), "d", [.command, .option, .shift])
        add(file, "Show Changes as Patch", #selector(MainWindowController.showChangesAsPatch(_:)))
        add(file, "Revert Change", #selector(MainWindowController.revertChange(_:)))
        file.addItem(.separator())
        add(file, "Reveal in Finder", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .option])
        add(file, "Reveal in Sidebar", #selector(MainWindowController.revealInSidebar(_:)))
        add(file, "Copy File Path", #selector(MainWindowController.copyFilePath(_:)))
        add(file, "Copy Relative Path", #selector(MainWindowController.copyRelativePath(_:)))
        file.addItem(.separator())
        add(file, "Print…", #selector(MainWindowController.printActiveDocument(_:)), "p", [.command, .option])
        file.addItem(.separator())
        add(file, "Close Tab", #selector(MainWindowController.closeTabCommand(_:)), "w")
        add(file, "Close Other Tabs", #selector(MainWindowController.closeOtherTabs(_:)))
        add(file, "Close All Tabs", #selector(MainWindowController.closeAllTabs(_:)), "w", [.command, .option])
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        add(file, "Close Folder", #selector(MainWindowController.closeFolder(_:)), "w", [.command, .control])

        // Edit
        let edit = submenu(main, "Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let line = submenu(edit, "Line")
        add(line, "Indent", #selector(EditorTextView.indentLines(_:)), "]")
        add(line, "Outdent", #selector(EditorTextView.outdentLines(_:)), "[")
        add(line, "Duplicate Line", #selector(EditorTextView.duplicateLine(_:)), "d", [.command, .shift])
        add(line, "Delete Line", #selector(EditorTextView.deleteLine(_:)), "k", [.control, .shift])
        add(line, "Move Line Up", #selector(EditorTextView.moveLineUp(_:)), up, [.command, .control])
        add(line, "Move Line Down", #selector(EditorTextView.moveLineDown(_:)), down, [.command, .control])
        add(line, "Join Lines", #selector(EditorTextView.joinLines(_:)), "j")
        add(line, "Insert Line After", #selector(EditorTextView.insertLineAfter(_:)), "\r")
        add(line, "Insert Line Before", #selector(EditorTextView.insertLineBefore(_:)), "\r", [.command, .shift])
        let comment = submenu(edit, "Comment")
        add(comment, "Toggle Comment", #selector(EditorTextView.toggleComment(_:)), "/")
        add(comment, "Toggle Block Comment", #selector(EditorTextView.toggleBlockComment(_:)), "/", [.command, .option])
        let text = submenu(edit, "Text")
        add(text, "Upper Case", #selector(EditorTextView.upperCase(_:)), "u", [.command, .control])
        add(text, "Lower Case", #selector(EditorTextView.lowerCase(_:)), "l", [.command, .control])
        add(text, "Title Case", #selector(EditorTextView.titleCase(_:)))
        add(text, "Swap Case", #selector(EditorTextView.swapCase(_:)))
        add(text, "snake_case", #selector(EditorTextView.snakeCase(_:)))
        add(text, "camelCase", #selector(EditorTextView.camelCase(_:)))
        text.addItem(.separator())
        add(text, "Sort Lines", #selector(EditorTextView.sortLines(_:)), f5, [])
        add(text, "Sort Lines (Case Sensitive)", #selector(EditorTextView.sortLinesCaseSensitive(_:)), f5, [.control])
        add(text, "Reverse Lines", #selector(EditorTextView.reverseLines(_:)))
        add(text, "Unique Lines", #selector(EditorTextView.uniqueLines(_:)))
        add(text, "Shuffle Lines", #selector(EditorTextView.shuffleLines(_:)))
        text.addItem(.separator())
        add(text, "Trim Trailing Whitespace", #selector(EditorTextView.trimTrailingWhitespace(_:)))
        add(text, "Convert Indentation to Spaces", #selector(EditorTextView.convertIndentationToSpaces(_:)))
        add(text, "Convert Indentation to Tabs", #selector(EditorTextView.convertIndentationToTabs(_:)))
        text.addItem(.separator())
        add(text, "Format JSON", #selector(EditorTextView.formatJSON(_:)))
        add(text, "Minify JSON", #selector(EditorTextView.minifyJSON(_:)))
        let folding = submenu(edit, "Code Folding")
        add(folding, "Fold", #selector(EditorTextView.foldCommand(_:)), "[", [.command, .option])
        add(folding, "Unfold", #selector(EditorTextView.unfoldCommand(_:)), "]", [.command, .option])
        add(folding, "Fold All", #selector(EditorTextView.foldAllCommand(_:)), "[", [.command, .option, .control])
        add(folding, "Unfold All", #selector(EditorTextView.unfoldAllCommand(_:)), "]", [.command, .option, .control])
        edit.addItem(.separator())
        add(edit, "Show Completions", #selector(NSTextView.complete(_:)), "\u{1b}", [.option])

        // Selection
        let sel = submenu(main, "Selection")
        add(sel, "Add Next Occurrence", #selector(EditorTextView.selectNextOccurrence(_:)), "d")
        add(sel, "Select All Occurrences", #selector(EditorTextView.selectAllOccurrences(_:)), "g", [.command, .control])
        add(sel, "Split into Lines", #selector(EditorTextView.splitSelectionIntoLines(_:)), "l", [.command, .shift])
        add(sel, "Add Caret Above", #selector(EditorTextView.addCaretAbove(_:)), up, [.control, .shift])
        add(sel, "Add Caret Below", #selector(EditorTextView.addCaretBelow(_:)), down, [.control, .shift])
        add(sel, "Single Selection", #selector(EditorTextView.singleSelection(_:)))
        sel.addItem(.separator())
        add(sel, "Expand Selection to Line", #selector(EditorTextView.selectLineCommand(_:)), "l")
        add(sel, "Expand Selection to Word", #selector(EditorTextView.selectWordCommand(_:)))
        add(sel, "Expand Selection to Brackets", #selector(EditorTextView.expandSelectionToBrackets(_:)), "m", [.control, .shift])
        add(sel, "Jump to Matching Bracket", #selector(EditorTextView.jumpToMatchingBracket(_:)), "m", [.control])

        // Find
        let find = submenu(main, "Find")
        add(find, "Find…", #selector(MainWindowController.showFind(_:)), "f")
        add(find, "Replace…", #selector(MainWindowController.showReplace(_:)), "f", [.command, .option])
        add(find, "Find Next", #selector(MainWindowController.findNextMatch(_:)), "g")
        add(find, "Find Previous", #selector(MainWindowController.findPreviousMatch(_:)), "g", [.command, .shift])
        add(find, "Use Selection for Find", #selector(MainWindowController.useSelectionForFindCommand(_:)), "e")
        find.addItem(.separator())
        add(find, "Find in Files…", #selector(MainWindowController.showFindInFiles(_:)), "f", [.command, .shift])

        // View
        let view = submenu(main, "View")
        add(view, "Sidebar", #selector(MainWindowController.toggleSidebarCommand(_:)), "b")
        add(view, "Focus Sidebar", #selector(MainWindowController.focusSidebar(_:)), "e", [.command, .shift])
        add(view, "Minimap", #selector(MainWindowController.toggleMinimap(_:)), "m", [.command, .option, .control])
        add(view, "Status Bar", #selector(MainWindowController.toggleStatusBar(_:)))
        add(view, "Markdown Preview", #selector(MainWindowController.toggleMarkdownPreview(_:)), "v", [.command, .shift])
        add(view, "Markdown Preview Side by Side", #selector(MainWindowController.toggleMarkdownPreviewSplit(_:)), "v", [.command, .option])
        view.addItem(.separator())
        add(view, "Word Wrap", #selector(MainWindowController.toggleWordWrap(_:)), "z", [.option])
        add(view, "Line Numbers", #selector(MainWindowController.toggleLineNumbers(_:)))
        add(view, "Indent Guides", #selector(MainWindowController.toggleIndentGuides(_:)))
        add(view, "Invisible Characters", #selector(MainWindowController.toggleInvisibles(_:)))
        view.addItem(.separator())
        let font = submenu(view, "Font Size")
        add(font, "Bigger", #selector(MainWindowController.increaseFontSize(_:)), "=")
        add(font, "Bigger", #selector(MainWindowController.increaseFontSize(_:)), "+", hidden: true)
        add(font, "Smaller", #selector(MainWindowController.decreaseFontSize(_:)), "-")
        add(font, "Reset", #selector(MainWindowController.resetFontSize(_:)), "0")
        let layout = submenu(view, "Layout")
        add(layout, "Single", #selector(MainWindowController.layoutSingle(_:)), "1", [.command, .option])
        add(layout, "Two Columns", #selector(MainWindowController.layoutColumns2(_:)), "2", [.command, .option])
        add(layout, "Three Columns", #selector(MainWindowController.layoutColumns3(_:)), "3", [.command, .option])
        add(layout, "Two Rows", #selector(MainWindowController.layoutRows2(_:)), "2", [.command, .option, .shift])
        layout.addItem(.separator())
        add(layout, "Split to New Column", #selector(MainWindowController.splitTabRight(_:)), "\\")
        add(layout, "Move Tab to Next Group", #selector(MainWindowController.moveTabToNextGroup(_:)), right, [.control, .option])
        for i in 1...3 { add(layout, "Focus Group \(i)", #selector(MainWindowController.focusGroupByNumber(_:)), "\(i)", [.control], tag: i) }

        let syntax = submenu(view, "Syntax")
        let langs = LanguageRegistry.shared.all
        var byLetter: [String: [Language]] = [:]
        for l in langs { byLetter[String(l.name.prefix(1)).uppercased(), default: []].append(l) }
        add(syntax, "Set Syntax…", #selector(MainWindowController.showSyntaxPicker(_:)))
        syntax.addItem(.separator())
        for letter in byLetter.keys.sorted() {
            let group = byLetter[letter]!
            let target = group.count > 1 ? submenu(syntax, letter) : syntax
            for l in group {
                let item = add(target, l.name, #selector(MainWindowController.setSyntaxFromMenu(_:)), "", [])
                item.representedObject = l.id
            }
        }
        let theme = submenu(view, "Theme")
        add(theme, "Select Theme…", #selector(MainWindowController.showThemePicker(_:)), "k", [.command, .control])
        add(theme, "Follow System Appearance", #selector(MainWindowController.toggleFollowSystemAppearance(_:)))
        theme.addItem(.separator())
        for t in ThemeManager.shared.themes {
            let item = add(theme, t.name, #selector(MainWindowController.setThemeFromMenu(_:)), "", [])
            item.representedObject = t.name
        }
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // Goto
        let go = submenu(main, "Goto")
        add(go, "Goto Anything…", #selector(MainWindowController.gotoAnything(_:)), "p")
        add(go, "Command Palette…", #selector(MainWindowController.commandPalette(_:)), "p", [.command, .shift])
        add(go, "Goto Symbol…", #selector(MainWindowController.gotoSymbol(_:)), "r")
        add(go, "Goto Symbol in Project…", #selector(MainWindowController.gotoSymbolInProject(_:)), "r", [.command, .shift])
        add(go, "Goto Definition", #selector(MainWindowController.gotoDefinition(_:)), f12, [])
        add(go, "Goto Definition", #selector(MainWindowController.gotoDefinition(_:)), down, [.command, .option], hidden: true)
        add(go, "Goto Line…", #selector(MainWindowController.gotoLine(_:)), "g", [.control])
        go.addItem(.separator())
        add(go, "Jump Back", #selector(MainWindowController.jumpBack(_:)), "-", [.control])
        add(go, "Jump Forward", #selector(MainWindowController.jumpForward(_:)), "-", [.control, .shift])
        go.addItem(.separator())
        add(go, "Next Change", #selector(MainWindowController.nextChange(_:)), f5, [.option])
        add(go, "Previous Change", #selector(MainWindowController.previousChange(_:)), f5, [.option, .shift])
        add(go, "Changed Files…", #selector(MainWindowController.showChangedFiles(_:)), "g", [.command, .option, .shift])
        add(go, "File History…", #selector(MainWindowController.showFileHistory(_:)), "h", [.command, .option, .shift])
        go.addItem(.separator())
        add(go, "Next Tab", #selector(MainWindowController.selectNextTabCommand(_:)), right, [.command, .option])
        add(go, "Previous Tab", #selector(MainWindowController.selectPreviousTabCommand(_:)), left, [.command, .option])
        add(go, "Next Tab", #selector(MainWindowController.selectNextTabCommand(_:)), "]", [.command, .shift], hidden: true)
        add(go, "Previous Tab", #selector(MainWindowController.selectPreviousTabCommand(_:)), "[", [.command, .shift], hidden: true)
        add(go, "Next Tab", #selector(MainWindowController.selectNextTabCommand(_:)), "\t", [.control], hidden: true)
        add(go, "Previous Tab", #selector(MainWindowController.selectPreviousTabCommand(_:)), "\t", [.control, .shift], hidden: true)
        add(go, "Move Tab Left", #selector(MainWindowController.moveTabLeft(_:)))
        add(go, "Move Tab Right", #selector(MainWindowController.moveTabRight(_:)))
        let tabs = submenu(go, "Select Tab")
        for i in 1...9 { add(tabs, i == 9 ? "Last Tab" : "Tab \(i)", #selector(MainWindowController.selectTabByNumber(_:)), "\(i)", tag: i) }

        // Window
        let window = submenu(main, "Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window

        // Help
        let help = submenu(main, "Help")
        add(help, "Keyboard Shortcuts", #selector(MainWindowController.showKeyboardShortcuts(_:)), "k", [.command, .shift])
        help.addItem(.separator())
        add(help, "Tovri on GitHub", #selector(AppDelegate.openProjectLink(_:)), target: app).representedObject = ProjectLinks.repository
        add(help, "Report an Issue", #selector(AppDelegate.openProjectLink(_:)), target: app).representedObject = ProjectLinks.newIssue
        add(help, "Release Notes", #selector(AppDelegate.openProjectLink(_:)), target: app).representedObject = ProjectLinks.releases
        NSApp.helpMenu = help

        return main
    }
}
