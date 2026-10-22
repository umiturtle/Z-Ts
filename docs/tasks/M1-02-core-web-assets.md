# Task M1-02: `zts_core` Web アセット・HTTP Range・CSP・URL/Glob 基盤の実装（＋ `M1-03` 手直し統合）

- **Status**: `in_progress`
- **Branch**: `arena/ff647573-z-ts`
- **Scope**: `src/core/{assets,mime,http_range,csp,html_escape,glob,url,mod}.zig`, `src/rpc/{types,codec}.zig`, `src/root.zig`
- **Upstream Reference**: `docs/roadmap/m1-foundation-packages.md`, `docs/architecture/web-zig-boundary.md`, `vendor/tauri/crates/tauri-utils/src/{mime_type.rs,acl/,html.rs}`
- **Next Step**: `M1-02` 全 7 モジュールの実装と `M1-03` のバグ修正・`zts_core` 統合・重複削減を実施し、全テストおよび 3-OS GitHub Actions CI を通す。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 分散ロック宣言コミット & リモート Push
- [ ] `src/core/mime.zig`: ES Module / Wasm / SVG / CSS / メディア等の拡張子 & マジックバイト MIME 判定
- [ ] `src/core/http_range.zig`: RFC 9110 `Range: bytes=...` パーサ & `206 Partial Content` / `416` スライス計算
- [ ] `src/core/html_escape.zig`: `</script>` XSS 完全防止 HTML-Safe JSON 文字列ライタ & `<head>` 初期化スクリプト注入
- [ ] `src/core/csp.zig`: ゼロアロケーション SHA-256 CSP ソース生成 & Nonce 置換・`<meta>` 生成
- [ ] `src/core/url.zig`: URL / Origin 解析、パーセントデコード、`%2e%2e`・ヌルバイト・バックスラッシュを含むパストラバーサル防御
- [ ] `src/core/glob.zig`: ReDoS 耐性 O(N×M) Glob マッチャ（`*`, `**`, `?`, `[...]`）& パス正規化スコープ検査
- [ ] `src/core/assets.zig`: 静的アセット解決 + SPA `index.html` フォールバック（拡張子付き欠損は `404` 維持）+ `206 Range` 統合
- [ ] **`M1-03` 手直し**:
  - `src/rpc/types.zig`: 二重定義されていた `Handle` / `max_safe_uint` を `zts_core` の単一実装へ統合（`core.WindowId` 直結保証）
  - `src/rpc/codec.zig`: `enum_info.mode` 存在しないフィールド参照（non-exhaustive enum でのコンパイルクラッシュバグ）を修正、`core.html_escape` へ統合、5 重重複オブジェクト走査ループを `ObjectReader` に共通化して大幅スリム化
- [ ] Debug / `ReleaseFast` / 3-OS GitHub Actions CI オールグリーン確認

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - `main` (`7107baf`) にマージ済みの `M1-01` と `M1-03` の全コードを精読・監査し、`M1-03` の手直し対象箇所を特定。
- **作業中・直前の状態**:
  - `M1-02` の 7 モジュール作成と `M1-03` リファクタリングを開始。

---

## 3. 設計判断・技術メモ・ハマりどころ

- SPA フォールバックでは `/users/42`（拡張子なしルート）は `/index.html` (`200`) へフォールバックさせる一方、`/assets/missing.js`（拡張子ありサブリソース）に HTML を返すとブラウザが `SyntaxError: Unexpected token '<'` を起こすため厳格に `404` を返す。
