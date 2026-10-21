# `zts_core` Web foundation（`M1-02`）設計書

> **スコープ**: [`src/core/`](../../src/core/) のうち `mime`, `http_range`, `assets`, `html_escape`, `csp`, `url`, `glob` の 7 モジュール。
> **前提**: `link_libc = false`・OS I/O 一切なし・`std` のみ。ファイルシステム読み取りは `zts_bridge` / `zts_webview` が注入する `Assets.Loader` が担う。

---

## 1. なぜ独立モジュールなのか

WebView アプリの「真っ白画面」「Wasm 起動不能」「動画がシークできない」「`</script>` で XSS」は、すべて **HTML / HTTP / ブラウザ仕様の細部** に起因する。これらを `zts_bridge` や OS 別 WebView 実装に散らすと、同じバグを 3 OS で 3 回踏む。そこで M1-02 では仕様境界を Pure Zig の小さなモジュールに閉じ込め、OS 非依存の単体テストで固定する。

```text
              ┌───────────────────────────────┐
   HTTP/SSE   │ zts_bridge (M1-05)            │
  custom URI  │  zts_webview (M1-06)          │
              └──────────┬────────────────────┘
                         │ Assets.resolve(allocator, target, options)
        ┌────────────────▼─────────────────┐
        │ zts_core                         │
        │  assets ── mime                  │
        │    │      http_range             │
        │    └── url ── glob               │
        │  html_escape ── csp              │
        └──────────────────────────────────┘
```

---

## 2. モジュール別 API と保証

| モジュール | 主要 API | 保証 / セキュリティ不変条件 |
|---|---|---|
| `mime.zig` | `fromExtension`, `fromPath`, `sniff`, `detect`, `essence`, `charsetOf`, `isTextual`, `isCompressible` | ES Modules は `text/javascript; charset=utf-8`、`.wasm` は `application/wasm`。既知拡張子をマジックバイトより優先（モジュール MIME 厳格一致）。判定は全て `comptime` 文字列でアロケーション0。 |
| `http_range.zig` | `parse`, `resolve`, `contentRange`, `unsatisfiedContentRange`, `ifRangeMatches`, `ByteRange.slice/length` | `bytes=start-end` / `start-` / `-suffix` のみ。**構文不正は 200 へフォールバック**、**構文は正しいが範囲外のみ 416**（RFC 9110 §14.2）。マルチレンジは 200。`If-Range` の弱い ETag は常に不一致。 |
| `assets.zig` | `Assets.resolve`, `Assets.Response.deinit`, `StaticMap.get`, `Loader` | パーセントデコード後に `..` / NUL / `\` / 制御文字 / 非 UTF-8 を拒否。SPA は **拡張子なしパスのみ**（`.js` 欠落を HTML で隠さない）。HEAD は `Content-Length` を保持し body 空。416 は body 空 + `total_length` 保持。ローダ確保バッファは `Response.deinit` で必ず 1 回解放。 |
| `html_escape.zig` | `writeJsonString`, `writeJsonStringContent`, `writeScriptSafe`, `writeEmbeddedJson`, `escapeHtmlAlloc`, `scriptSafeAlloc` | `<` → `\u003c`、`>` → `\u003e`、`&` → `\u0026`、U+2028/U+2029 をエスケープ。不正 UTF-8 は `\ufffd`。`std.json.Stringify` の出力を後処理するため、任意の Zig 値が `<script>` 内で安全。 |
| `csp.zig` | `Nonce.random(io)`, `writeHashSource`, `Policy.write`, `writeDefaultPolicy`, `injectIntoHead`, `injectScript`, `replaceAll` | 128-bit CSPRNG Nonce（`Io.randomSecure`）、`'sha256-…'` ソース、`<head>` 不在でも先頭注入。Nonce は base64 文字のみ許可、script body 内の `</script` は拒否。ヘッダ値への `;` / CR/LF 注入を拒否。 |
| `url.zig` | `parse`, `parseOrigin`, `Origin.eql`, `sameOrigin`, `percentDecodeAlloc`, `matchesRemotePattern`, `isLocalScheme/isRemoteScheme`, `tauri_origin`/`ipc_origin` | userinfo・バックスラッシュ・制御文字・パーセントエンコード済みホスト・非 ASCII ホストを拒否（fail-closed）。デフォルトポート（80/443/21）を正規化し、scheme/host は ASCII 大文字小文字を無視して比較。 |
| `glob.zig` | `match`, `matchWith`, `matchAny`, `isSafePath`, `hasWildcard` | `*` は 1 セグメント内、`**` は 0 個以上のセグメント、`?` は 1 文字。`..` / `%2e%2e` / `%2f` を含むパスは不一致。セグメント数上限 256・パス長上限 8192 で DoS を防止。 |

---

## 3. アセット解決パイプライン

```text
target ("/users/42?x=1#top")
  │
  ├─ 1. query / fragment を除去
  ├─ 2. percent-decode（不正な % は 404）
  ├─ 3. 正規化: 先頭 / 付与、空セグメント / "." を除去、UTF-8 検証
  │      ".." / NUL / "\" / 制御文字 → 404（正規化で消さない）
  ├─ 4. ディレクトリ要求 ("/docs/") → "/docs/index.html"
  ├─ 5. StaticMap 完全一致 → なければ Loader（相対パス "docs/index.html"）
  ├─ 6. 見つからない & 拡張子なし & spa_fallback → "/index.html"
  ├─ 7. MIME: Asset.mime 上書き > 拡張子 > マジックバイト
  └─ 8. Range / If-Range / HEAD を適用して Response
