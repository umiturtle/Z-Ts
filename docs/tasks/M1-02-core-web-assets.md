# Task M1-02: `zts_core` Web アセット・HTTP Range・CSP・URL/Glob 基盤

- **Status**: `done`
- **Branch**: `arena/527fbcc6-z-ts`
- **Scope**: `src/core/{assets,mime,http_range,csp,html_escape,glob,url}.zig`, `src/core/mod.zig`, `docs/architecture/core-web-foundation.md`
- **Upstream Reference**: `vendor/wry` (custom protocol / MIME / range 応答), `vendor/tauri` (CSP 注入・asset 解決)
- **Next Step**: `M1-05`（`zts_bridge`）で `Assets.resolve` → HTTP ヘッダ対応表（本タスクの設計書 §3）を実装し、`305` 系の E2E で Cookie/Origin 検査を追加する

---

## 1. 目的と完了条件（Definition of Done）

- [x] 設計メモ / API 仕様の整理（[`../architecture/core-web-foundation.md`](../architecture/core-web-foundation.md)）
- [x] 単体テスト（正常系・異常系・境界値・セキュリティ境界・リーク検査 `std.testing.allocator`）の作成とパス
- [x] `./zigw quick-test`（全 84 テスト）および `python3 scripts/check-docs.py` のパス
- [x] `./zigw fmt --check src/ build.zig build.zig.zon` のパス
- [ ] 必要な場合 GitHub Actions（Linux Xvfb / macOS / Windows）でのグリーン確認

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `mime.zig`: 拡張子表（ES Modules / wasm / SVG / 画像 / 音声 / 動画 / WebFont）＋マジックバイト判定（PNG/JPEG/GIF/WebP/AVIF/RIFF/WASM/PDF/ZIP/WOFF/TTF/MP4/Ogg/MP3/FLAC/HTML/SVG 等）。
  - `http_range.zig`: RFC 9110 `bytes=start-end` / `bytes=start-` / `bytes=-suffix` パーサ、`206` / `416` 解決、`Content-Range` ビルダ、`If-Range` 検証（マルチレンジは 200 へフォールバック）。
  - `assets.zig`: 静埋め込みマップ＋遅延ローダ抽象（OS I/O 非依存）、パス正規化（パーセントデコード・`..` 拒否・NUL/制御文字/バックスラッシュ拒否）、ディレクトリ index 解決、SPA フォールバック、Range/HEAD 対応、所有権付きバッファの `deinit`。
  - `html_escape.zig`: HTML-Safe JSON（`<`→`\u003c`, `>`→`\u003e`, `&`→`\u0026`, U+2028/U+2029）、不正 UTF-8 は `\ufffd`、`std.json.Stringify` ラッパー。
  - `csp.zig`: 128-bit Nonce（base64）、`'sha256-…'` ソース生成、`<head>` 注入・Nonce プレースホルダ置換、CSP ヘッダ組み立て。
  - `url.zig`: Origin 抽出・正規化比較（userinfo / パーセント済みホスト / 制御文字を拒否）、`tauri://localhost` / `http://ipc.localhost`、リモート URL glob パターン。
  - `glob.zig`: `*` / `**` / `?` のセグメント単位マッチャ、`..`（`%2e%2e` 含む）パストラバーサル拒否、セグメント数上限による DoS 防止。
- **完了したこと（最終）**:
  - `src/core/mod.zig`（アルファベット順再公開 + `test { _ = … }`）と `src/root.zig` の `pub const core` を接続。`./zigw quick-test` で 84 テスト全パス（アロケーショリーク 0）。
  - 設計書 [`../architecture/core-web-foundation.md`](../architecture/core-web-foundation.md) を作成（API 保証・解決パイプライン・`Loader` 所有権契約・CSP 注入例・攻撃ベクタ表）。
- **作業中・直前の状態**:
  - 実装・検証完了。`M1-01`（`HandlePool` / `OwnedBytes` / `queue` / `geometry` / `host`）は未着手のため、`mod.zig` の先頭にその旨を明記し、追加時に既存行を壊さない構成にしてある。

---

## 3. 設計判断・技術メモ・ハマりどころ

- `zts_core` は `link_libc = false` / OS I/O なしを維持するため、`assets.zig` はファイルシステムに直接触れず **`Loader` 関数ポインタ抽象** のみを定義する（実 FS 読み取りは `zts_bridge` / `zts_webview` 側）。
- `std.Uri.parse` は入力スライスを借用するのみでアロケーションしないが、**userinfo 付き URL（`http://evil.com\@localhost` 等）を Origin 比較に使うと spoof 可能** なため、`url.zig` は userinfo・`%` を含むホスト・制御文字・バックスラッシュをすべて拒否する（fail-closed）。
- Zig 0.17 の `std.ArrayList(T)` は unmanaged（`.empty`, `append(gpa, x)`, `deinit(gpa)`）。可変長文字列生成には `std.Io.Writer.Allocating` を使う。
- マルチレンジ `bytes=0-1,4-5` は `multipart/byteranges` を実装しないため **Range ヘッダ無視（200 全量）** とし、構文的に正しいが充足不能な場合のみ `416` を返す（RFC 9110 §14.2）。
- `mime.detect` は「既知拡張子 > マジックバイト」の順で決定する（`.js` / `.mjs` / `.wasm` は MIME 厳格一致が必須のため、拡張子を信頼する）。
- **SPA フォールバックは拡張子なしのディレクトリ要求にも適用**する（`/dashboard/` は SPA ルート）。ただし `/docs/` のように `index.html` が実在すればそちらを優先し、`.js` 等の拡張子付き 404 は絶対に HTML で隠さない。
- `Assets.resolve` のパス文字列は呼び出しごとの `ArenaAllocator`、アセット本体は呼び出し元 `Allocator` から確保する。ローダ由来バッファは `Response.deinit` が `release_fn` を 1 回だけ呼ぶ（テストで呼び出し回数を検証済み）。
- Zig 0.17 では `std.crypto.random` が廃止されており、CSP Nonce は **`std.Io.randomSecure`**（`Nonce.random(io)`）で取得する。単体テストは `std.testing.io` を使用。
- Zig 0.17 の `std.ArrayList(T)` は unmanaged。文字列組み立ては `std.Io.Writer.Allocating`、部分文字列探索は `std.mem.find*`（`indexOf` は廃止）を使用する。
- `std.Uri.parse` はアロケーションせず入力スライスを借用する。ただし userinfo 付き URL は origin spoof に直結するため、`url.parse` は `uri.user`/`uri.password` を検出した時点で `error.HasUserInfo` を返す。
