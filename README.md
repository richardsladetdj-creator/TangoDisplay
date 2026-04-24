# TangoDisplay

A native macOS menu-bar app that shows a clean, fullscreen dancer display on an external monitor at milongas. It polls Music.app every 2 seconds, automatically detects cortinas, and shows track info — artist, title, genre, and tanda position.

![TangoDisplay in action](docs/screenshots/DisplayCoverImage.png)

---

## Features

- **Live track display** — artist, title, genre/label, and track counter (e.g. Track 2 of 4) on the dancer screen
- **Cortina detection** — configurable allowlist (cortina genres) and denylist (dance genres) with partial matching; shows a "CORTINA" overlay automatically
- **Coming-up preview** — displays the next tanda's genre and artist before it starts
- **Multi-monitor support** — sends the presentation window to any connected display; move and toggle fullscreen from the control window
- **Appearance profiles** — built-in (Classic, Modern, High Contrast) and unlimited custom profiles with per-field colors, fonts, and background image
- **Background image** — any image with opacity, scale, and pan controls
- **Transitions** — configurable fade style and duration between tracks
- **Global hotkeys** — `⌘⇧O` override, `⌘⇧P` pause display, `⌘⇧R` force-refresh, without switching windows
- **Mirror mode** — live preview of the presentation window in the control window
- **Display labels** — customisable "CORTINA", "COMING UP", and idle message text
- **Idle message** — optional text shown when nothing is playing
- **Player Source** — choose Music.app (default, full playlist lookahead and tanda counting), Swinsian (real-time notifications; no lookahead — tanda counting from history), or Embrace (real-time notifications + next-track lookahead via AppleScript; "Coming Up" preview during cortinas is supported)

---

## Requirements

| Requirement | Detail |
|---|---|
| macOS | 13 Ventura or later |
| Music.app | Required when using Music.app as the player source (default). Must be running and playing from a playlist. |
| Swinsian | Required only if selecting Swinsian as the player source in Settings › Player. |
| Embrace | Required only if selecting Embrace as the player source in Settings › Player. |
| Xcode Command Line Tools | `xcode-select --install` — no full Xcode needed |

---

## Installation

### Option A — Download pre-built app (easiest)

