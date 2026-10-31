# Changelog

All notable changes to Tovri are recorded here. The release workflow turns
each section into the GitHub release notes and the in-app update notes, so
write entries for people using the app.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/rahatsagor/Tovri/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/rahatsagor/Tovri/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rahatsagor/Tovri/releases/tag/v0.1.0
