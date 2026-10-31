# Contributing

Thanks for helping. Tovri takes bug reports and ideas as
[issues](https://github.com/rahatsagor/Tovri/issues/new/choose), and pull
requests are welcome too. For anything bigger than a small fix, open an issue
first so we can agree on the approach before you spend time on it.

The most useful reports include:

- what you did, what you expected and what happened instead,
- the Tovri version (**Tovri → About Tovri**), the Mac and its macOS version,
- the kind of file (language, roughly how large), and whether the folder is a
  Git repository,
- a small file that shows the problem, if you can share one.

Report security problems privately, as described in [SECURITY.md](SECURITY.md).

## Setup

- macOS 14 or later on Apple silicon
- Xcode 16 or later. Tovri is a Swift package; there is no Xcode project.
- [Bun](https://bun.sh), only for the release tooling in `scripts/`

CI and releases use the newest stable Xcode installed on GitHub's `xcode-27`
image. That runner image is currently in public preview; beta Xcode compilers
are excluded. Swift dependencies are pinned in `Package.resolved`, and the
release tooling uses the committed `scripts/bun.lock`. Action code is pinned
to verified commits, with Dependabot proposing updates weekly.

```sh
make debug        # build/Debug/Tovri.app
make              # build/Release/Tovri.app
make run          # build the release app and open it
make test         # swift test
make package      # dist/Tovri-<version>.dmg and .zip
```

The Makefile calls `scripts/build.sh`, which takes `--debug` and
`--version 1.2.3`. You can also open `Package.swift` in Xcode to edit and run
the tests there.

Debug builds and builds without an update key never check for updates, so a
copy you built can't replace itself with a release.

### Signing your builds

macOS remembers privacy permissions, such as access to your Desktop,
Documents or removable volumes, by the app's code signature. Without a
signing identity the build script signs ad-hoc, which works but changes with
every build, so macOS asks again each time. Create a local self-signed
identity once and the build script uses it automatically:

```sh
scripts/make-signing-identity.sh
```

Set `TOVRI_SIGN_IDENTITY` to use a different identity from your keychain, or
to `-` to force ad-hoc signing.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/Tovri/` | The app (AppKit, with SwiftUI for Settings). |
| `Tests/TovriTests/` | Unit and regression tests, run with `swift test`. |
| `Resources/` | `Info.plist`, entitlements, and the app icon with its editable SVG artwork. |
| `scripts/` | Build, signing, packaging and release tooling, and `tovri`, the command line launcher shipped inside the app. |
| `packaging/` | The Homebrew cask template and files that go into the DMG. |

## Architecture

```text
Sources/Tovri
├── App/        app delegate, main menu, updater, entry point
├── Core/       document model, line index, encodings, settings, session, fuzzy matcher,
│               project index, Git, FSEvents watcher
├── Syntax/     language model, 128 language definitions, lexers, incremental engine, themes
├── Editor/     text view (multi-cursor, commands), layout manager, colorizer, gutter,
│               minimap, folding, find bar, completion, Markdown preview
├── Window/     window controller, tab bar, editor groups, sidebar, palette, status bar,
│               Find in Files, Quick Look
└── Settings/   SwiftUI settings window
```

- **Text system:** TextKit 1 (`NSLayoutManager`) with non-contiguous layout, a
  uniform line height and temporary attributes for syntax colors. Colors never
  touch the text storage, so highlighting causes no relayout and no undo
  noise, and several views of one document color independently.
- **Syntax engine:** the lexer state at the start of every line is cached.
  After an edit, re-lexing starts at the edited line and stops when the new
  state matches the old one, so the rest of the file stays valid. Lines are
  lexed on demand for the visible region only.
- **Documents:** files are memory-mapped and decoded once. A line-start index
  is updated incrementally on every edit, which keeps line lookups O(log n)
  for the gutter, Goto Line and the syntax engine.
- **Markdown preview:** the only web view in the app, created when a preview
  is first opened. A strict Content-Security-Policy allows only Tovri's own
  script, and local images are served from disk by a URL scheme handler.
- **Updates:** [Sparkle](https://sparkle-project.org), added with SwiftPM.
  `scripts/build.sh` embeds and signs `Sparkle.framework` and writes the
  update key into the app's `Info.plist`.

Set `TOVRI_PERF=1` to log timings for loading, coloring, searching and
main-thread stalls over 50 ms:

```sh
open --env TOVRI_PERF=1 --stderr /tmp/tovri.log -a build/Release/Tovri.app
```

## Checks

CI runs all of these on pushes to `main` and on pull requests.

```sh
swift test
scripts/build.sh              # a signed, verified release app

cd scripts                    # release tooling, on Bun
bun install
bun run lint
bun run typecheck
bun run test

actionlint                    # workflows, if you changed .github/
```

## Pull requests

- Keep each pull request to one change, and describe what it fixes or adds
  and how you checked it.
- Add a test for a fix when you can. The tests in `Tests/TovriTests` show how
  to drive documents, the editor and sessions without a window.
- Try the change in a release build too (`make run`). Tovri's speed on large
  files is a feature, so check that typing, scrolling and searching stay
  smooth in a big file.
- Match the style of the surrounding code. Add a comment only when the reason
  behind the code isn't obvious from the code itself, such as a hidden
  constraint or a workaround for a macOS bug.
- Add user-facing changes to the `Unreleased` section of `CHANGELOG.md`, in
  plain words for the people using the app.
- CI must pass before a pull request is merged.

## Guidelines

- **Never lose someone's work.** Saving, reloading, hot exit and session
  restore protect unsaved edits and the file on disk. Changes to them need
  tests for the failure cases, not only the happy path.
- **Treat every file and folder as untrusted.** Opening a file, previewing it
  or showing a repository's status must never run code from it. See
  [SECURITY.md](SECURITY.md).
- **Stay light.** Prefer AppKit and the macOS text system over new
  dependencies, and don't add work to launch or file opening.
- **Write for the person using the app.** Messages say what happened and what
  to do next, without jargon.

Tagged releases run the same CI checks before building and packaging the
app. Publishing requires matching Sparkle keys and the permanent code signing
identity configured in GitHub Actions; local builds and forks do not need
release secrets. Downloads become public only after the draft release has all
its files.

By contributing, you agree that your contributions are released under the
[GNU Affero General Public License v3.0](LICENSE), like the rest of Tovri.
