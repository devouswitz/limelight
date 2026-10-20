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
| ⌘↑ ⌘↓ | Previous / next section |
| Return | Open (calculator, definition, clipboard: copy) |
| ⌘Return, ⌘R | Show in Finder |
| ⌘Y | Quick Look |
| ⌘C | Copy the path, or the answer |
| ⌘B | Search the web for the query |
| ⌘1 ⌘2 ⌘3 ⌘4 | Applications, Files, Actions, Clipboard (again to go back) |
| Tab, → | Accept the completion; on a folder, browse into it |
| Esc | Clear the query, leave the mode, then close |
| ⌘, | Settings |

Double-click opens a result, and you can drag results into other apps. To move the panel, drag any empty part of it, such as the search icon, the margins or the preview. It stays where you leave it, on every display. **Reset Panel Position** in the menu bar puts it back.

## The panel

Results are grouped like Spotlight's: a Top Hit, then Applications, System Settings, Actions, Folders and Documents, ordered by their best match, with web search last. The right side previews the selection: a Quick Look preview for documents, and version and last-opened date for apps. Calculations, definitions and clipboard entries are shown in full. Gray text after the cursor finishes the top hit's name.

- **Applications (⌘1):** every app, alphabetically, filtered as you type.
- **Files (⌘2):** files only, with recently modified files shown before you type.
- **Actions (⌘3):** Lock Screen, Sleep, Turn Off Display, Screen Saver, Toggle Dark Mode, Show Trash, Restart, Shut Down and Log Out, plus every shortcut in the Shortcuts app.
- **Clipboard (⌘4):** text and files you copied in the last 8 hours. It is held in memory only and skips anything a password manager marks as concealed. You can turn it off in Settings.

Typing a word also looks it up in the Dictionary app's local dictionaries.

## How ranking works

Each result gets a score:

1. **How well the name matches.** From best to worst: exact name, exact name without its extension, prefix ("saf" → Safari), start of a word ("code" → Visual Studio Code), word initials ("vsc"), anywhere in the name, and, for apps only, one typo ("chorme") or scattered letters. Within each tier, a match covering more of the name scores higher. Multi-word queries can match folder names too, so "lifting models" finds `Models.swift` inside a `Lifting` folder.
2. **What kind of thing it is.** Apps get the largest boost, then System Settings panes, then actions, so an app beats a file with the same name.
3. **How recent it is.** Apps gain points for being opened recently and, by less, for being installed, updated or built recently. Open apps get a little extra. Files gain points for recent changes. These bonuses shrink smoothly with age, so two equal matches always list the newer one first.
4. **What you've picked before.** Opening a result after typing something boosts it for that query and its prefixes, plus a smaller general bonus for things you open often. All of it halves every two weeks.
5. **Penalties.** Files deep in the folder tree, or inside build, cache or vendor folders, rank lower.

An app's last-opened date comes from the preferences and saved-window files every app rewrites when it runs, so Limelight knows about apps you launch from the Dock too.

## Settings

Shortcut, open at login, web search engine, which folders are searched, which are skipped, and whether hidden files count. `~/Library`, `node_modules`, `__pycache__`, `site-packages`, `DerivedData`, `Pods`, `venv` and any `*.noindex` folder are skipped. Files inside build, cache and vendor folders stay searchable but rank lower.

## What it doesn't do

- **No file contents:** it searches names and folder paths, not text inside documents.
- **No currency conversion:** that needs a network rate source.

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
LIMELIGHT_PROMO=$PWD/promo/limelight-promo.mp4 ~/Applications/Limelight.app/Contents/MacOS/Limelight   # renders the promo video
```

The promo video is `promo/limelight-promo.mp4`. The app renders it from its own panel, driving a scripted session over sample files and sample clipboard entries. The frosted backdrop is composited, because the real glass is drawn by the window server.

Free and open source under the MIT license.
