# FileRenamerのDMG配布

この手順はMac App Store用のArchiveとは独立しています。通常のXcode設定を変更せず、
App Store外配布用の成果物だけをDeveloper IDで署名・公証します。

## 必要なもの

- Apple Developer Programの有効なチーム `6HY8YSMK7C`
- 秘密鍵付きの次の証明書
  - `Developer ID Application: Keiju Hiramoto (6HY8YSMK7C)`
- Xcode
- AppleのNotary serviceへ接続できるネットワーク

`Developer ID Installer`は`.pkg`用であり、このDMG配布では使用しません。

## 1. 公証資格情報をキーチェーンへ保存する（一度だけ）

Apple Accountでアプリ用パスワードを作成してから、Terminalで次を実行します。

```bash
xcrun notarytool store-credentials "FileRenamer-Notary" \
  --apple-id "Apple Developerで使用しているメールアドレス" \
  --team-id "6HY8YSMK7C"
```

アプリ用パスワードは安全な対話プロンプトで入力します。パスワード、APIキー、`.p12`は
リポジトリ、スクリプト、シェル履歴へ保存しません。

App Store Connect APIキーを使用する場合も、`notarytool store-credentials`で
キーチェーンプロファイル名を`FileRenamer-Notary`として保存してください。

## 2. 最終DMGを作成する

```bash
./scripts/build-dmg.sh
```

スクリプトは次を順番に実行します。

1. Release構成をUniversal Binary（Apple Silicon／Intel）としてArchive
2. `Developer ID Application`署名とHardened Runtimeを検証
3. `FileRenamer.app`と`Applications`ショートカットをDMGへ格納
4. DMGをDeveloper IDで署名
5. Apple Notary serviceへ提出して結果を待機
6. 公証チケットをDMGへ添付
7. GatekeeperでDMGと格納アプリを検証
8. SHA-256チェックサムを生成

成果物は次へ出力されます。

```text
build/distribution/FileRenamer-1.0.0.dmg
build/distribution/FileRenamer-1.0.0.dmg.sha256
```

## ローカルのパッケージング確認

公証せず、DMGの構成だけを確認する場合に限り次を使用します。

```bash
./scripts/build-dmg.sh --skip-notarization
```

出力名には`-unnotarized`が付きます。この成果物は配布しません。

## 公開前確認

- ブラウザ経由でDMGを再ダウンロードする
- 開発環境ではないmacOSユーザーまたは別のMacで開く
- Gatekeeperの開発元警告が出ないことを確認する
- `Applications`へコピーして起動する
- ファイル／フォルダ追加、リネーム、画像変換、Undoを確認する
- 公開ページへDMGと`.sha256`を一緒に掲載する

DMG版にはMac App Storeの自動アップデートはありません。更新方法を別途案内するか、
安全な更新機構を導入するまでは新バージョンのダウンロードページを案内します。