1. Go to the [Releases](https://github.com/richardsladetdj-creator/TangoDisplay/releases) page
2. Download `TangoDisplay-v1.4.0.zip`
3. Unzip and drag `TangoDisplay.app` to your `/Applications` folder
4. **Right-click › Open** on first launch (required because the app is ad-hoc signed, not notarised)
5. Grant the permissions macOS requests (see [Permissions](#permissions) below)

### Option B — Build from source

```bash
# Clone the repo
git clone https://github.com/richardsladetdj-creator/TangoDisplay.git
cd TangoDisplay

# Build, bundle, sign, and install to /Applications in one step
./Install.sh
```

`Install.sh` requires Xcode Command Line Tools (`xcode-select --install`). It will:
- Regenerate the app icon
- Build a release binary with `swift build -c release`
- Assemble `TangoDisplay.app` with a correct `Info.plist`
- Ad-hoc code-sign the bundle
- Install to `/Applications` and launch the app

---

## Permissions

On first launch macOS will prompt for two permissions:

| Permission | Why it's needed |
|---|---|
| **Automation › Music** | TangoDisplay reads the currently playing track, artist, genre, playlist position, and upcoming tracks via AppleScript |
| **Input Monitoring** | Required for the global hotkeys (`⌘⇧O`, `⌘⇧P`, `⌘⇧R`) to work while other apps are in focus. Grant in **System Settings › Privacy & Security › Input Monitoring** |

> Global hotkeys silently do nothing if Input Monitoring is denied — everything else works fine without it.

---

## Quick Start

1. Start Music.app and play a playlist
2. Launch TangoDisplay — a small display icon appears in the menu bar
3. Click the menu bar icon › **Show Settings Window**
4. Go to **Display** and select your external monitor as the target display
5. Click **Move Presentation Window** then **Toggle Fullscreen**
6. The dancer display is live — go to **Appearance** to customise colors, fonts, and background

See the **[Wiki](https://github.com/richardsladetdj-creator/TangoDisplay/wiki)** for a full user guide with screenshots.

---

## Building and Testing

```bash
# Debug build
swift build

# Run all tests (39 tests, custom runner — no Xcode needed)
swift run TangoDisplayTests

# Full release build → /Applications (same as install)
./Install.sh
```

---

## Architecture

The project has three SPM targets with no external dependencies:

| Target | Type | Purpose |
|---|---|---|
| `TangoDisplayCore` | Library | Pure logic — cortina detection, tanda tracking, models. No AppKit/SwiftUI. |
| `TangoDisplay` | Executable | SwiftUI app — UI, AppleScript bridge, polling, settings, window management |
| `TangoDisplayTests` | Executable | Lightweight custom test runner (`swift run TangoDisplayTests`) |

Key design decisions:
- `NSAppleScript` runs on a dedicated background serial queue (avoids blocking the main thread)
- Playlist lookahead is fetched on every cortina transition (for accurate "Coming Up" info) and also refreshed every 20 seconds (every 10th 2s poll)
- Profiles are stored as JSON in `~/Library/Application Support/TangoDisplay/profiles/`
- Colors are stored as hex strings in `AppearanceProfile` (Codable)
- `ObservableObject` + `@Published` throughout (macOS 13 target predates `@Observable`)

---

## Changelog

### v1.4.0
- **New (Embrace):** Embrace now supports next-track look-ahead via AppleScript — the "Coming Up" upcoming tanda preview is shown during cortinas, matching Music.app behaviour. Full playlist enumeration is still unavailable (no setlist API), so tanda counting continues to use track history.

### v1.3.1
- **Reliability:** Music.app now subscribes to the `com.apple.Music.playerInfo` DistributedNotification, triggering an immediate poll on every track and state change — mirroring how Embrace support works. This eliminates detection delays that could occur when the watchdog had backed off the polling interval due to transient AppleScript failures. The 2-second fallback polling and watchdog backoff are unchanged.

### v1.3.0
- **Fix:** Unpausing the display no longer leaves it frozen when the player state changed while the display was paused. The dedup guard is now reset on unpause and an immediate poll is triggered, so the display snaps to the real current player state without waiting for the next scheduled poll.
- **Fix:** Pressing "Pause Display" while the player is paused (not the display) no longer silently engages user-level display-freeze, causing the display to stay stuck when music resumes.
- **Fix:** Player stop now clears the user-pause flag, so restarting music after a stop always updates the display correctly.
- **New:** Status bar now shows two independent badges — **player state** (Playing / Player Paused / Idle) and **display state** (Display Live / Display Paused / Cortina / Override) — so the state of each is always visible at a glance.

### v1.2.0
- **New:** Embrace is now supported as a player source. Select Music.app, Swinsian, or Embrace in **Settings › Player**. Embrace uses a hybrid push/poll strategy — real-time notifications plus AppleScript polling for reliability. Note: playlist lookahead and the "Coming Up" preview during cortinas are unavailable with Embrace — tanda counting falls back to track history.

### v1.1.0
- **New:** Swinsian is now supported as an alternative player source. Select Music.app or Swinsian in **Settings › Player**. Swinsian uses real-time push notifications instead of polling. Note: playlist lookahead and the "Coming Up" next-tanda preview during cortinas are unavailable with Swinsian — tanda counting falls back to track history.

### v1.0.3
- **Fix:** Display labels ("CORTINA", "COMING UP", idle message) now update immediately on the presentation window when saved, instead of requiring a restart. Edited via the Display tab with a **Save** button and an unsaved-changes indicator.

### v1.0.2
- **Bug fix:** "Coming Up" next-tanda artist on the cortina screen now refreshes on every cortina transition instead of waiting up to 20 seconds. If the user switches playlists while a cortina is playing, the stale next-artist preview is cleared immediately when the fresh playlist data arrives, falling back to a plain "CORTINA" display.

### v1.0.1
- **Bug fix:** Clearing an override no longer inherits a user-pause that was active before the override was triggered. `isPausedByUser` and `pendingStateBeforePause` are now reset in `clearOverride()`.

### v1.0
- Initial release.

---

## License

MIT — see [LICENSE](LICENSE).
