# Security

Tovri is an editor, so it opens files and folders from anywhere: a download, a
cloned repository, a coding agent's output. Opening, previewing or browsing
them must never run code from them. This page describes how Tovri keeps to
that and how to report a problem.

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/rahatsagor/Tovri/security/advisories/new)
rather than in a public issue. Include the Tovri version, what an attacker
needs (a file you open, a folder you browse, a link you click, another app on
the Mac), and steps to reproduce. You should hear back within a week.

Only the latest release receives fixes.

## Untrusted files and folders

- **Markdown preview.** The preview is the only web view in Tovri. Its page
  allows only Tovri's own script under a strict Content Security Policy with
  DNS prefetching disabled, strips active elements including `<base>`,
  `<meta>`, and `<link>` inside templates, ignores untrusted synthetic clicks
  on code-copy buttons, and limits local media loads to 256 MB total per
  preview session. Remote images and media are blocked until you click
  **Load Remote Images** in the bar above the preview (which the document can't
  draw or click itself) or allow them in **Settings → Files**, because loading
  them tells the sender when and where the document was read. Links to local
  files open in Tovri, in Quick Look or as a folder; they never launch an app
  or a script. Web and email links open in your default browser or mail app.
- **Git.** Tovri reads the branch, file status, history and committed copies
  of files, and from the Changes list it can stage, unstage and discard
  changes, and switch branches, when you ask. It never commits, pushes or
  fetches. Before switching branches, Tovri checks that no file with
  uncommitted or unsaved changes, no untracked or ignored file, and no file
  that uses a filter would be replaced. A repository's
  own configuration can name programs for Git to run, so Tovri runs Git with
  hooks (including Git 2.54+ `hook.*` entries), `core.fsmonitor`,
  `submodule.recurse`, signature checking and every network transport turned
  off, every configured filter neutralized, subprocess output capped, and ref
  paths validated. Before opening or running Git on a folder, Tovri verifies
  that the current user (`geteuid()`) owns the repository root, `.git`
  entry, resolved git directory, and common directory; rejects `.git`
  symlinks and unbound standalone `gitdir:` pointers (including
  `--separate-git-dir` setups without worktree back-links); validates linked
  worktrees (`commondir` and `worktrees/<name>/gitdir`) and submodules
  (`core.worktree` inside an enclosing repository's `modules/`)
  bidirectionally; and pins canonical `--git-dir` and `--work-tree` paths on
  every Git call. These settings are passed in a way the repository can't
  override, and Tovri doesn't use Git versions older than 2.31, which ignore
  them. Files that use a filter, such as Git LFS, can't be staged or
  discarded in Tovri. Browsing a cloned folder doesn't run anything from its
  `.git` folder.
- **EditorConfig.** `.editorconfig` files only set indentation, whitespace
  and line endings. Their patterns are matched in linear time, so a hostile
  pattern can't freeze the app.
- **Quick Look.** Images, PDFs, media and documents are shown by macOS's
  Quick Look, not opened in their own apps.

## The `tovri` URL scheme and command

The `tovri` command line tool talks to the app through `tovri://` URLs. Any
web page or app can open such a URL, so the app acts only on request files
the command created for the current user in their temporary folder. Any
other `tovri://` URL just brings Tovri to the front; it can't open a path,
read piped text or wait on a file. Line and column numbers from a request are
clamped, so they can't crash the app.

Installing the command adds a link in `/opt/homebrew/bin` or
`/usr/local/bin`. When that folder needs administrator rights, Tovri copies
a `sudo` command for you to run yourself instead of asking for your password.

## Your files and unsaved work

- Tovri normally saves by writing a new copy and renaming it into place, so
  a failed write does not leave the original half-written. A file with other
  hard links, or in a folder Tovri can't add files to, is written in place
  instead. If an in-place save fails, Tovri attempts to restore the old
  contents, but that recovery can also fail and leave the file partially
  written. Read-only files are never replaced. File and CLI request reads
  verify a regular file on a single non-blocking (`O_NONBLOCK`) descriptor
  so FIFOs, devices, or swapped symlinks cannot hang the app. Tovri asks
  before overwriting a detected external change.
- Hot exit keeps unsaved changes in `~/Library/Application Support/Tovri`
  between launches. These files are readable only by your user account, but
  they are not encrypted, so they are as safe as the rest of your home
  folder. Turn hot exit off in **Settings → Files** if you edit secrets you
  don't want kept on disk.
- Local History keeps earlier versions of files you save over, and their
  original paths, only on your Mac, in
  `~/Library/Application Support/Tovri/History`, readable only by your user
  account. Turn it off in **Settings → Files** if you edit secrets you don't
  want copied. It is never uploaded or shared, and **File → Clear Local
  History…** deletes it. Discard Changes in the Changes list moves new files
  and a copy of changed files to the Trash before Git restores them.

## Network

Tovri has no accounts, no analytics and no telemetry. It contacts GitHub to
check for updates, and the Markdown preview loads remote images only when you
allow it. Nothing else leaves your Mac.

## Updates

Updates are delivered with [Sparkle](https://sparkle-project.org). Both the
update feed and every update archive are signed with an EdDSA key held only by
the release workflow, and the app refuses updates that fail either check.
Builds made without that key, such as your own builds and forks, never check
for updates.

Tovri is not notarized by Apple. Releases are built on GitHub Actions from
the tagged source, signed with the same self-signed certificate every time
and with the hardened runtime turned on, and `SHA256SUMS` is attached to
every release.

Every release file also has a signed
[build attestation](https://github.com/rahatsagor/Tovri/attestations). It
proves the file was built by this repository's release workflow, and from
which commit. To check a download, install the [GitHub CLI](https://cli.github.com)
and run:

```sh
gh attestation verify Tovri.dmg --repo rahatsagor/Tovri
```

An attestation shows where a file came from, not that the code is free of
bugs.
