<div align="center">

<img src="Resources/AppIcon.svg" width="112" height="112" alt="Tovri app icon" />

# Tovri

### Open anything. Read it fast. Fix it quickly.

A fast, lightweight, native code and text editor for your Mac.<br />
Made for reading code and quick edits, including reviewing what an AI coding
agent just changed.<br />
**Opens huge files instantly. No account. No telemetry.**

<br />

<a href="https://github.com/rahatsagor/Tovri/releases/latest/download/Tovri.dmg"><img src="https://img.shields.io/badge/Download_for_Mac-242424?style=for-the-badge&logo=apple&logoColor=white" alt="Download for Mac" height="36" /></a>

<sub>Or try a live Tovri window at <a href="https://tovri.rsapplication.com"><strong>tovri.rsapplication.com</strong></a></sub>

<br />

[![Latest release](https://img.shields.io/github/v/release/rahatsagor/Tovri?style=flat-square&label=release&color=242424)](https://github.com/rahatsagor/Tovri/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-1f1f1f?style=flat-square&logo=apple)](#requirements)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-native-1f1f1f?style=flat-square)](#requirements)
[![AGPL-3.0 License](https://img.shields.io/badge/license-AGPL--3.0-1f1f1f?style=flat-square)](LICENSE)
[![Website](https://img.shields.io/badge/website-tovri.rsapplication.com-1f1f1f?style=flat-square)](https://tovri.rsapplication.com)

<br />

<!-- Hero screenshot: a Tovri window with the sidebar, a highlighted file and gutter change markers. -->

</div>

<br />

Tovri isn't an IDE, and it doesn't try to be one. It's the editor you reach
for to look inside a file, follow some code, check what changed and fix a
line or two. It's built on the macOS text system with its own syntax engine,
so it starts in a blink, stays light, and feels like a Mac app because it is
one. You don't need to be a developer to use it: if you can use TextEdit, you
can use Tovri.

<table>
<tr>
<td width="33%" align="center" valign="top">

**1. Open a file or folder**<br />
<sub>Drop it on the window, use Finder or type <code>tovri .</code> in Terminal.</sub>

</td>
<td width="33%" align="center" valign="top">

**2. Read and review**<br />
<sub>Colors for 128 languages, and every change since the last commit marked.</sub>

</td>
<td width="33%" align="center" valign="top">

**3. Make the edit**<br />
<sub>Save, and Tovri keeps the file's encoding, line endings and permissions.</sub>

</td>
</tr>
</table>

## Everything you need for reading and quick edits

<table>
<tr>
<td width="50%" valign="top">

#### Fast, even on huge files
A 93 MB log with 2 million lines opens and is highlighted in about a quarter
of a second. Tovri lays out only what's on screen, and an empty window uses
about 45 MB of memory.

</td>
<td width="50%" valign="top">

#### Review what changed
Gutter markers show every change since the last commit. Click one to see the
removed and added lines or revert them. **Compare with Last Commit** (⇧⌥⌘D)
shows removed lines right in the editor, and the status bar counts changed
files: click it to list them with the lines each one adds and removes.
Ideal for checking what a coding agent touched. Turn on **Changes and file
history** in **Settings → Git** for a Changes list in the sidebar and **File
History** (⇧⌥⌘H), which compares a file with any earlier commit. Every Git
feature can be turned off there too.

</td>
</tr>
<tr>
<td valign="top">

#### Find your way
**Goto Anything** (⌘P) opens files by a few letters of their name, the
command palette (⇧⌘P) runs any command, and Goto Symbol (⌘R), Goto Symbol in
Project (⇧⌘R) and Goto Definition (F12) jump straight to the code you need.
Find in Files (⇧⌘F) searches a whole folder on every core.

</td>
<td valign="top">

#### Edit quickly
Multiple cursors, column selection, line commands, comments, case changes,
sorting, word completion and code folding. Brackets and quotes close
themselves, and JSON formats or minifies without reordering its keys.

</td>
</tr>
<tr>
<td valign="top">

#### Markdown, rendered
Preview a document in place (⇧⌘V) or side by side (⌥⌘V), with tables, task
lists, alerts and highlighted code as on GitHub. Scripts never run, and
remote images load only when you ask.

</td>
<td valign="top">

#### Made for the Mac
15 themes that can follow light and dark mode, tabs and split layouts, a
minimap, Quick Look for images, PDFs and documents, printing, `.editorconfig`
support, and spell checking for prose.

</td>
</tr>
<tr>
<td valign="top">

#### Never lose your work
Windows, tabs and unsaved changes are still there after you quit. Files
changed by other apps reload on their own, and Tovri asks before it replaces
your edits. A growing log follows its new lines.

</td>
<td valign="top">

#### Safe with any folder
Opening a file, previewing it or showing a repository's changes never runs
code from it. No accounts, no analytics; the only outside connection is the
update check. Read [SECURITY.md](SECURITY.md) for the details.

</td>
</tr>
</table>

The [changelog](CHANGELOG.md) lists everything Tovri can do, release by
release.

## Requirements

- A Mac with Apple silicon, running macOS 14 Sonoma or later.
- For the Git features, Git itself: the Xcode Command Line Tools
  (`xcode-select --install`) or Homebrew's `git`.

## Install

**With Homebrew**

```sh
brew install --cask rahatsagor/tap/tovri
```

**Or download it**

1. Download [Tovri.dmg](https://github.com/rahatsagor/Tovri/releases/latest/download/Tovri.dmg)
   and drag Tovri into Applications.
2. Tovri is free and open source, and it isn't notarized by Apple yet, so
   macOS asks you to confirm the first time it opens. Run this once in
   Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Tovri.app
   ```

   Or open Tovri, then go to **System Settings → Privacy & Security** and
   click **Open Anyway**.
3. Open Tovri from Applications.

You only do this once. Updates install from inside the app (**Tovri → Check
for Updates…**), and Homebrew skips this step for you.

## Command line

Choose **Tovri → Install “tovri” Command…** (or **Settings → Files**). Tovri
links the command into `/opt/homebrew/bin` or `/usr/local/bin`; when that
needs administrator rights, it copies the one-line `sudo` command for you.
The same places offer to uninstall it. Then:

```sh
tovri file.swift other.md   # open files
tovri ~/Projects/app        # open a folder
tovri src/main.go:42:7      # open at line 42, column 7
tovri new-file.ts           # a path that doesn't exist opens as a new, unsaved file
tovri -n notes.txt          # open in a new window
git diff | tovri            # piped text opens in a new tab (or: tovri -)
git config --global core.editor "tovri -w"   # -w waits until the tab is closed
```

## Default editor

Tovri registers as an editor for source code, config and text files (178
extensions). To make it the default, choose **Tovri → Make Tovri the Default
Editor…** or use **Settings → Files**, which also shows how many code file
types already open in Tovri. HTML, SVG, CSV and property lists keep their
current apps. You can still change individual types in Finder's Get Info.

## Keyboard shortcuts

**Help → Keyboard Shortcuts** (⇧⌘K) lists every shortcut, generated from the
current menus. Every menu command can be rebound in **Settings → Key
Bindings**: search, click a shortcut and press the new keys (Esc cancels, ⌫
removes it). Conflicts are flagged, and each binding can be reset.

## Troubleshooting

<details>
<summary><strong>"Apple could not verify Tovri is free of malware"</strong></summary>
<br />

Tovri isn't notarized by Apple, so macOS asks once. Run
`xattr -dr com.apple.quarantine /Applications/Tovri.app` in Terminal, or open
**System Settings → Privacy & Security** and click **Open Anyway**. If macOS
says Tovri "is damaged and can't be opened", the same command fixes it.

</details>

<details>
<summary><strong>The <code>tovri</code> command isn't found</strong></summary>
<br />

Install it from **Tovri → Install “tovri” Command…**. If Terminal still says
`command not found`, open a new Terminal window, and check that your `PATH`
includes `/opt/homebrew/bin` or `/usr/local/bin` (`echo $PATH`).

</details>

<details>
<summary><strong>Changes since the last commit aren't marked</strong></summary>
<br />

Tovri uses the Git installed on your Mac. Install the Xcode Command Line
Tools with `xcode-select --install`, or `brew install git`. Check that
**Settings → Git → Use Git** and **Changes in the editor** are on, and that the file is
inside a Git repository.

</details>

<details>
<summary><strong>macOS keeps asking for access to a folder</strong></summary>
<br />

macOS asks before an app reads your Desktop, Documents, Downloads or an
external drive, and remembers the answer for that copy of the app. If you
declined once, allow Tovri in **System Settings → Privacy & Security → Files
and Folders**.

</details>

<details>
<summary><strong>Typing or scrolling feels slow</strong></summary>
<br />

That's a bug worth reporting. Quit Tovri, then run:

```sh
open --env TOVRI_PERF=1 --stderr /tmp/tovri.log -a Tovri
```

Repeat what felt slow, quit, and attach `/tmp/tovri.log` to an
[issue](https://github.com/rahatsagor/Tovri/issues/new/choose). It has
timings, not the contents of your files.

</details>

<details>
<summary><strong>Something else</strong></summary>
<br />

Please [open an issue](https://github.com/rahatsagor/Tovri/issues/new/choose)
with your Tovri version (**Tovri → About Tovri**), your macOS version, and
what happened. **Help → Report an Issue** opens the same page.

</details>

## Build from source

You need Xcode 16 or later on an Apple silicon Mac.

```sh
make            # build/Release/Tovri.app
make run        # build and open it
make test       # run the tests
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers the project layout, architecture,
signing and development workflow. Bug reports, ideas and pull requests are
welcome.

## License

© 2026 Tovri. Free and open source under the
[GNU Affero General Public License v3.0](LICENSE). You may use, study, share
and modify Tovri, but anything you distribute or offer to others that is
based on it must be released under the same license, with its full source
code.

<div align="center">
<br />
<img src="Resources/AppIcon.svg" width="40" height="40" alt="" />
<br />
<a href="https://tovri.rsapplication.com"><strong>tovri.rsapplication.com</strong></a>
·
<a href="https://github.com/rahatsagor/Tovri"><strong>github.com/rahatsagor/Tovri</strong></a>
</div>
