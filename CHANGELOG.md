# Changelog

All notable changes to Tovri are recorded here. The release workflow turns
each section into the GitHub release notes and the in-app update notes, so
write entries for people using the app.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Custom themes.** In **Settings → Appearance**, choose **New Theme…** to
  start from any theme and change its colors: the background, text, accent,
  selection and cursor, every kind of syntax color and, under **Interface
  colors**, the sidebar, tabs, gutter, find highlights and window blur. A
  preview shows your changes, and open windows follow along as you edit.
  Colors you don't set are worked out from the others. Your themes appear in
  **View → Theme**, the theme picker and the light and dark mode choices.
- A **Backup** settings pane. **Export…** saves your preferences, key
  bindings and custom themes to a file, and **Import…** brings them back,
  on the same Mac or another one.
- **Find in Selection** (⌥⌘L) in the find bar. It turns on by itself when you
  open the bar with several lines selected, and Replace All then changes only
  the selection.
- Regular expression replacements understand `\n` (new line), `\t` (tab)
  and `\\` (backslash).

### Changed

- Changing the line ending in the status bar is now an unsaved change you can
  undo, instead of saving the file right away.
- Whole Word finds searches that start or end with punctuation, such as
  `foo.` or `$name`, and follows each language's word characters.
- With several cursors, Shift and the arrow keys extend each selection in
  both directions, Up and Down keep each cursor's column, brackets, quotes and
  accented letters go to every cursor, and Undo brings back all the cursors.
- Delete Line, Move Line, Duplicate Line and cutting a line on a folded line
  act on the whole folded block, and moved or duplicated blocks stay folded.
- Saving keeps a file's hidden flag and updates every hard link to it, and
  Save All and saving when you quit trim whitespace and add the final newline
  the same way ⌘S does.
- Very large unsaved documents are backed up regularly while you work, not
  only when you quit.

### Fixed

- Choosing **Don't Save** really discards your changes. Reopening the file
  could bring the discarded edits back.
- Reopening Tovri could replace unsaved edits in one window with an older
  backup from a window you had closed. Both are now kept, and the older one
  opens as "(unsaved copy)".
- **Reopen with Encoding** threw away unsaved changes without asking.
- If a file changed on disk while Tovri was closed, saving your restored edits
  replaced the newer file without warning. Now Tovri asks.
- A file that disappeared and came back, such as when switching Git
  branches, showed as having unsaved changes.
- If another app removed a file's byte order mark or converted it to UTF-8,
  Tovri added the mark back or kept reading it in the old encoding.
- Save As and moving a file in the sidebar kept the old folder's
  `.editorconfig` settings, and an `.editorconfig` at the root of the disk
  never applied.
- Tovri could crash when a file it was reading was cut short by another
  program, as log rotation does.
- Syntax colors could go wrong further down a long file after Replace All or
  a multi-cursor edit followed by typing above it.
- Toggle Comment in CSS, HTML and XML broke code when whole lines were
  selected.
- Putting the caret at the end of a folded line unfolded it.
- Delete Line with several cursors left only one cursor.
- Format JSON rejected valid JSON with very large numbers, very deep nesting
  or lone `\u` escapes. Errors now say the line and column.
- Clicking a change marker on the last line of a file opened the wrong
  change.
- Files ignored only by your global Git ignore file, such as `.DS_Store`,
  showed as new in the sidebar and the Changes list.
- `tovri -w` waited forever over SSH or with a custom `TMPDIR`.

### Security

- A repository could make Git run one of its own programs through File
  History (signature checking), through filters with unusual names, through
  submodules, or by allowing a network transport. Tovri now turns all of these
  off in a way the repository can't override.
- A Markdown file could make an ordinary click load remote images. The
  button is now outside the document, and very large previews stop loading
  media after 256 MB.
- A symlink to a device such as `/dev/zero` in a repository could make the
  Changes list read forever.

## [0.3.0] - 2026-11-01

### Added

- **Compare with Last Commit** (⇧⌥⌘D) now shows the comparison in the editor
  itself: removed lines appear struck through above the lines that replaced
  them, and added or changed lines are tinted. You can keep editing; press ⎋
  to stop. A button for it appears in the tab bar when a file has changes.
  The old patch view is still there as **File → Show Changes as Patch**.
- The status bar shows how many files have uncommitted changes. Click it, or
  use **Changed Files** (⇧⌥⌘G), to list them with the lines each adds and
  removes; choosing one opens it at its first change.
- A **Git** settings pane. **Use Git** turns off everything Git-related, and
  the gutter changes, sidebar status and changed-file count can each be
  turned off on their own. A feature that's off runs no git commands at all.
  With Git off, **Find in Files** searches every file instead of skipping
  the ones Git ignores.
