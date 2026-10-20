# Limelight

A launcher and file finder for macOS, built to replace Spotlight.

Spotlight's results come from `mds`, the metadata indexer. When that index stalls, gets corrupted, or skips a folder, apps and files go missing and nothing tells you why. Limelight keeps its own index of file names in memory and does not use `mds` for anything:

- **Files and folders:** crawls your home folder and iCloud Drive at launch (about 725k items in 6–7 s on this Mac). FSEvents then keeps it current within about a second. If the kernel drops events, the affected folder is re-crawled.
- **Apps:** read straight from `/Applications`, `/System/Applications`, `~/Applications` and the folders inside them (Utilities, Chrome Apps, vendor folders), and rescanned when those change.
- **System Settings panes:** opened directly by their extension identifier, and findable by what they control. For example, "dark mode" finds Appearance and "full disk access" finds Privacy & Security.
- **Calculator and unit conversion:** `12*3.5+2`, `20% of 150`, `50 + 10%`, `sqrt(2)`, `0xff`, `5 km to mi`, `100f in c`, `2 cups to ml`, `1 gib in mb`. Return copies the answer.
- **Paths:** type `~/` or `/` to browse a folder live. Tab steps into the selected folder.
- **Learning:** whatever you open after typing a query ranks higher next time for that query and its prefixes. Weights halve every two weeks.

A search over the full index takes 7–15 ms.

## Install

```bash
./scripts/build-app.sh --install
```

This builds a release binary, wraps it as `Limelight.app`, signs it ad hoc, copies it to `~/Applications` and launches it. Limelight lives in the menu bar and has no Dock icon.

On first run, macOS asks whether Limelight may access Desktop, Documents and Downloads. Allow these, or those folders won't be searchable. Because the app is signed ad hoc, each rebuild asks again.

## Shortcut

On first launch Limelight takes ⌘Space if Spotlight has released it. Otherwise it uses ⌥Space, then ⌃Space. To move it to ⌘Space:

1. Open System Settings → Keyboard → Keyboard Shortcuts → Spotlight and turn off "Show Spotlight search".
2. In Limelight Settings, click **Use ⌘Space**.

Settings shows a warning while Spotlight still owns the combination.

## Keys

| Key | Action |
| --- | --- |
| ↑ ↓, ⌃P ⌃N | Move selection |
| Return | Open (calculator: copy the answer) |
| ⌘Return | Show in Finder |
| ⌘1 – ⌘9 | Open that row |
| ⌘C | Copy the path, or the answer |
| Tab | Complete; on a folder, browse into it |
| Esc | Clear the query, then close |
| ⌘, | Settings |

You can also drag a result into another app.

## Settings

Shortcut, open at login, web search engine, which folders are searched, which are skipped, and whether hidden files count. `~/Library`, `node_modules`, `__pycache__`, `site-packages`, `DerivedData`, `Pods`, `venv` and any `*.noindex` folder are skipped. Files inside build, cache and vendor folders stay searchable but rank lower.

## What it doesn't do

- **No file contents:** it searches names and folder paths, not text inside documents.
- **No currency conversion:** that needs a network rate source.
- **No Quick Look preview.**

## Layout

```
Sources/LimelightCore    index, matcher, ranking, calculator, catalog (no UI, fully tested)
Sources/Limelight        menu bar app: hotkey, panel, settings
Sources/limelight-cli    builds the same index in a terminal and runs queries, with timings
Tests/LimelightCoreTests
scripts/                 build-app.sh, make-icon.swift, snapshot.sh
```

Build output goes to `~/Library/Caches/Limelight-build`, because the attributes Desktop sync adds to files make `codesign` fail.

```bash
swift test --scratch-path ~/Library/Caches/Limelight-build
swift run --scratch-path ~/Library/Caches/Limelight-build -c release limelight-cli "query" "another query"
scripts/snapshot.sh "query" out.png   # renders the panel for a query to a PNG
```
