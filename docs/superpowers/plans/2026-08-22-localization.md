# FileRenamer Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** FileRenamerを設定で日本語・英語へ即時切替でき、システム言語が日本語以外なら英語で一貫して表示する。

**Architecture:** `AppLanguage`が表示言語を解決し、`AppPreferences`が選択値を保存する。String Catalogを英語基準・日本語翻訳として追加し、アプリのSceneへ解決済みLocaleを渡す。固定文言はカタログキー、可変文言はロケール指定の書式化ヘルパーで表示する。

**Tech Stack:** Swift 5、SwiftUI、Foundation、Xcode String Catalog、UserDefaults、既存RenameKitTests。

**Spec:** `docs/superpowers/specs/2026-08-22-localization-design.md`

## Global Constraints

- 初期設定は「システム設定に従う」。
- `ja`と`ja-*`は日本語、それ以外は英語として解決する。
- ファイル名、命名規則の固定文字、利用者作成プリセット名は翻訳しない。
- 通常リネーム、画像処理、Undo、Sandboxアクセス、更新処理の動作を変更しない。
- `main`と`app-store`は共有実装を同期し、配布版のバージョンは同じ値に保つ。

---

### Task 1: 表示言語の解決と設定保存

**Files:**
- Create: `Sources/RenameKit/Localization/AppLanguage.swift`
- Modify: `Sources/RenameKitTests/EngineTests.swift`
- Modify: `Sources/RenameKitTests/main.swift`
- Modify: `Sources/FileRenamer/FileRenamerApp.swift:6-112`

**Interfaces:**
- Produces: `AppLanguage`, `ResolvedAppLanguage`, `AppLanguage.resolved(preferredLanguageIdentifier:)`
- Consumes: `AppPreferences.displayLanguage`

- [ ] **Step 1: Add failing language-resolution tests**

```swift
try expectEqual(AppLanguage.system.resolved(preferredLanguageIdentifier: "ja-JP"), .japanese)
try expectEqual(AppLanguage.system.resolved(preferredLanguageIdentifier: "en-US"), .english)
try expectEqual(AppLanguage.system.resolved(preferredLanguageIdentifier: "fr-FR"), .english)
try expectEqual(AppLanguage.japanese.resolved(preferredLanguageIdentifier: "en-US"), .japanese)
```

- [ ] **Step 2: Run the test executable and confirm the new symbols are unavailable**

Run: `xcodebuild -scheme RenameKitTests build` followed by the built `RenameKitTests` executable.

- [ ] **Step 3: Implement the pure language model**

```swift
public enum AppLanguage: String, CaseIterable, Sendable {
    case system, japanese, english
    public func resolved(preferredLanguageIdentifier: String) -> ResolvedAppLanguage
}
public enum ResolvedAppLanguage: String, Sendable { case japanese, english }
```

Use `Locale(identifier: preferredLanguageIdentifier).language.languageCode?.identifier == "ja"` for system resolution.

- [ ] **Step 4: Persist the choice in AppPreferences**

Add key `preferences.displayLanguage`, register `.system`, read an invalid stored value as `.system`, and save every change. Expose `resolvedLanguage` and `displayLocale` using `Locale.preferredLanguages.first ?? "en"`.

- [ ] **Step 5: Run the language tests and the complete test executable**

