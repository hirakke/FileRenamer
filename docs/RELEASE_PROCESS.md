# FileRenamer リリース運用

## ブランチ

- `develop`：共通機能の開発と検証
- `main`：Developer ID署名・公証済みDMGの配布
- `app-store`：Mac App Store提出用

通常の機能修正は`develop`で完了させます。リリース時に、配布方法ごとの差分を確認したうえで`main`と`app-store`へ反映します。SparkleはDMG版だけに含め、App Store版には含めません。

## リリース前チェック

1. `main`と`app-store`の`MARKETING_VERSION`と`CURRENT_PROJECT_VERSION`を同じ値にする。
2. `develop`の共通修正が両方の配布ブランチに反映されていることを確認する。
3. 両方で安全性テスト、Releaseビルド、手動の基本操作確認を行う。
4. DMG版は署名、公証、Gatekeeper確認後にappcastとGitHub Releaseを更新する。
5. App Store版はArchiveを検証してからApp Store Connectへアップロードする。
6. 配布または提出に使用した各コミットへ、`v<version>-dmg`と`v<version>-appstore`のタグを付ける。

タグは実際に配布・提出したコミットだけに付けます。未配布の準備コミットには付けません。