- **Changes and file history**, off until you turn it on in Settings → Git:
  - A **Changes** list in the sidebar, next to Files, with the lines each
    file adds and removes. Right-click a file to compare it or see its
    history.
  - **File History** (⇧⌥⌘H) lists the commits that changed the current file.
    Choose one to compare the file with that version in the editor, the same
    way Compare with Last Commit works. While comparing, the gutter markers,
    the change card, **Revert Change** and **Next/Previous Change** all work
    against that commit.
- The status bar shows the theme; click it to choose another.

### Changed

- Clicking a change marker opens a card in the editor instead of a popover.
  It shows the removed and the added lines with syntax colors, which change
  of how many it is, and buttons for the previous and next change, Revert
  and close.
- The sidebar's edge is easier to grab and highlights while you drag it.
  Double-click it to reset the sidebar's width.
- The palette shows what it's searching (files, commands, themes…) and its
  keys at the bottom.
- The cursor position moved to the right side of the status bar.
- Tovri runs git less often: it no longer reloads each open file's committed
  version every time the window is focused unless a commit was made, and the
  status bar no longer looks up the branch on every cursor move.

### Fixed

- Change markers, sidebar colors and other Git information could
  occasionally take 30 seconds to appear: Tovri sometimes missed that a git
  command had finished and waited for its time limit.
- The palette's search field never showed its placeholder text.

## [0.2.1] - 2026-11-01

### Changed

- **Close Folder** has a keyboard shortcut: ⌃⌘W.

### Fixed

- The closed-folder bug still happened across restarts: close a folder
  window, quit Tovri, relaunch it and open a single file, and the closed
  window came back along with the file. Now a window you closed before
  quitting only comes back if it has unsaved changes.
- The popover for a Git change (click a marker in the gutter) had no
  padding and cut off its title, and **Next Change** and **Previous Change**
  stepped from the text cursor instead of the change shown in the popover.
- **Find in Files** did nothing when the regular expression was invalid,
  the folder didn't exist or the search text was empty. It now explains
  what's wrong.
- Clicking the padding of an overlay panel such as **Find in Files** closed
  the panel, and panels drifted off center when the window was resized.
- ⌘W closed the tab behind **Find in Files** while the panel was open. It
  now closes the panel.
- The find bar lost focus when you clicked its buttons, didn't search again
  when you pressed ⌘E with the bar open, and clipped the "N of M" count.
- The command palette listed some commands twice, offered commands that
  can't run right now, and showed an empty list instead of "No matches".
- A long branch name or commit message in the status bar overlapped the
  items on the right instead of being truncated.
- When Tovri saves files in the background, for example because it lost
  focus, a file that can't be saved no longer opens a dialog per file. A
  short message appears in the window instead.
- The completion list could extend past the edge of the screen.
- Several menu items stayed clickable when they can't do anything, such as
  **Close Other Tabs** with a single tab open.

## [0.2.0] - 2026-11-01

### Changed

- **Find in Files** skips files that Git ignores (`.gitignore` and your
  global ignore file) when it searches a Git repository, as well as the
  folders listed in **Settings → Files**.
- **Title Case** capitalizes the first letter of each word and leaves the
  rest alone, so `NASA` and `McDonald` keep their capitals.
- `tovri file:12` only reads `:12` as a line number when `file` exists.
  Otherwise it creates a new file with exactly the name you typed, the same
  rule `tovri file:12:3` already followed.

### Fixed

- **View → Sidebar** was greyed out, so the sidebar couldn't be shown or
  hidden from the menu or with ⌘B. **Next Tab** and **Previous Tab** had the
  same problem.
- Opening a file from Finder or with `tovri` while no window is open no
  longer brings back the folder of the window you closed. That window still
  comes back if it has unsaved changes.
- With hot exit on, unsaved changes in a closed window are no longer lost
  when you open another window before quitting.
- **Save As** now trims trailing whitespace and adds the final newline when
  your settings or the destination folder's `.editorconfig` ask for it, and
  offers to save as UTF-8 when the text doesn't fit the file's encoding,
  like **Save** does.
- Read-only tabs, such as Find Results and Git changes, no longer offer
  editing commands like Sort Lines, the case commands or Trim Trailing
  Whitespace in the menus. **Convert Indentation** no longer changes the
  tab's indentation setting there.
- A Git command that hangs, for example on a stalled network volume, is
  stopped after 30 seconds instead of waiting forever.
- Deleting or moving a folder's `.git` now removes its Git markers, instead
  of keeping them until Tovri restarts.
