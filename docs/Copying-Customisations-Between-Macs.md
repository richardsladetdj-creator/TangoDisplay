# Copying Your Customisations to a Second Mac

You can copy everything you've set up in TangoDisplay — appearance settings, display profiles, background and artist images, and plugin presets — from one Mac to another. Handy when you build your set on one Mac and play live on another.

TangoDisplay keeps all of this in **two places**. Copy both to the second Mac and it looks and behaves identically. There's no cloud sync, so this is done by hand — but it's quick.

> **Before you start:** Install the same version of TangoDisplay on both Macs, and **quit TangoDisplay on both** before copying anything.

---

## What gets copied

| You keep | Where it lives |
|----------|----------------|
| All settings (appearance, display, cortina rules, startup, advanced) | A preferences file |
| Display profiles | The TangoDisplay support folder |
| Background & artist images | The TangoDisplay support folder |
| Plugin presets and chains | The TangoDisplay support folder |
| Your current playlist *(optional)* | The TangoDisplay support folder |

Just **two things** to copy — a settings file and a folder.

---

## Step 1 — Quit TangoDisplay on both Macs

Right-click the TangoDisplay icon in the Dock and choose **Quit**, or press **⌘Q** with the app in front. Make sure it isn't running on either Mac.

*(This matters — macOS keeps settings in memory while the app runs, and can overwrite your copy if the app is open.)*

---

## Step 2 — Find the two items on your first Mac

They live in your hidden **Library** folder. To open it:

1. In **Finder**, click the **Go** menu in the menu bar.
2. Hold down the **Option (⌥)** key — a **Library** entry appears. Click it.

Find these two items:

1. **The settings file** — `Library › Preferences › com.local.tangodisplay.plist`
2. **The support folder** — `Library › Application Support › TangoDisplay`

> Faster route: Finder's **Go › Go to Folder…** (**⌘⇧G**), then paste `~/Library/Application Support/` or `~/Library/Preferences/`

---

## Step 3 — Send them to the second Mac

Easiest between two Macs is **AirDrop**:

1. Select both the `com.local.tangodisplay.plist` file and the `TangoDisplay` folder.
2. Right-click → **Share › AirDrop**, pick your second Mac.

No AirDrop? A USB stick, shared folder, or any cloud drive works just as well — copy both items across.

---

## Step 4 — Put them in place on the second Mac

On the second Mac, open **Library** the same way (**Go** menu + **Option**), then:

1. Put `com.local.tangodisplay.plist` into `Library › Preferences` *(replace the existing one if asked).*
2. Put the `TangoDisplay` folder into `Library › Application Support` *(replace if asked — or drag the old one to the Desktop first as a backup).*

---

## Step 5 — Restart the second Mac

**Restart the Mac** (Apple menu → **Restart**) before opening TangoDisplay.

Important: macOS remembers the old settings until it restarts, so skipping this can make your copied settings appear to "not take."

Open TangoDisplay — your profiles, appearance, images, and plugin presets should all be there.

---

## A note about your playlist and music files

If you also copied `setlist.json` (your current playlist), the tracks point to the **exact location of your music files**. It plays perfectly if the second Mac:

- uses the **same macOS account name**, and
- has the **same music files in the same folders**.

If your music lives elsewhere on the live Mac, the settings still transfer fine — you may just need to re-add or re-link the tracks in the playlist.

---

## Doing it again later

Whenever you change your setup on the first Mac, repeat Steps 1–5. Only the **two items** ever need copying.

---

## Quick version (for the technically confident)

With TangoDisplay quit on both Macs, copy these to the same paths on the second Mac:

```
~/Library/Preferences/com.local.tangodisplay.plist
~/Library/Application Support/TangoDisplay/
```

Then on that Mac run `killall cfprefsd` (or just restart) so macOS reloads the preferences.
