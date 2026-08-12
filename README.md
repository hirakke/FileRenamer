# File Renamer

macOS 向けの一括リネームアプリ。中心にあるのは「連番を入力する」のではなく
**ファイルを並べると番号が決まる** という体験です。

```
Import  →  Arrange  →  Name  →  Rename
```

リスト（またはグリッド）の並び順がそのまま連番の割り当て順になり、
1 行ドラッグするだけで全ファイルの変更後の名前が即座に付け替わります。
命名ルールは `{date}_{name}_{counter:03}` のような記法ではなく、
Shortcuts 風のブロックを並べて作ります。

写真（JPEG / RAW / HEIC）を主要ユースケースにしつつ、PDF・動画・Office 文書など
形式による制限は設けていません。

## ビルドと実行

通常は Xcode で `FileRenamer.xcodeproj` を開き、
`FileRenamer` スキームを選択します。ロジックテストは
`RenameKitTests` スキームを実行します。
Xcode プロジェクトのアプリターゲットは App Sandbox を有効化し、
ユーザーが選択したファイルとフォルダへの読み書きを許可しています。

```bash
./scripts/build-app.sh          # build/FileRenamer.app を生成
open build/FileRenamer.app
```

ロジックのテスト:

```bash
swift run RenameKitTests
```

## アーキテクチャ

UI とビジネスロジックを別ターゲットに分離しています。
View はファイル名を組み立てず、`FileManager` も呼びません。

```
Sources/
  RenameKit/            ← AppKit / SwiftUI 非依存。純ロジックのみ
    Models/
      RenameItem        論理アイテム。RAW+JPEG は companionURLs で 1 件にまとまる
      RenameRule        Text / Counter / Date / OriginalName / Metadata のブロック列
      RenamePreview     元URL → 変更後URL と検証結果
      FileMetadata      作成日・更新日・撮影日・カメラ・ISO ほか
    Engine/
      RenameEngine      [RenameItem] + RenameRule → [RenamePreview]（I/O なし）
      RenameValidator   重複 / 既存衝突 / 不正文字 / 長さ を判定
      ItemSorter        自動ソート、ロック行の位置保持、並べ替えと order の同期
      FileNameSanitizer macOS のファイル名規則
    IO/
      FileImporter      フォルダ再帰展開・パッケージ除外・RAW+JPEG グルーピング
      MetadataLoader    ImageIO による EXIF 読み取り（RAW 含む・現像はしない）
      RenameExecutor    2 段階リネーム、永続ジャーナル、起動時復旧
      RenameHistory     Undo / Redo スタック

  FileRenamer/          ← SwiftUI
    AppModel            状態の集約。すべての操作の入口
    Views/              List / Grid / 命名ルールバー / ステータスバー

  RenameKitTests/       ← ロジックのテスト
```

### 連番のモデル

`RenameEngine.makePreviews(items:rule:)` は渡された配列の **index** をそのまま
カウンタに使います。つまり「並び順 = 番号」という関係が 1 箇所に閉じており、
ドラッグ・自動ソート・行の削除のいずれも同じ経路を通ります。
`ItemSorter.reindexed` が配列 index と `RenameItem.order` を常に同期させます。

`isLocked` を立てた行は `ItemSorter.sorted` で元の index に固定されるため、
「撮影日時順に自動整列 → 数枚だけ手で調整 → 再ソート」しても調整が消えません。

並べ替えの手段はドラッグだけではありません。各行の ▲▼（グリッドでは ◀▶）ボタン、
右クリックメニュー、⌘↑ / ⌘↓ が `ItemSorter.shift` を通り、
ドラッグとまったく同じ経路で番号を更新します。複数選択はひとかたまりで動きます。