- **Snake Case** no longer doubles underscores ("Hello World" gave
  `hello__world`) and keeps acronyms together (`parseHTTPResponse` becomes
  `parse_http_response`). **Camel Case** keeps the word breaks of names that
  are already camel or Pascal case (`FooBar` becomes `fooBar`, not `foobar`).
  Both keep each line's indentation.
- **Revert to Saved** asks before throwing away unsaved changes, since they
  can't be undone afterwards.
- The sidebar's Git markers are right for files renamed in the work tree
  (`git add -N`) or copied, instead of showing a stray entry for the old name.
- `tovri -- -file.txt` opens a file whose name starts with a dash.
## [0.1.0] - 2026-11-01

The first public release. Tovri is a fast, lightweight editor for reading
code and making quick edits on a Mac, including reviewing what an AI coding
agent just changed.

### Fast and light

- Huge files open instantly. A 93 MB file with 2 million lines opens and is
  highlighted in about a quarter of a second, because Tovri only lays out
  what is on screen.
- An empty window uses about 45 MB of memory.
- Syntax highlighting for 128 languages, including JavaScript and CSS inside
  HTML, Vue and Svelte, and code blocks in Markdown. Highlighting keeps up
  as you type.
- 15 themes, led by Tovri Dark, a translucent window with calm colors. Tovri
  can switch between a light and a dark theme with the system.

### Editing

- Multiple cursors: ⌘-click, ⌘D for the next occurrence, ⌃⌘G for all of
  them, ⇧⌘L to split a selection into lines, and ⌥-drag for a column.
- Brackets and quotes close themselves, and indentation follows the code.
- Duplicate, delete, move, join, sort and reverse lines, toggle comments and
  change case, from the Edit menu or the keyboard.
- Word completion, code folding, and copy or cut of the whole line when
  nothing is selected.
- Format and minify JSON without reordering its keys.
- Spell checking and a live word count for Markdown and plain text.

### Finding your way

- Goto Anything (⌘P) finds files by a few letters of their name, and jumps
  to a line or symbol with `file:line` and `file@symbol`.
- The command palette (⇧⌘P) runs any menu command, and picks syntaxes and
  themes.
- Goto Symbol in the file (⌘R) or the whole project (⇧⌘R), and Goto
  Definition (F12).
- Find and replace with regular expressions stays smooth on huge files, and
  Find in Files (⇧⌘F) searches a whole folder on every core.

### Reviewing changes

- Markers in the gutter show what changed since the last commit. Click one
  to see the original text or revert it, and step through changes with ⌥F5
  and ⇧⌥F5.
- Compare with Last Commit (⇧⌥⌘D) shows a diff of the file, unsaved edits
  included.
- Changed Files (⇧⌥⌘G) lists every file with uncommitted changes, so you can
  review what a coding agent touched.
- With the cursor at the end of a file that grows, such as a log or an
  agent's output, Tovri follows the new lines.

### Markdown

- A rendered preview in place of the source (⇧⌘V) or side by side (⌥⌘V),
  with tables, task lists, alerts and highlighted code as on GitHub.
- Links to other files open them in Tovri, and local images show in place.
- Scripts in Markdown files never run, and remote images load only when you
  ask.

### Files and windows

- Tabs, layouts with up to three columns or two rows, and a sidebar file
  tree that updates as files change.
- A minimap, indent guides, word wrap, and a status bar for the line,
  indentation, encoding, line endings and syntax.
- Common text encodings and Windows, Unix and classic Mac line endings, kept
  as they were when you save.
- Files changed by other apps reload on their own, and Tovri asks before it
  replaces unsaved edits. Saving keeps permissions, Finder tags and other
  file details.
- `.editorconfig` files set indentation, trailing whitespace and the final
  newline.
- Images, PDFs, media and office documents open in Quick Look. Press Space
  in the sidebar to preview any file, or drop files and folders on the
  window to open them.
- Print with syntax colors, or print the rendered Markdown.
- Windows, tabs and unsaved changes are still there after you quit.
- Every shortcut can be changed in **Settings → Key Bindings**.

### Mac app

- The `tovri` command opens files, folders and piped text from Terminal, and
  can wait while you write a commit message.
- Tovri can become the default editor for code and config files in one step.
- Automatic updates with release notes, which you can turn off in
  **Settings → Updates**.
- VoiceOver reads tabs, the status bar, the sidebar's Git status and the
  empty editor's shortcuts and recent files.

[Unreleased]: https://github.com/rahatsagor/Tovri/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/rahatsagor/Tovri/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/rahatsagor/Tovri/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/rahatsagor/Tovri/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rahatsagor/Tovri/releases/tag/v0.1.0
