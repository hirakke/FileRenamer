# App Store リリース手順

## Xcodeで最初に設定するもの

1. `FileRenamer.xcodeproj` を開き、FileRenamerターゲットの Signing & Capabilities を選ぶ。
2. Apple Developer Programへ登録済みのTeamを選ぶ。
3. `jp.keiju.FileRenamer` が利用できない場合は、App Store ConnectとXcodeの両方で同じ一意のBundle IDへ変更する。
4. Version `1.0.0`、Build `1`を確認する。再提出時はBuild番号を増やす。

ソース一覧に付く小さな矢印はXcodeプロジェクトから実ファイルへの参照を示すだけです。
コンパイル後のアプリにはソース参照は含まれず、App Store審査への影響はありません。

## 提出前チェック

- `Product > Archive` を実行する。
- OrganizerのValidate Appを通す。
- App SandboxとUser Selected Files (Read/Write)が有効であることを確認する。
- Archive内に `AppIcon.icns` と `PrivacyInfo.xcprivacy` があることを確認する。
- 実ファイルの複製で、リネーム、Undo、アプリ再起動後のUndoを確認する。
- 日本語表示、ライト／ダークモード、VoiceOver、キーボード操作を確認する。

## App Store Connectで必要な外部情報

- アプリ名、サブタイトル、説明、キーワード
- 1280×800、1440×900、2560×1600、2880×1800のいずれかのmacOSスクリーンショット
- サポートURL、マーケティングURL（任意）、プライバシーポリシーURL
- App Privacy: 追跡なし、収集データなし（実装を変更した場合は再確認）
- 年齢区分、価格、配信地域、輸出コンプライアンス

公開URL:

- サポート: `https://github.com/hirakke/FileRenamer/issues`
- プライバシーポリシー: `https://hirakke.github.io/FileRenamer/privacy.html`

署名証明書、Team、App Store Connectの登録情報、公開URLは開発者アカウント固有のため、
このリポジトリには固定していません。