ボタンを押すと対象の行はカーソルの下から移動してしまうため、
`AppModel` は押された行を一定時間「掴んだ」状態にします（`grabbedStepIDs`、最後のクリックから 1.6 秒）。
掴んでいる間はどのボタンを押しても同じファイルが動くので、
**マウスを動かさず連打するだけで目的の位置まで送れます**。掴んでいる間は矢印がアクセントカラーになります。
さらに、行が移動した距離とまったく同じ量だけリストをスクロールさせるため、
移動した行はカーソルの真下に戻ります。
**動くのはリストの中身のほうで、対象のファイルはその場に留まって見えます。**

移動距離は「入れ替わる相手の行が今どこにあるか」から算出します（`FileListView.travelDistance`）。
行の高さが揃っていなくても正確で、移動前のレイアウトから計算するので 1 フレームのズレも出ません。
スクロールは `ListScrollController` が `NSScrollView` のクリップビューを直接動かします。
`ScrollViewReader.scrollTo(_:anchor:)` は `List` では
「見える範囲まで最小限スクロール」に丸められて割合アンカーが効かないため使っていません。
ドラッグ・自動ソート・削除など他の並べ替え操作が入ると掴みは解除されます。

リスト表示には、**現在の並べ替え基準の値**を表示する列があります
（撮影日時でソート中なら撮影日時、サイズでソート中ならサイズ）。
値を持たないファイルは「—」になり、そのまま「なぜ末尾に並ぶのか」の説明になります。
列見出しをクリックすると昇順・降順が反転します。

### 命名ルールのプリセット

`RenameRulePreset` は名前 + `RenameRule` です。組み込みプリセット（日付+イベント名+連番 など）は
コード上で毎回生成し、ユーザーが保存したものだけを
`~/Library/Application Support/FileRenamer/rule-presets.json` に JSON で保存します
（`RulePresetStore`）。ブロックを手で編集するとプリセットとの紐付けが外れ、
ラベルが「カスタム」に変わります。

命名ルールはメインウィンドウでもプリセット編集画面でも、**テキストを打つのが基本**です。
`Day1_` のような固定文字列や区切り文字はそのままキーボードで入力し、
ファイルごとに変わる部分（連番・日付・元の名前・写真情報）だけをキャレット位置にブロックとして差し込みます。
ブロックはドラッグで移動、ホバーの × または右クリックで削除でき、削除すると前後のテキストが結合します。
ブロックの直後で **Backspace** を押しても削除できます（文字を消すのと同じ操作感）。
Delete（前方削除）なら直後のブロックを消します。
削除後のキャレットは、結合されたテキストの「ブロックがあった位置」に戻ります
（結合ランが前側の id を引き継ぐことを利用。この前提はテストで固定してあります）。

この編集形式は `RuleTextField` の 1 実装で、ツールバーの本番ルールとプリセットの下書きは
同じ部品の置き場所違いです（違いはブロック設定の出し方だけ — バーはポップオーバー、
シート内はインライン。macOS ではポップオーバーの入れ子が安定しないため）。

内部では `RenameRule.normalizedForTextEditing()` が
「テキスト → ブロック → テキスト」の交互構造を保証し（キャレットの居場所を作るための空ランを含む）、
`compactedAfterTextEditing()` が保存形に戻します。
`inserting(_:atRun:caret:)` がキャレット位置でテキストランを分割してブロックを差し込みます。

画面構成（名前 → 例 → ルールのフィールド → カテゴリ別の挿入）は
Lightroom Classic のファイル名テンプレートエディターを参考にしています。

### 見た目

ブロックはテキストの中の「語」として読めるようにしています。
等幅・同サイズ・同じベースラインで、周囲の文字と違うのは色だけ。
表示する文字も `連番 (001)` のようなラベルではなく、
**実際に生成される文字列**（`001`、`20260808`、元のファイル名）です。
リストに読み込み済みのファイルがあれば、その 1 件目の実値を使います。

角丸と Liquid Glass は `View.liquidGlass(tint:cornerRadius:interactive:)` に集約しています。
macOS 26 以降では `glassEffect`、それ以前ではマテリアル + ヘアラインにフォールバックします。

