# FileRenamer 開発ガイド

この文書はFileRenamerをソースからビルド・検証する開発者向けです。アプリの使い方は [README.md](README.md) を参照してください。

## Xcodeで開く

1. `FileRenamer.xcodeproj` をXcodeで開きます。
2. `FileRenamer` スキームを選びます。
3. 実行先を「My Mac」にしてビルドまたは実行します。

アプリのDeployment TargetはmacOS 14.0です。アプリターゲットではApp Sandbox、User Selected FilesのRead/Write、Hardened Runtimeを有効にしています。

## コマンドラインでビルドする

```bash
./scripts/build-app.sh
open build/FileRenamer.app
```

生成物は `build/` 以下に出力され、Gitの管理対象には含まれません。

## テスト

```bash
swift run RenameKitTests
```

`RenameKitTests` は、名前の生成、衝突検出、二段階リネーム、Undo／Redo、ロールバック、クラッシュ復旧、画像変換、JPEG品質、原本保護、メタデータ保持などを実ファイルで検証します。

GitHub Actionsでも、macOS上の安全性テストとReleaseビルドを実行します。

## ソース構成

```text
Sources/
  FileRenamer/       SwiftUIによるmacOSアプリと画面
  RenameKit/         名前生成、検証、ファイル操作、画像処理
  RenameKitTests/    ロジックとファイル操作のテスト
```

`RenameKit` はUIから分離し、名前のプレビュー、検証、実際のファイル操作が同じ規則を共有する構成です。

主な責務:

- `RenameEngine`：命名ルールと並び順から変更後の名前を生成
- `RenameValidator`：重複、既存ファイル、不正文字、長さを検証
- `RenameExecutor`：二段階リネーム、ジャーナル、ロールバック、Undo／Redo
- `ImageProcessor`：JPEG／PNG変換、リサイズ、メタデータ、原本保護
- `AppModel`：アプリ状態とユーザー操作を集約

## 配布

- Developer ID署名、Apple公証、DMG：[DMG_DISTRIBUTION.md](DMG_DISTRIBUTION.md)

署名証明書、秘密鍵、App用パスワード、個人用の素材はリポジトリへ追加しないでください。
