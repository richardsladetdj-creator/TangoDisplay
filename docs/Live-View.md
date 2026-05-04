# Live View

The control window is the central hub for TangoDisplay. It uses a sidebar for navigation with three sections:

**Live**
- **Live** — Status, preview, and quick-action buttons (this page)
- **Setlist** — Built-in player queue and playback controls ([Built-In Player](Built-In-Player))

**Settings**
- **Cortina Rules** — Automatic cortina detection ([Cortina Rules](Cortina-Rules))
- **Appearance** — Colors, fonts, and transitions ([Appearance](Appearance))
- **Display** — Monitor and label settings ([Display Settings](Display-Settings))
- **Player** — Player source selection and built-in player settings ([Built-In Player](Built-In-Player))

**Profiles**
- **Profiles** — Saved appearance profiles ([Profiles](Profiles))

> The **Setlist** item is only active when Built-in Player is selected as the player source. Selecting it while using another source shows a prompt to switch.

---

The **Live** page shows what is currently playing, a live preview of the dancer display, and quick-action buttons.

![Live view](https://raw.githubusercontent.com/richardsladetdj-creator/TangoDisplay/main/docs/screenshots/live-view.png)

---

## Status indicators

At the bottom of the preview area:

| Indicator | Meaning |
|---|---|
| **Playing** (green) | A track is currently playing |
| **Polling OK** (green) | TangoDisplay successfully read track data on the last poll |
| **Paused** | The display is manually paused (dancer screen is frozen) |

> When using the Built-in Player, status reflects local playback state rather than Music.app polling. The "Polling OK" indicator is not shown in this mode.

---

## Action buttons

| Button | Shortcut | What it does |
|---|---|---|
| **Force Poll** | `⌘⇧R` | Immediately triggers a Music.app re-read, bypassing the normal notification/fallback-poll cycle |
| **Override…** | `⌘⇧O` | Opens a dialog to manually set what text appears on the display |
| **Pause Display** | `⌘⇧P` | Freezes the dancer screen; pressing again resumes live updates |

All three shortcuts work globally — you don't need to switch to TangoDisplay first.

---

## Track info panel

Below the buttons, TangoDisplay shows the currently detected values:

- **Title** — track name (may include vocalist in parentheses)
- **Artist** — orchestra / artist name
- **Genre** — the genre tag from Music.app
- **Tanda** — position within the current tanda, e.g. "Track 1 of 4"

---

## Debug log

The **Debug Log** disclosure item at the bottom expands to show recent polling events, AppleScript results, and cortina detection decisions. Useful for troubleshooting unexpected behaviour.
