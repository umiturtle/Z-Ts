# Task M1-02: `zts_core` Web アセット・HTTP Range・CSP・URL/Glob 基盤の実装（＋ `M1-03` 手直し統合）

- **Status**: `done`
- **Branch**: `arena/ff647573-z-ts`
- **Scope**: `src/core/{assets,mime,http_range,csp,html_escape,glob,url,mod,handle_pool}.zig`, `src/rpc/{mod,scanner,types,codec}.zig`, `src/root.zig`, `docs/{architecture/rpc-codec.md,decisions/0003-zig-017-runtime-findings.md,tasks/M1-03-rpc-codec.md}`
- **Upstream Reference**: `docs/roadmap/m1-foundation-packages.md`, `docs/architecture/web-zig-boundary.md`, `vendor/tauri/crates/tauri-utils/src/{mime_type.rs,acl/,html.rs}`
- **Next Step**: Wave 1 全タスク（`M1-01`, `M1-02`, `M1-03`）完了により、Wave 2（`M1-04` `Schema`/`tsgen`, `M1-05` `zts_bridge`, `M1-06` `zts_webview`, `M1-07` `zts_tauri`）が 4 並列で着手可能。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 分散ロック宣言コミット & リモート Push
- [x] `src/core/mime.zig`: ES Module / Wasm / SVG / CSS / フォント / 音声・動画の拡張子ルックアップ + WHATWG マジックバイト Sniffing
- [x] `src/core/http_range.zig`: RFC 9110 `Range: bytes=...` パーサ（bounded / open-ended / suffix / クランプ / `416` / malformed 無視）& ゼロアロケーション `Content-Range` 生成
- [x] `src/core/html_escape.zig`: チャンク一括書き込み高速化 HTML-Safe JSON ライタ（`</script>` / `<!--` / `U+2028` / `U+2029` 防御）& HTML コメント回避付き `<head>` 初期化スクリプト注入
- [x] `src/core/csp.zig`: ゼロアロケーション `sha256Source`（`[53]u8`）・`nonceSource`（`[32]u8`）、CSP Level 3 `default-src` 継承対応ディレクティブ追記、Nonce プレースホルダ置換、`<meta>` 生成
- [x] `src/core/url.zig`: ゼロアロケーション URL / IPv6 / Web Origin 比較、ローカル WebView オリジン判定、`%2e%2e`・`%5c`・NUL バイトを完全阻止するパス正規化器
- [x] `src/core/glob.zig`: ヒープ確保ゼロ・ReDoS 完全耐性 `O(|P|×|T|)` Glob マッチャ（`*`, `**`, `?`, `[...]`）+ 1,000 反復ランダムファズテスト
- [x] `src/core/assets.zig`: 静的アセット解決 + SPA ルートフォールバック（拡張子付き欠損アセットは厳格に `404` 維持）+ `206 Partial Content` + HTML `<head>` 自動注入
- [x] **`M1-03` 手直し・統合完了**:
  1. **名目型分裂バグ修正**: `rpc/types.zig` の重複 `Handle` 実装を削除し `core.Handle` を直接再エクスポート（`comptime assert(rpc.Handle(.window) == core.WindowId)` を保証）。
  2. **カスタムフック型 `@compileError` バグ修正**: `checkRpcType` が `jsonParse`/`jsonStringify` を持つ構造体（内部に `*anyopaque` や `usize` を持つ `Channel(T)` 等）を誤拒否していた不具合を修正。
  3. **Non-exhaustive Enum エラーコード修正**: 未定義タグ値に対して誤って `error.InvalidUtf8` を返していた箇所を `error.InvalidEnumTag` に修正し回帰テストを追加。
  4. **符号付きフル Safe Integer 対応**: `i53`（`±2^52`）に加え `±(2^53 - 1)` 全域を扱う `rpc.SafeInt` を追加。
  5. **`zts_core` エスケープ統合 & モジュール分割スリム化**: `core.html_escape` への一本化、`scanner.zig` 分離、および共通 `ObjectIter` 導入により `src/rpc/codec.zig` を **2,904 行 → 1,868 行（▲1,036 行削減、実装本体 1,280 行）** に圧縮。
  6. **パッケージ公開統一**: `src/rpc/mod.zig` を新設し、`src/root.zig` から `pub const core` / `pub const rpc` を対称公開。
- [x] Debug / `ReleaseFast` / Windows・macOS クロスコンパイル / `zig fmt --check` / 3-OS GitHub Actions CI 全検証

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `M1-02` 全 7 モジュール実装、`M1-03` 全 6 項目の手直し・スリム化、および全 50 テストスイート（10,000-step HandlePool ファズ + 1,000-step Glob/URL ファズ + MPSC マルチスレッド並行テスト含む）オールグリーンを確認。
- **作業中・直前の状態**:
  - 最終フルビルド（Debug / `ReleaseFast` / 3-OS クロスビルド）・`zig fmt`・PR 作成・GitHub Actions 3-OS CI 実機完走確認を実行。