色は `Palette` に集約。命名ブロックには用途別の色を使い、
エラー・警告・成功・アクセントはmacOSのシステムカラーに追従します。

### エラーの確認

行の右端のマークをクリックすると、原因の全文・元の名前・変更後・場所がポップオーバーで出ます。
下部の「N 件のエラー」をクリックすると該当ファイルの一覧が出て、項目をクリックするとその行が選択されます。

## 安全性

大量のファイル名を書き換えるため、以下を設計上の前提にしています。

- **中身に触れない** — `FileManager.moveItem` のみ。ファイルを開いて書き戻す経路が存在しません
- **拡張子を保持** — 変更後の名前は常に元の拡張子を引き継ぎます（`.RAF` は `.RAF` のまま）
- **2 段階リネーム** — `original → .filerenamer-tmp-<UUID> → final`。
  `A.jpg → B.jpg` と `B.jpg → A.jpg` を同一バッチで安全に処理できます
- **永続ジャーナルとロールバック** — 最初の move より前にApplication Supportへ記録し、
  moveごとに同期します。通常の失敗は即座に逆順で戻し、強制終了やクラッシュ後は次回起動時に元の名前へ復旧します
- **処理中の終了防止** — リネーム・Undo・復旧の途中は通常終了とSudden Terminationを抑止します
- **実行前の検証** — 変更後の名前の重複（大文字小文字・Unicode 正規化を含む）、
  既存ファイルとの衝突、不正文字、255 バイト超をエラーとして実行をブロックします
- **パッケージの除外** — `.app` や `.rtfd` などの中身は対象にしません
- **Undo** — 直前のバッチを `⌘Z` で元に戻せます（履歴は `RenameHistory` に保持）

## App Store向け設定

- App Sandbox: 有効
- User Selected Files: Read/Write
- Hardened Runtime: 有効
- Bundle ID: `jp.keiju.FileRenamer`
- Version: `1.0.0` / Build `1`
- App Icon: `Resources/Assets.xcassets/AppIcon.appiconset`
- Privacy Manifest: 追跡なし・収集データなし。ユーザーが選択したファイルの日時／メタデータ取得を `3B52.1` で申告
- 暗号化: 非免除暗号化の使用なし

提出前にはXcodeのSigning & Capabilitiesで実際のApple Developer Teamを選び、
App Store Connect側で同じBundle IDを登録してください。スクリーンショット、説明文、
サポートURL、プライバシーポリシーURLはリポジトリ外の情報なので別途入力が必要です。

## 主なキーボード操作

| 操作 | ショートカット |
| --- | --- |
| ファイルを追加 | ⌘O |
| フォルダを追加 | ⇧⌘O |
| すべて選択 | ⌘A |
| 1つ前へ / 1つ後ろへ | ⌘↑ / ⌘↓ |
| 先頭へ / 末尾へ移動 | ⌥⌘↑ / ⌥⌘↓ |
| リストから除外 | Delete |
| クイックルック | Space |
| 位置を固定 / 解除 | ⌘L |
| リネームを元に戻す | ⌘Z |
| リネームを実行 | ⌘Return |

## テストと継続的検証

`swift run RenameKitTests` はXCTestに依存しない60件の安全性・性能テストを実行します。
二段階リネーム、Undo、クラッシュ復旧、Unicode衝突、RAW+JPEG、写真メタデータ、
検索置換、連番リセット、プリセット入出力・破損時退避を実ファイルで検証します。GitHub Actionsでも安全性テストと
Releaseビルドを実行します。

プレビュー生成と検証はアクター上で実行し、メインスレッドを占有しません。
連続する文字入力や並べ替えは最新リビジョンへ集約し、保存先の存在確認は同じフォルダを
まとめて調べます。サムネイルはリスト用／グリッド用の2サイズへ集約し、同一リクエストを共有します。
10,000件の名前生成・構造検証を性能回帰テストで継続確認しています。
