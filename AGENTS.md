# FileRenamer — agent notes

## Branches
- Implement on `develop` (worktree `.worktrees/develop`), then merge to `main` (DMG + Sparkle) and apply the same shared changes to `app-store` (no Sparkle). See `docs/RELEASE_PROCESS.md`.

## Verification
- Tests: `swift run RenameKitTests` (includes localization catalog checks).
- App build: `xcode-select` points at CommandLineTools, so call Xcode explicitly:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project FileRenamer.xcodeproj -scheme FileRenamer -configuration Release -destination 'generic/platform=macOS' -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build`
- `swift build` of the `FileRenamer` app target fails by design on `main` (Sparkle is only linked through the Xcode project).

## Localization
- User-facing app strings go through `L10n.string` / `L10n.format` with semantic keys in `Sources/FileRenamer/Resources/Localizable.xcstrings` (en + ja, one-line JSON entries, `item(s)` style plurals).
- RenameKit has no resources: it returns `LocalizableMessage` (key + English default + arguments); errors conform to `LocalizableError`. Resolve with `L10n.string(_:language:)` / `L10n.describe(_:language:)`.
- Do not write interpolated Japanese literals (`Text("\(n) 件")`) in app code; tests reject them.
