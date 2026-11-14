# 用語集

ziggurats のドキュメントと API で使う言葉を、1 か所に集めたものです。各項目は **1 文の定義** と
**初出するページへのリンク** を持ちます。本文中の `` `Engine` `` のようなコード表記は、
このページの該当する見出しへ自動でリンクされます（用語集にない名前は API リファレンスへ）。

> [!NOTE]
> ここに載っていない言葉が出てきたら、それは用語集の不足です。追加先はこのファイル 1 つだけです。

---

## Pack

配布・開発の単位。`zts_foundation` / `zts_web` / `zts_rpc` / `zts_bridge` / `zts_webview` /
`zts_tauri` / `zts_ssg` / `zts_wasm` / `zts_build` / `zts_cli` の 10 個があり、それぞれが 1 つの
Zig モジュールとして独立してリンクできます。どれがどれに依存するかは
[パッケージ構成](../docs/architecture/00-overview.md) の図を見てください。

## Handle

JavaScript 側に渡す「実体を持たない参照」の整数 ID。ポインタをそのまま渡すと寿命も型も失われる
ので、`HandlePool` がプロセス内で一意な番号を発行し、ホスト側で実体に戻します。寿命は
`OwnedBytes` と同様に「誰が解放するか」が決まっています（[所有権](#ownedbytes)）。

## OwnedBytes

「長さ + ポインタ」ではなく、**長さとポインタを 1 つの値をして所有する**バイト列。確保した側が
`deinit` する責任を持ち、借りただけの `[]const u8` と型で区別できます。IPC の戻り値がこれです。

## Engine

WebView エンジンのハンドル。`create` で 1 つ作り、`step` でイベントループを 1 周回します。
GTK / AppKit / Win32 のどれを使うかは実行時に選ばれ、アプリ側のコードは変わりません。

## Bridge

ブラウザの Live Preview とホストをつなぐ HTTP + SSE のサーバ。`BridgeServer` が `invoke` を
HTTP の POST として受け、結果を SSE で戻します。ネイティブ実行では使われません。

## Ctx

コマンド 1 回分の実行文脈。アロケータ（`scratch`）、呼び出し元の情報（`getEnv`）、
キャンセル状態を持ちます。ハンドラの第 1 引数に `*Ctx` を置くと受け取れます。

## Schema

「どのコマンドが、どんな引数を取り、何を返すか」を型として 1 か所に書いたもの。
`Schema(.{ .app = Commands })` で作り、`bind` で状態と結びつけ、`handler` でディスパッチャに
なります。TypeScript の型はこの `Schema` から生成されるので、**手で二重に書く場所はありません**。

## Handler

`Schema` から作られる、型消去された呼び出し口。`dispatch(ctx, &ctx, "name", json)` の形で
コマンド名と JSON を受け取り、`Responses`（ステータス + 本文）を返します。

## Command

JavaScript から `invoke("name", args)` で呼べる関数 1 つ。Zig 側では `` `Schema` `` に登録された
`pub fn` がそのままコマンドになります。名前空間（`plugin:fs|read_text_file` など）で衝突を避けます。

## Capability

「このウィンドウは、この権限を持っている」という宣言。`capabilities/*.json` に書き、
ビルド時に ACL へ取り込まれます。capability は **許可の束** であり、それ自体は何も実行しません。

## Permission

`plugin:fs|read_text_file` のような識別子 1 つ。実際にコマンドを呼べるかは、capability が
その permission を含むかで決まります。[ACL](#acl) を参照。

## ACL

Access Control List。「誰が（window）何を（permission）できるか」の表。`Policy.allows()` が
それを判定します。**何を守らないか** も明記しています: ACL はプロセス内のコードを守りません。
同じプロセスで動く Zig のコードは自由に呼べます。

## Scope

permission に付く「範囲」。たとえば `fs` の read 権限でも、`$APPDATA/**` の下だけ、のように
パスや URL を限定できます。permission だけでは足りないときに使います。

## Invoke

JavaScript からホストのコマンドを呼ぶ操作。`@tauri-apps/api` の `invoke` と互換です。
戻り値は JSON で、エラーは HTTP ステータス相当の `IpcStatus` と本文で返ります。

## IPC

Inter-Process Communication。ここでは WebView とホストの間のやり取り全般を指します。
ネイティブでは `ipc://` スキーム、Live Preview では HTTP、WASM では関数呼び出しになります。
アプリ側のコードはこの違いを知りません。

## Channel

コマンドの戻り値とは別に、**後から複数回流れる値** を受け取る口。進捗・ログ・イベントに使います。
`Channel<string>` のように型を付けます。

## Plugin

コマンドと状態をまとめた再利用単位。`plugin:fs` / `plugin:dialog` / `plugin:menu` /
`plugin:tray` / `plugin:clipboard` / `plugin:path` / `plugin:event` / `plugin:resources` の 8 つが
組み込みです。`CorePluginStates` が全部入りの束です。

## Window

WebView を載せる枠。`WindowConfig` で幅・高さ・タイトル・リサイズ可否を決めます。
1 プロセスに複数持て、それぞれが独立した `label` を持ちます。

## Assets

`web/` 配下の静的ファイルを、**実行ファイルに埋め込んだもの**。`@embedFile` で取り込み、
gzip 版と CSP ハッシュを同時に生成します。実行時にファイルを読まないので、配布物は 1 つで済みます。

## CSP

Content Security Policy。埋め込んだスクリプトのハッシュを `script-src` に列挙し、
インラインスクリプトの実行を許可しつつ、外部からの注入を拒否します。

## SSG

Static Site Generation。同じアプリをサーバなしで配れる形（HTML + JS + WASM）に書き出すこと。
`exportStaticSite` が担当します。

## WASM

WebAssembly。デスクトップ用のコードを `wasm32-freestanding` でビルドし、ブラウザで同じ
コマンドを動かします。`exportApp` が C ABI（`_zts_invoke` など）を公開します。

## Prerender

SSG の書き出し時に、ルートごとの HTML をあらかじめ生成しておくこと。初回表示が速くなり、
JavaScript が無効でも本文が読めます。

## Manifest

SSG が出力する `_zts/manifest.json`。どのファイルがどのハッシュを持つかを列挙し、
キャッシュの無効化と整合性検査に使います。

## Loopback

`127.0.0.1` だけで待ち受けること。Live Preview のブリッジは既定で loopback のみ、
外部からの接続は `OriginPolicy` で拒否します。

## Origin

ブラウザが送る「どのページから来たか」の情報。Live Preview はこの値を見て、許可した
オリジン以外からの `invoke` を拒否します。

## Determinism

同じ入力から同じバイト列が出ること。ドキュメントサイトもバイナリも、時刻・乱数・
ファイル順に依存しないように作っています（`.deb` の `mtime=0`、HTML のソート済みファイル一覧）。

## Layer violation

「公開 API の説明に内部事情（設計番号・実装用語）が混ざる」こと。
`scripts/check-docs.py` が `///` を検査して落とします。理由は `docs/decisions/`、
使い方は `///`、という分担を守るための機械的な歯止めです。

## doctest

ドキュメント中のコードを、実際にコンパイルして検証すること。情報文字列に `zig check` を持つ
フェンスだけが対象で、壊れた例は CI で落ちます。書いた例が「動かない例」にならないための仕組みです。

## xref

本文中の `` `名前` `` を、API リファレンス・用語集・エラー索引・CLI リファレンスの該当箇所へ
自動で張るリンク。名前はソースから作られるので、rename するとリンクが壊れてビルドが落ちます。

## 関連

- [API リファレンス](api/index.html) — 名前から引く辞書
- [エラー索引](reference/errors.html) — `error.Name` から引く
- [CLI リファレンス](reference/cli.md) — `zts` のサブコマンド
- [はじめての ziggurats](learn/ja/start.md) — 10 分で動かす
- [ドキュメント索引](INDEX.md) — サイトのサイドバーと同じ並び

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-10-21 -->
