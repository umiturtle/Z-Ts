# Tauri v2 互換の範囲 — 「同じ書き方」と「同じ挙動」は別

> **対象読者**: Tauri v2 からの移行を検討している人、導入前に実機能の範囲を確認したい人。
> **所要時間**: 10 分。
> **前提**: [Tauri v2 の使い方](tauri-usage.md) を一度眺めていること。

`@tauri-apps/api` v2 は**無改造で呼べます**。コマンド名・引数・戻り値の形は上流と揃えています。
ただしそれは **ワイヤ互換** であって、**OS の実機能や副作用まで同じ** という意味ではありません。
このページは「Tauri と同じ書き方ができる」と「Tauri と同じ結果が得られる」を分けて評価するための
境界を並べます。

## 3 行で言うと

1. **ワイヤ互換**: `invoke("plugin:…|…")` のコマンド名とペイロードは上流どおり。
2. **状態互換**: ウィンドウの `is*` は OS 側の操作にも追従します。
3. **実機能互換**: ネイティブ実装は**アプリ側の配線が必要**で、一部の API は**固定値・プレースホルダー**、
   未対応のプラグインは**設計上の明示的な選択**です。

## 互換は 3 層ある

| 層 | 例 | 到達度 |
|---|---|---|
| ワイヤ | `plugin:window\|set_title`、`plugin:webview\|create_webview_window` | 実装済み。無改造の JS パッケージから呼べる |
| 状態 | `isMinimized()` / `isMaximized()` / `isFullscreen()` | OS 起点のイベントがレジストリへ反映される |
| 実機能 | OS 通知センター、マルチモニター、実ユーザーのパス、OS プロセス情報 | **既定では縮小または未配線**（以下） |

「`invoke` がエラーを返さない」ことは「期待した OS の挙動が起きた」ことの証拠にはなりません。
導入判断では 3 層目を必ず確認してください。

## 1. ネイティブ機能は「無い」のではなく「自動で繋がらない」

`zts_tauri_native` は GTK / Cocoa / Win32 のメニュー・トレイ・ダイアログ・クリップボード実装を
**コンパイル時に選択します**。Linux 用のメニュー／トレイ実装も実在します。
（以前この資料の一部に「Linux のメニューは Stub」と書いてありましたが、これは誤りでした。）

しかし [`CorePluginStates.create()`](../api/zts_tauri/plugins.html) はメニュー／トレイを
**Stub で初期化**します。ネイティブ実装は別モジュールから**明示的に差し込む**設計です。
ダイアログとクリップボードも、それぞれ別の State と Backend を組み立てます。

```text
アプリ起動
  ├─ CorePluginStates.create()   → menu / tray は Stub
  └─ zts_tauri_native を差し込む → GTK / Cocoa / Win32 の実装に入れ替わる
```

つまり「実装が無い」のではなく、**利用アプリ側の配線が必要で、その手順が分散している**のが現状です。
配線手順は [プラグインガイド](../learn/ja/guides/plugins.md) と
[機能ギャップの整理](../architecture/tauri-feature-gap.md) に分かれています。

> [!WARNING]
> GTK のトレイ実装は `GtkStatusIcon` に依存しています。GTK 4 で削除された deprecated API で、
> ソース自身もその旨を明記しています。GTK 3.24 では動きますが、将来の移行が必要です。

## 2. 任意プラグインは、API 名があっても値が縮小されている

| コマンド | 実際に返る値 | 意味 |
|---|---|---|
| `plugin:process\|pid` | `0` | 固定値。実プロセス ID ではない |
| `plugin:os\|version` | `"ziggurats"` | 固定文字列。OS のバージョンではない |
| `plugin:os\|locale` | `null` | OS のロケール API に未接続 |
| `plugin:notification\|*` | アプリ内イベント | OS の通知センターには出ない |
| `plugin:opener\|*` | provider 未設定で `Unsupported` | 黙って成功せず fail-closed |
| HTTP / Updater / SQL | 不対応 | 設計上の明示的な選択（[機能ギャップ](../architecture/tauri-feature-gap.md)） |

`Unsupported` はバグではなく**既定で拒否**の契約です。provider を設定するか、未対応であることを
アプリ側で扱ってください。

## 3. 永続化と単一起動の弱点