Expected: all existing safety tests and the new language tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/RenameKit/Localization/AppLanguage.swift Sources/RenameKitTests/EngineTests.swift Sources/RenameKitTests/main.swift Sources/FileRenamer/FileRenamerApp.swift
git commit -m "Add display language preference"
```

### Task 2: String Catalog and localization helpers

**Files:**
- Create: `Sources/FileRenamer/Resources/Localizable.xcstrings`
- Create: `Sources/FileRenamer/Support/Localization.swift`
- Modify: `FileRenamer.xcodeproj/project.pbxproj`
- Test: `Sources/RenameKitTests/EngineTests.swift`

**Interfaces:**
- Consumes: `ResolvedAppLanguage`
- Produces: `L10n.string(_:defaultValue:language:)`, `L10n.format(_:defaultValue:arguments:language:)`

- [ ] **Step 1: Add a failing fallback test**

```swift
try expectEqual(AppLanguage.system.resolved(preferredLanguageIdentifier: "ko-KR"), .english)
```

- [ ] **Step 2: Create the English-base String Catalog**

Use stable keys such as `menu.file.add`, `settings.displayLanguage`, `action.cancel`, `action.confirmRename`, and `status.itemCount`. Add English development values and Japanese translations. Configure `en` and `ja` as known project regions.

- [ ] **Step 3: Implement localized string access**

```swift
enum L10n {
    static func string(_ key: String, defaultValue: String, language: ResolvedAppLanguage) -> String
    static func format(_ key: String, defaultValue: String, arguments: [CVarArg], language: ResolvedAppLanguage) -> String
}
```

Resolve a language-specific bundle (`en.lproj` or `ja.lproj`) before calling `localizedString(forKey:value:table:)`; use the English default value when the key is absent.

- [ ] **Step 4: Build the FileRenamer target and inspect the built app resources**

Confirm that English and Japanese localization resources are copied into the application bundle.

- [ ] **Step 5: Commit**

```bash
git add Sources/FileRenamer/Resources/Localizable.xcstrings Sources/FileRenamer/Support/Localization.swift FileRenamer.xcodeproj/project.pbxproj Sources/RenameKitTests/EngineTests.swift
git commit -m "Add English and Japanese string catalog"
```

### Task 3: Settings, root Locale, menus, and shared controls

**Files:**
- Modify: `Sources/FileRenamer/FileRenamerApp.swift`
- Modify: `Sources/FileRenamer/Views/ContentView.swift`
- Modify: `Sources/FileRenamer/Views/StatusBar.swift`
- Modify: `Sources/FileRenamer/Views/FileListView.swift`
- Modify: `Sources/FileRenamer/Views/FileGridView.swift`

**Interfaces:**
- Consumes: `AppPreferences.resolvedLanguage`, `AppPreferences.displayLocale`, `L10n`
- Produces: localized root scene and menus that update when `displayLanguage` changes.

- [ ] **Step 1: Add the display-language Picker to Settings**

Use the three values `System Setting`, `日本語`, and `English`; bind it to `$preferences.displayLanguage`. Label it with `settings.displayLanguage` and describe the non-Japanese-to-English rule.

- [ ] **Step 2: Inject the current Locale into every scene**

Apply `.environment(\\.locale, preferences.displayLocale)` to `WindowGroup` content and `Settings` content. Ensure the scene observes `preferences` so a Picker change refreshes all visible views.

- [ ] **Step 3: Replace visible shared controls with catalog keys**

Migrate file import, folder import, execution, cancellation, close, remove-from-list, Finder reveal, Quick Look, trash, sorting, grid/list labels, status labels, and their accessibility labels. Use `L10n.format` for counts.

- [ ] **Step 4: Localize command menus and confirmation dialogs**

Migrate Window, Edit, tab, file, sort, Undo/Redo, update, and destructive-operation menu labels. Migrate ContentView confirmation titles, explanatory text, and action labels.

- [ ] **Step 5: Build and manually verify runtime switching**

At runtime select Japanese, English, and System with a non-Japanese preferred language. Confirm the main window, settings, open sheets, context menus, and Window/Edit menus change without relaunching.

- [ ] **Step 6: Commit**

```bash
git add Sources/FileRenamer/FileRenamerApp.swift Sources/FileRenamer/Views/ContentView.swift Sources/FileRenamer/Views/StatusBar.swift Sources/FileRenamer/Views/FileListView.swift Sources/FileRenamer/Views/FileGridView.swift
git commit -m "Localize app navigation and commands"
```

### Task 4: Naming, image, preset, preview, and error localization

**Files:**
- Modify: `Sources/FileRenamer/AppModel.swift`
- Modify: `Sources/FileRenamer/Views/NamingRuleBar.swift`
- Modify: `Sources/FileRenamer/Views/RuleTextField.swift`
- Modify: `Sources/FileRenamer/Views/PresetMenu.swift`
- Modify: `Sources/FileRenamer/Views/TokenEditor.swift`
- Modify: `Sources/FileRenamer/Views/TokenInsertPanel.swift`
- Modify: `Sources/FileRenamer/Support/PreviewImageLoader.swift`

**Interfaces:**
- Consumes: `L10n`, `AppPreferences.resolvedLanguage`
- Produces: localized image controls, preset management, preview errors, alerts, and results.

- [ ] **Step 1: Replace all user-facing fixed text in the listed views with catalog keys**

Include naming-rule blocks, image format and resize settings, JPEG quality presets, extension settings, preset import/export/manage labels, token labels, validation guidance, and preview recovery buttons.

- [ ] **Step 2: Localize AppModel-created messages at the display boundary**

Represent internal outcomes with stable keys and interpolation values. Format alerts, result messages, image-change descriptions, validation explanations, and permission guidance through `L10n` immediately before presenting them. Do not translate filesystem-provided error detail or user file names.

- [ ] **Step 3: Add catalog entries for every migrated key**

Each entry must have an English value and a Japanese value. Use positional format placeholders for dynamic filenames, folder names, and counts.

- [ ] **Step 4: Run the complete safety test suite**

Expected: RenameEngine, RenameExecutor, ImageProcessor, FileTrasher, history, preset, and new language tests all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FileRenamer/AppModel.swift Sources/FileRenamer/Views/NamingRuleBar.swift Sources/FileRenamer/Views/RuleTextField.swift Sources/FileRenamer/Views/PresetMenu.swift Sources/FileRenamer/Views/TokenEditor.swift Sources/FileRenamer/Views/TokenInsertPanel.swift Sources/FileRenamer/Support/PreviewImageLoader.swift Sources/FileRenamer/Resources/Localizable.xcstrings
git commit -m "Localize naming and image workflows"
```

### Task 5: Release verification and distribution-branch synchronization

**Files:**
- Modify: `README.md`
- Modify: `docs/RELEASE_PROCESS.md`
- Sync: `main`, `app-store`

**Interfaces:**
- Consumes: verified `develop` localization commits
- Produces: synchronized release branches and documented language availability.

- [ ] **Step 1: Update user documentation**

State that the app supports Japanese and English, that System uses Japanese only for Japanese macOS language preferences and English otherwise, and that language selection is in FileRenamer Settings.

- [ ] **Step 2: Run full verification on develop**

Run RenameKitTests, Debug build, Release build, Xcode Analyze, and inspect the built app for both `en.lproj` and `ja.lproj` resources.

- [ ] **Step 3: Sync shared localization commits to both distribution branches**

Merge the verified `develop` commits into `main`. Apply the same shared source and resource changes to `app-store` without introducing Sparkle. Keep both branches at the same marketing and build version.

- [ ] **Step 4: Verify both distribution branches**

Run RenameKitTests and a universal Release build in each branch. Confirm `main` embeds Sparkle and `app-store` contains no Sparkle references.

- [ ] **Step 5: Push branches without tagging an unreleased build**

Push `develop`, `main`, and `app-store`. Create `v<version>-dmg` only after notarized DMG creation, and `v<version>-appstore` only after the submitted archive is final.
