# AGENTS.md

Notes for AI coding agents (and people) working on this repo. See README.md for what the app does.

## Setup

- macOS 14.4 or later, with the Xcode Command Line Tools. Full Xcode is not needed.
- `brew install media-control`. The build copies its Now Playing helper into the app.
- Optional, for Sync words: a Python 3.12 venv at `~/Library/Application Support/Yues Yinyue/sync-env` with `torch torchaudio demucs soundfile` (see README).

## Build and run

```sh
swift build                 # debug build, quick compile check
./build-app.sh              # release build, bundles and installs ~/Applications/Yue's 音乐.app
```

There is no Xcode project. `Package.swift` defines one executable target, `YuesYinyue`, and `build-app.sh` packs it into a `.app` with an ad-hoc signature.

## Checking changes without the UI

The binary has developer modes that print or render and then exit:

```sh
.build/debug/YuesYinyue --test "晴天" "周杰伦" 269          # lyrics search + pinyin for a song
.build/debug/YuesYinyue --qishui <share link or track id>    # 汽水音乐 share-link import
.build/debug/YuesYinyue --snapshot home build/snaps/home.png # draw the dashboard to a PNG
```

`--snapshot` takes `home`, `now`, `songs`, `custom` or `settings`. Environment variables: `YY_SNAP_W` / `YY_SNAP_H` set the window size, `YY_FORCE_NOTFOUND=1` shows the no-lyrics state, and `YY_DEBUG_POPUP=album|song|new` opens a menu or dialog first. Look at the PNG to check layout changes, especially at the 900 pt minimum width.

## Where things are (`Sources/YuesYinyue`)

- `App.swift`: app entry, menu bar item, windows, developer modes
- `AppModel.swift`: what's playing → saved or found lyrics → what's shown; Sync words scheduling
- `NowPlaying.swift`: reads macOS Now Playing through mediaremote-adapter; play/pause/skip/seek/speed
- `LyricsService.swift` + `NetEaseSource.swift` + `LRCLIBSource.swift` + `Qishui.swift`: lyric sources, one per file
- `LyricsParser.swift`: LRC, enhanced LRC, NetEase YRC, 汽水音乐 KRC, plain text
- `Pinyin.swift`: pinyin-pro in JavaScriptCore, per-line overrides
- `Karaoke.swift`, `LyricsStage.swift`: fill timing and the animated lyrics view
- `Overlay.swift`: the floating island, its controls and the turntable
- `Dashboard.swift`, `LibraryView.swift`, `Popups.swift`: the dashboard window, its pages, menus and dialogs
- `Library.swift`: saved songs (JSON), album art, albums
- `Listen.swift`, `WordSync.swift`, `Resources/Sync/align.py`: audio capture, speech recognition, Sync words
- `Settings.swift`: user settings and the curated themes

## Conventions

- Use `@Local` (in `Local.swift`) instead of `@State`. In the macOS 27 SDK `@State` is a macro whose plugin only ships with full Xcode.
- Menus and dialogs are drawn by `PopupHost` in the app's theme. Don't add system `Menu`, `.sheet`, `.confirmationDialog` or `.contextMenu` to the dashboard.
- Colors come from the current `Theme`. Don't add free color pickers.
- Keep layouts working at the 900 × 620 minimum window size.
- A new lyric source goes in its own file as an `extension LyricsService`, so any source can be removed on its own.
- Comments explain why the code does something, in plain words.

## Rules

- Never commit lyrics, album art or other copyrighted content. Saved songs live in `~/Library/Application Support/Yues Yinyue/`, outside the repo.
- Don't decrypt or download songs' audio. The app only reads what's playing on the user's own Mac.
- When adding or updating third-party code or models, update `THIRD_PARTY_NOTICES.md`.
- Don't put personal information, secrets or API keys in the code.
