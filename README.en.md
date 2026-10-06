<p align="center">
  <img src="FileRenamer-iOS-Default-1024x1024@1x.png" width="160" height="160" alt="FileRenamer app icon">
</p>

<h1 align="center">FileRenamer</h1>

<p align="center">
  <strong>Arrange them. Rename them all at once.</strong><br>
  A Mac app for batch-renaming photos and documents — with every result checked before anything changes.
</p>

<p align="center">
  <a href="https://github.com/hirakke/FileRenamer/releases/latest"><strong>Download the DMG</strong></a>
  ·
  <a href="https://apps.apple.com/us/app/filerenamer/id6800803707?mt=12"><strong>Get it on the Mac App Store</strong></a>
  ·
  <a href="README.md">日本語</a>
</p>

<p align="center">
  <img src="Documentation/Images/icon-view.png" width="860" alt="FileRenamer icon view showing photos with their original and new names">
</p>

```text
DSC_1842.jpg  →  20260820_Event_001.jpg
IMG_2941.jpg  →  20260820_Event_002.jpg
DSC_2186.jpg  →  20260820_Event_003.jpg
```

Add files with messy names, put them in order, and choose a naming rule. The new names appear in the list as you go, and one click applies them to every file.

## Features

### Your order becomes the numbering

Sort by capture date, creation date, modification date, name, or size, then fine-tune individual files by dragging or with `⌘↑` / `⌘↓`. Counters run `001`, `002`, … from the top of the list, and the new names update the moment you change the order.

### Naming rules made of blocks

Type fixed text directly and insert blocks only for the parts that change per file. Save rules you use often as presets.

| Block | What it inserts | Example |
| --- | --- | --- |
| Date | Capture, creation, or modification date (or type a format such as `YYYYMMDD` with **Date (Custom Format)…**) | `20260820` |
| Counter | Position in the list (digits, start number, reset per date or folder) | `001` |
| Original Name | The original file name, optionally upper- or lowercased | `DSC_1842` |
| Photo Info | Camera, lens, ISO, and other EXIF data | `ISO800` |

### Every result checked before you rename

Duplicate names, files already at the destination, characters that can't be used, and names that are too long are flagged as errors before anything runs. FileRenamer never renames with errors present and never overwrites existing files.

### Gather files from many folders into one

Files added from different folders can be moved into one folder as part of the same rename. Choose **Move to Folder…** from the ▾ next to the rename button and pick the destination (create a new folder with the **New Folder** button in the chooser). Choose **Rename in Place** to keep files where they are. Name clashes in the destination are reported before anything moves.

### See your photos while you work

Icon view shows thumbnails alongside the original and new names, in two to eight columns. Double-click or press Space to open images, PDFs, and videos in Quick Look. Dark Mode is fully supported.

### Convert and resize in the same step

Convert JPEG, PNG, and HEIC images to JPEG or PNG and resize them by their longest edge while renaming. Keep the originals in a separate folder, or replace them after confirmation.

### Find similar images

FileRenamer points out identical images and visually similar ones, such as burst shots. Analysis stays on your Mac, and nothing is deleted or excluded automatically — only files you choose in the review sheet go to the Trash.

### Undo anytime

Undo the last rename with `⌥⌘Z` and redo it with `⇧⌥⌘Z`. History is kept even after you quit the app.

### And more

- A tutorial on first launch (show it again anytime from **Help → Show Tutorial Again**)
- Work on several naming jobs at once in tabs (`⌘T`)
- Keep RAW + JPEG pairs together under the same name
- Japanese and English interface, or follow the system language
- Everything happens on your Mac — no files or usage data are sent anywhere

## Download

| Where | Details |
| --- | --- |
| [GitHub Releases (DMG)](https://github.com/hirakke/FileRenamer/releases/latest) | Notarized by Apple, with in-app update checks |
| [Mac App Store](https://apps.apple.com/us/app/filerenamer/id6800803707?mt=12) | Installed and updated through the App Store |

**Requirements:** macOS 14.0 or later (Apple silicon and Intel)

For the DMG, open it, drag `FileRenamer` to `Applications`, and launch it from there.

## How to Use

1. **Add files.** Click **Add Files** or **Add Folder** in the toolbar, or drop files from Finder onto the window.
2. **Arrange the order.** Pick a sort order from the Sort menu, then drag to adjust if needed.
3. **Make a naming rule.** Choose a preset, or type text and use **Insert Block** for the parts that vary.
4. **Review.** Check the new names in the list. Green means ready, orange is worth a look, and red must be fixed.
5. **Rename.** Click **Rename N Items** at the bottom right and confirm. To gather the files into one folder, choose **Move to Folder…** from ▾ first.

macOS asks for folder access only for locations that need it, such as external drives.

## Keyboard Shortcuts

| Action | Shortcut |
| --- | --- |
| New tab | `⌘T` |
| Add files / folder | `⌘O` / `⇧⌘O` |
| Rename | `⌘↩` |
| Quick Look | `Space` |
| Move selection earlier / later | `⌘↑` / `⌘↓` |
| Move selection to start / end | `⌥⌘↑` / `⌥⌘↓` |
| Lock / unlock position | `⌘L` |
| Remove from list | `Delete` |
| Undo / redo an order change | `⌘Z` / `⇧⌘Z` |
| Undo / redo the last rename | `⌥⌘Z` / `⇧⌥⌘Z` |

## FAQ

### Can I rename files other than photos?

Yes — PDFs, videos, audio, Office documents, and more. Image conversion and resizing work on JPEG, PNG, and HEIC/HEIF; RAW files support renaming and photo-info blocks.

### Does adding files change them?

No. Files change only after you click the rename button and confirm.

### What if two files would get the same name?

It's shown as an error before anything runs. Existing files are never silently overwritten.

### Are similar images deleted?

Never automatically. Only files you explicitly choose are moved to the Finder Trash. You can turn detection off in **FileRenamer → Settings…**.

### How do I get updates?

The DMG version checks via **FileRenamer → Check for Updates…**, and automatic checks can be turned on in Settings. The App Store version updates through the App Store.

## Built to Be Safe

Renaming is hard to take back, so FileRenamer is designed above all to get you back to where you started if something goes wrong.

- **Two-phase renaming.** Every file first moves to a temporary name, then to its final name, so swaps like `A↔B` and case-only changes are safe.
- **Rollback on failure.** If an error occurs mid-run, completed changes are reversed in order. If some files can't be restored, that state is kept in history so Undo can restore them later.
- **Crash recovery.** Progress is journaled file by file, so if the app or your Mac stops mid-run, the original names are restored on the next launch.
- **Image backups.** Before converting or resizing, the original data and metadata are set aside.
- **Name variants count as clashes.** Like the standard macOS file system, differences in case and Unicode normalization (NFC/NFD) are treated as the same name.
- **Renaming doesn't touch contents.** A plain rename never reads or writes file data — only the name changes.
- **Stays on your Mac.** No files, images, names, or usage data leave your Mac. The DMG update check only asks whether a newer version exists.

## Privacy and Support

- [Privacy Policy](https://hirakke.github.io/FileRenamer/privacy.html)
- [Report a problem or ask a question](https://github.com/hirakke/FileRenamer/issues)
- [Release notes](https://hirakke.github.io/FileRenamer/release-notes.html) · [All releases](https://github.com/hirakke/FileRenamer/releases)

---

Copyright © 2026 Keiju Hiramoto. All rights reserved.