| 項目 | 実際の挙動 | 使う側が把握しておくこと |
|---|---|---|
| `store.set` / `delete` / `clear` | **メモリ上の状態だけ**を変更 | ファイルへ残すには別の `save` コマンドを呼ぶ |
| `store.clear` | エントリを消すだけで保存は呼ばない | `clear` の後に `save` が必要 |
| 初期化時の読み込み | エラーが `catch {}` で無視される | 壊れた／読めない保存ファイルでも**空の状態で起動**し得る |
| `single-instance` | 排他ファイル方式。正常終了では削除 | クラッシュ後に残った古いロックの検出・回復処理は無く、次の起動がロック中と判定され得る |
| ブラウザ環境 | 排他ファイルの挙動が未定義 | Live Preview / 静的サイトでは前提を置かない |

保存を呼ばなければ終了後に残りません。重要な状態は `save` を明示し、起動時は「空で始まった」
可能性を UI で扱ってください。

## 4. `zts dev` はネイティブアプリの開発実行ではない

[`zts dev`](cli.md) は `web/` を配信する開発サーバーです。`src/` の変更も監視して型チェックと
再ビルドは行いますが、**ネイティブ WebView を開いて Zig 側との IPC を確認するコマンドではありません**。
[`zts init`](cli.md) のテンプレートも、フロントエンドの埋め込みまでは行いますが、
最初から Zig のコマンドを呼び出す RPC アプリにはなっていません。

| 最初の成功体験 | 確認できること | 確認できないこと |
|---|---|---|
| `zts dev` でブラウザ表示・再読み込み | HTML / CSS / ホットリロード | `invoke` の往復、ネイティブウィンドウ |
| `zts build` で生成した実行ファイル | ウィンドウと Zig 側のコマンド | — |

Tauri のように「起動した瞬間に IPC まで通る」体験を作るには、アプリ側にコマンド定義と
`invoke` 呼び出しを追加する必要があります（[カウンターを作る](../learn/ja/tutorials/counter.md)）。

## 5. パス API の既定値は実環境ではない

`PathState` を明示しない場合、次の固定値が返ります。

| フィールド | 既定値 |
|---|---|
| `home_dir` | `/home/user` |
| `resource_dir` | `/app/resources` |
| `executable_dir` | `/app/bin` |
| `cwd` | `/` |
| `config` / `data` | `~/.config` / `~/.local/share` を**文字列として組み立てる**だけ |

Windows の `%APPDATA%` や各 OS の実際のユーザーディレクトリは取得しません。
`DesktopConfig` の `paths` も既定では空の `PathState` なので、
`appDataDir()` などが**実在しない場所**を返す可能性があります。
本番ではアプリ側で `PathState` を実環境から組み立てて注入してください。

## 6. モニター API の既定値は固定値

| 項目 | 既定値 |
|---|---|
| モニター | 1920×1080、倍率 1.0、1 台 |
| カーソル位置 | `(0, 0)` |

差し替え用の provider の仕組みはありますが、リポジトリ内に実 OS 用 provider を登録する箇所は
ありません。この既定はヘッドレスモック・CI・スクリーンショット比較のための**決定論的な値**です。
マルチモニター配置、HiDPI、実カーソル位置を使う機能は、provider を登録しない限り正しい情報を
得られません。

## 7. 評価するときのチェックリスト

- [ ] その機能は「ワイヤ互換」だけでなく「実機能」まで必要か
- [ ] ネイティブ backend を `CorePluginStates` に差し込んだか
- [ ] 返ってくる値が固定値・`null`・プレースホルダーではないか
- [ ] 状態を永続化するなら `save` を呼んでいるか、壊れたファイルを想定しているか
- [ ] `PathState` と monitor provider を実環境から注入しているか
- [ ] `zts dev` ではなく `zts build` の実行ファイルで IPC を確認したか

## 関連

- [Tauri v2 の使い方](tauri-usage.md) — コマンド・設定・Capabilities の対応表
- [プラグインガイド](../learn/ja/guides/plugins.md) — backend の差し込み方
- [機能ギャップの整理](../architecture/tauri-feature-gap.md) — 実装する／しないの判断基準（内部資料）
- [`zts` コマンドリファレンス](cli.md)
- [API リファレンス](../api/index.html)

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
