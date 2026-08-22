<p align="center">
  <img src="FileRenamer-iOS-Default-1024x1024@1x.png" width="192" height="192" alt="FileRenamer app icon">
</p>

<h1 align="center">FileRenamer</h1>

<p align="center">A Mac app for batch-renaming files in the order you arrange them.</p>

<p align="center">
  <a href="https://github.com/hirakke/FileRenamer/releases/latest"><strong>Download the latest version</strong></a>
  ·
  <a href="https://apps.apple.com/us/app/filerenamer/id6800803707?mt=12"><strong>Download on the Mac App Store</strong></a>
  ·
  <a href="https://hirakke.github.io/FileRenamer/privacy.html">Privacy Policy</a>
  ·
  <a href="https://github.com/hirakke/FileRenamer/issues">Support</a>
</p>

[日本語版はこちら](README.md)

FileRenamer helps you put many files in a clear order, build a naming rule from dates, text, and counters, and review the result before any files are changed.

```text
DSC_1842.jpg  →  20260820_Event_001.jpg
IMG_2941.jpg  →  20260820_Event_002.jpg
IMG_3014.jpg  →  20260820_Event_003.jpg
```

Before you rename, FileRenamer checks for duplicate names and conflicts with files already at the destination. If it finds a problem, it explains it instead of running the change.

## Icon View

Review your photos with larger previews and both the original and proposed names. Choose two to eight columns to suit the size of your window.

![FileRenamer icon view showing original and proposed names](Documentation/Images/icon-view.png)

## What You Can Do

- Add files or folders with drag and drop.
- Sort by original name, creation date, modification date, capture date, or file size.
- Drag rows or use move controls to fine-tune the order; counters follow that exact order.
- Combine date, counter, original-name, fixed-text, and photo-information blocks.
- Switch between list and icon views and adjust the icon-view column count.
- Convert JPEG, PNG, and HEIC images to JPEG or PNG.
- Resize images by their longest edge while keeping the original aspect ratio.
- Open images, PDFs, and videos in a separate preview window with double-click or the Space bar.
- Keep several naming jobs open at once in tabs.
- Review exact and visually similar image candidates before deciding what to do.

Similarity analysis stays on your Mac. FileRenamer never removes files or excludes them from the list automatically. Files can only be moved to the Finder Trash after you explicitly choose them and confirm.

## Languages

FileRenamer is available in Japanese and English. Open **FileRenamer → Settings…** and choose **Use System Setting**, **Japanese**, or **English**.

With **Use System Setting**, FileRenamer uses Japanese only when macOS is set to Japanese; it uses English for every other system language. File names, fixed text in your naming rules, and names of presets you create are never translated.

## Requirements

- macOS 14.0 or later
- Apple silicon and Intel Macs

The direct-download DMG is signed and notarized by Apple.

## Install from the DMG

1. Download `FileRenamer-*.dmg` from the [latest release](https://github.com/hirakke/FileRenamer/releases/latest).
2. Open the DMG.
3. Drag `FileRenamer` to the `Applications` folder.
4. Open FileRenamer from Applications.

## Your First Rename

### 1. Add Files

Choose **Add Files…** or **Add Folder…** in the toolbar, or drag files from Finder onto the window.

When you add a folder, its name appears at the top of the window. Click it to reveal that folder in Finder.

### 2. Arrange the Order

Use the Sort menu in the toolbar, or drag rows into the order you want. The first item becomes `001`, the second becomes `002`, and so on. Proposed names update immediately when you change the order.

### 3. Make a Naming Rule

You can start with a built-in preset. To build your own rule, type any fixed text directly into the naming field, then choose **Insert Block** for the parts that vary per file.

| Block | Use | Example |
| --- | --- | --- |
| Date | Add a creation, modification, or capture date | `20260820` |
| Counter | Number files in the arranged order | `001` |
| Original Name | Reuse all or part of the original name | `DSC_1842` |
| Photo Information | Use camera, lens, ISO, and other metadata | `ISO800` |
| Fixed Text | Add an event name or separator | `_Event_` |

For example, a rule of capture date + `_Event_` + a three-digit counter produces `20260820_Event_001.jpg`. By default, the existing file extension is kept.

### 4. Review the Changes

The list shows the original name and the proposed name side by side. Double-click a file or press Space to inspect it in a separate preview window.

A green check means the file can be processed. An orange warning is something to review. A red error must be resolved before FileRenamer can continue; use the control at the right edge of the row to read the reason.

### 5. Rename

Click **Rename** at the bottom right, review the final confirmation, then run the change.

FileRenamer asks macOS for folder access only when it is needed, such as when working with an external drive. It does not repeatedly request access for folders that are already available.

## Image Conversion and Resizing

Open **Image Settings** beside the naming rule to choose an output format and an optional longest edge.

- JPEG and PNG output are supported.
- The aspect ratio is always preserved.
- **Do Not Upscale Smaller Images** is on by default when you enable resizing.
- JPEG output offers Maximum (100%), High (95%, recommended), Standard (90%), Compact (80%), and Custom quality.
- JPEG files are recompressed when saved. At 100%, when the output remains JPEG and resizing is off, FileRenamer can skip recompression and only rename the file.

Whenever image content will change, FileRenamer lets you choose whether to keep the originals. You can save originals in a newly created folder with a name you choose, or replace them after confirmation. Name-conflict checks, rollback after a failure, and rename history continue to protect the operation in either case.

## Undo and Recovery

- **Command-Z** undoes the most recent list-order change.
- **Option-Command-Z** undoes the last completed file rename after confirmation.
- Image processing keeps the backup material needed for Undo and for recovery after an interrupted operation.
- Undo history is limited. Keeping originals is separate from Undo and is the safer option when image content matters.

## Privacy

Files, thumbnails, image analysis, metadata reading, renaming, conversion, resizing, similarity checks, Trash actions, Undo, and recovery are handled on your Mac. FileRenamer does not collect or send your files, images, names, metadata, or usage data.

When update checking is enabled, the app contacts the update feed only to learn whether a newer version is available. It does not upload file or usage data.

Read the full [Privacy Policy](https://hirakke.github.io/FileRenamer/privacy.html).

## Development

The repository uses three branches:

- `develop` — shared feature work and verification
- `main` — direct, notarized DMG distribution with Sparkle updates
- `app-store` — Mac App Store submission, without Sparkle

See [the release process](docs/RELEASE_PROCESS.md) for the checks required before a release.
