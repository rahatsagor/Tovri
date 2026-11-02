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
  allows only Tovri's own script, so scripts, forms and frames in a Markdown
  file never run. From disk it can read only image and media files, and
  only small ones, up to 256 MB per preview. Remote images and media are
  blocked until you click **Load Remote Images** in the bar above the preview
  (which the document can't draw or click itself) or allow them in
  **Settings → Files**, because loading them tells the sender when and where
  the document was read. Links to local files open in Tovri, in Quick Look or
  as a folder; they never launch an app or a script. Web and email links open
  in your default browser or mail app.
- **Git.** Tovri only reads from Git: the branch, file status, history and
  committed copies of files. It never commits, checks out or fetches. A
  repository's own configuration can name programs for Git to run, so Tovri
  runs Git with hooks, `core.fsmonitor`, signature checking and every network
  transport turned off, every configured filter neutralized, and the work tree
  pinned to the repository's folder. These settings are passed in a way the
  repository can't override, and Tovri doesn't use Git versions older
  than 2.31, which ignore them. Browsing a cloned folder doesn't run
  anything from its
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

- Saving writes a new copy and then replaces the file, so a failed save never
  leaves a half-written file. Read-only files are never replaced, and a file
  changed by another app since Tovri read it asks before it's overwritten.
- Hot exit keeps unsaved changes in `~/Library/Application Support/Tovri`
  between launches. These files are readable only by your user account, but
  they are not encrypted, so they are as safe as the rest of your home
  folder. Turn hot exit off in **Settings → Files** if you edit secrets you
  don't want kept on disk.

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