```

`Assets.Response` から HTTP へのマッピング（`zts_bridge` / `zts_webview` が使用）:

| Response | HTTP |
|---|---|
| `status` | `200` / `206` / `404` / `416` |
| `mime` | `Content-Type` |
| `content_length` | `Content-Length`（HEAD でも実値） |
| `range` | `Content-Range: bytes {start}-{end}/{total_length}`（`http_range.contentRange`） |
| `status == .range_not_satisfiable` | `Content-Range: bytes */{total_length}`（`unsatisfiedContentRange`） |
| `etag` | `ETag`（`If-Range` と同一の引用符付き文字列） |
| `isSuccess()` | `Accept-Ranges: bytes` を付与してよい |

### `Loader` の所有権契約

```zig
const loader = Assets.Loader{
    .ctx = state,
    .load_fn = struct {
        fn load(ctx: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
            // path はアセットルートからの相対パス（先頭 "/" なし）
            // 見つからない場合は null、確保した場合は呼び出し元が deinit で release_fn を 1 回呼ぶ
        }
    }.load,
    .release_fn = struct {
        fn release(ctx: ?*anyopaque, gpa: std.mem.Allocator, bytes: []u8) void {
            gpa.free(bytes);
        }
    }.release,
};
```

- `path` は **リクエスト終了時に破棄される借用スライス**（内部 Arena 由来）なので、保持する場合はコピーする。
- `load_fn` が `null` を返した場合のみ「未存在」と解釈し、その他のエラーは `error.LoadFailure` として伝播する。
- `Response` を返した後は必ず `response.deinit(allocator)` を呼ぶ（静的アセットは no-op）。

---

## 4. CSP 注入フロー（`M1-06` / `M1-07` 連携）

```zig
const nonce = try core.csp.Nonce.random(io);
var nonce_buf: [core.csp.nonce_encoded_len]u8 = undefined;
const nonce_b64 = nonce.encode(&nonce_buf);

// 1. ヘッダ（または <meta>）用ポリシー
var policy_buf: [1024]u8 = undefined;
var writer = std.Io.Writer.fixed(&policy_buf);
try core.csp.writeDefaultPolicy(&writer, nonce_b64);
// → default-src 'self'; script-src 'self' 'nonce-…'; object-src 'none'; …

// 2. ブートストラップ JS を <head> 先頭へ注入
const html = try core.csp.injectScript(allocator, raw_html, bootstrap_js, nonce_b64);

// 3. 動的 JSON を <script> に埋め込む場合は JSON 側も HTML-Safe にする
const json = try core.html_escape.writeEmbeddedJson(allocator, .{ .user = untrusted });
```

`__ZTS_CSP_NONCE__` のようなプレースホルダを使う場合は `csp.replaceAll` で一括置換する。静的インライン script は `csp.hashSourceAlloc` の `'sha256-…'` を `script-src` に追加できる。

---

## 5. 攻撃ベクタと防御（テスト対象）

| 攻撃 | 防御 | テスト |
|---|---|---|
| `</script><script>alert(1)</script>` を JSON に埋め込む | `writeJsonStringContent` が `<`/`>`/`&`/U+2028/U+2029 を `\uXXXX` 化 | `html_escape.zig` |
| `/../../etc/passwd`、`/%2e%2e/secret`、`/%2E%2E%2Fsecret` | デコード後セグメント比較で 404、ローダ未呼び出し | `assets.zig`, `glob.zig` |
| `http://evil.com\@localhost`、`http://local%68ost`、`http://user@host` | userinfo / `\` / `%` ホスト / 非 ASCII ホストを拒否 | `url.zig` |
| `Range: bytes=0-1,4-5`（multipart 未実装） | 200 全量へフォールバック（RFC 準拠） | `http_range.zig` |
| `Range: bytes=999999999999999999999-` | `error.Overflow` → 200 | `http_range.zig` |
| 巨大な `**/**/**/…` や 10 万セグメントパス | パターン 4 KiB / パス 8 KiB / 256 セグメント上限 | `glob.zig` |
| CSP ヘッダへの CRLF / `;` 注入 | `Directive` / source 検証で拒否 | `csp.zig` |
| SPA フォールバックで `.js` 欠落を隠蔽 | 拡張子ありパスはフォールバックしない | `assets.zig` |
| HEAD 応答での Content-Length 不整合 | body 空・`content_length` は実値 | `assets.zig` |

---

## 6. 検証方法

```bash
./zigw quick-test                 # src/root.zig 経由で core 全 84 テスト（コールド約5秒）
./zigw fmt --check src/ build.zig build.zig.zon
python3 scripts/check-docs.py
```

`std.testing.allocator` を使用しているため、アセットのローダ確保バッファ・Arena・CSP の出力文字列にリークが 1 バイトでもあればテストが失敗する。
