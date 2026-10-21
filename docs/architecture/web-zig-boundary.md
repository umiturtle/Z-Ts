# Web 標準（HTML / CSS / JS / TS）⇔ Zig 言語仕様 境界設計規約

> **本書は、フロントエンド（HTML5 / CSS / JavaScript / TypeScript / JSON / WebView Engine）とバックエンド（Zig `0.17.0` / OS Native API）の言語・データモデル仕様差によって発生するバグを、型システムとプロトコル層で根絶するための必須実装規約です。**

---

## 一覧マトリクス（10 大インピーダンス・ミスマッチと解決策）

| # | 境界領域 | Web 側（HTML / CSS / JS / TS）の仕様 | Zig `0.17.0` / OS 側の仕様 | 放置すると起きるバグ | Z-Ts の解決規約（実装必須） |
|---|---|---|---|---|---|
| **1** | **文字列とバイト列** | `string` は UTF-16（Lone Surrogate 許容）。バイナリは `Uint8Array` / `ArrayBuffer`。 | `str` 型が存在せず文字列も生バイト列もすべて `[]const u8`。Windows パスは WTF-8、Linux パスは任意バイト列。 | `[]const u8` の意味が曖昧になり、非 UTF-8 ファイルパスで `JSON.parse` が死ぬ／ラウンドトリップでパスが壊れる。 | **`[]const u8`（UTF-8 文字列）**、**`zts.Bytes`（`Uint8Array`）**、**`zts.OsPath`（ロスレス往復パス）** の 3 型を明確に分離する。 |
| **2** | **`undefined` vs `null`** | `{}`（キー省略 = `undefined`）と `{ a: null }`（明示的 `null`）が明確に別物。 | オプショナル型は `?T` の 1 種類のみ。 | 部分更新（PATCH）で「未変更」と「NULL 削除」を区別できずデータを誤消去。TS `exactOptionalPropertyTypes` で型エラー。 | デフォルト値有無と `?T` を厳密対応させ、さらに 3 状態型 **`zts.Patch(T)`（`unchanged \| null \| value(T)`）** を提供する。 |
| **3** | **Tagged Union** | `{ kind: "circle", r: 10 } \| { kind: "point" }`（Discriminated Union）や `number \| string` が標準。 | `std.json` 標準は `{"circle":{"r":10}}` と `"point"`（文字列とオブジェクトが混在）。 | TS 側で `switch (x.kind)` が使えず型絞り込みが崩壊する。CSS 値のような `number \| string` が書けない。 | デフォルトを TS 親和の **Internally Tagged Object** とし、`.adjacent` / `.external` / `.untagged`（`number \| string` 用）も選択可能にする。 |
| **4** | **予約語 & ハイフン識別子** | `delete`, `class`, `default`, `in`, `new`, `function` 等が予約語。HTML `data-*` / `aria-*`、CSS `--*` はハイフン区切り。 | `type`, `error`, `align`, `opaque`, `async`, `test` 等が予約語（`@"type"` で記述）。 | Zig の `class` や `delete` が生成 `.ts` を構文破壊。`@"aria-label"` が勝手に `ariaLabel` に変換されて壊れる。 | `tsgen` に JS/TS 全予約語エスケープを内蔵。ハイフンを含む `@"..."` フィールドは `camelCase` 変換せずそのまま保持する。 |
| **5** | **浮動小数点 `NaN` / `Inf`** | `JSON.stringify(NaN)` はエラーにならず黙って **`null` に化ける**。`JSON.parse("NaN")` は `SyntaxError`。 | `f32`/`f64` は `NaN`/`Inf` を保持可能。非オプショナル `f64` に `null` が来るとデコード失敗。 | Canvas/CSS 計算で `0/0` が起きた瞬間に IPC 全体が `UnexpectedToken` でクラッシュする。 | 出力時は `std.math.isFinite` 検査を強制。入力時はオプションまたは明確な `InvalidFloat` エラーで捕捉する。 |
| **6** | **座標系・DPI・透過色** | CSS は **左上原点・論理ピクセル（DIP）・Straight RGBA**。 | Win32 は物理ピクセル、macOS `NSWindow` は **左下原点（Y 軸逆）**、コンポジタは Premultiplied BGRA。 | 4K/Retina でウィンドウが豆粒化・上下逆転・透過背景が黒塗りになる。 | **`LogicalPx` と `PhysicalPx` を別の Zig `struct` 型として定義** し、単位取り違えをコンパイルエラーにする。OS 差異は `zts_webview` 内部で完全吸収する。 |
| **7** | **MIME・SPA・`Range`** | `<script type="module">` や `.wasm` は MIME 厳格一致必須。SPA は仮想パスをリロード。`<video>` は `206` 必須。 | 単純なファイルマップだと仮想 URL が `404` になり、一括 `200` 応答だと Safari/WKWebView で動画が再生不能。 | ビルド後に真っ白画面・Wasm 起動不能・音声/動画シーク不能になる。 | `zts_core.Assets` に **標準 MIME 表 + SPA `index.html` フォールバック + RFC 9110 `Range` (`206 Partial Content`)** を標準搭載する。 |
| **8** | **HTML インライン注入と CSP** | HTML パーサは JSON 文字列リテラル内でも **`</script>` でタグを強制終了** する。 | `JSON.stringify` 単体では `/` をエスケープしない。Linux WebKit はヘッダ CSP が効かない場合がある。 | ユーザーデータに `</script>` が入ると即 XSS・画面崩壊。インライン CSS/JS が CSP で自爆する。 | HTML 埋め込み JSON は `<` → `\u003c` 等の **HTML-Safe エスケープ** を必須化し、CSP Nonce/Hash 書き換えを共通化する。 |
| **9** | **Enum 表現と TS 最新仕様** | TS 5.8+ / Node ネイティブ TS では `enum` 構文が非推奨（`erasableSyntaxOnly`）。文字列 Union が標準。 | `enum` の実体は整数だが `std.json` ではタグ名文字列。 | `tsgen` が `export enum Foo` を吐くとモダン TS コンパイラ設定でビルドエラーになる。 | `tsgen` は **型消去可能な `export type Foo = "a" \| "b";` のみを出力** し、ランタイムコード汚染をゼロにする。 |
| **10** | **カスタムタイトルバードラッグ** | Electron 出身の `-webkit-app-region: drag` CSS が WebKit (`WKWebView` / `WebKit2GTK`) では**動かない**。 | ウィンドウ移動は OS ごとのネイティブドラッグ開始 API 呼び出しが必要。 | フレームレスウィンドウを CSS だけで作ると Linux / macOS で一切動かせなくなる。 | 初期化スクリプトで `[data-tauri-drag-region]` および `app-region` 相当のマウスダウン委譲を組み込み、3 OS 共通で動作させる。 |

---

## 型マッピング完全対応表（Zig `zts_rpc` ⇔ JSON Wire ⇔ TypeScript `tsgen`）

| Zig 型 (`src/rpc/`) | JSON ワイヤー表現 | 生成される TypeScript 型 | 備考 |
|---|---|---|---|
| `bool` | `true` / `false` | `boolean` | |
| `i8`..`i53`, `u8`..`u53` | `42` | `number` | IEEE 754 完全精度保証 |
| `f32`, `f64` | `3.14` | `number` | `isFinite` 検証付き |
| `i64`, `u64`, `i128`, `usize` | **コンパイルエラー (`@compileError`)** | — | 暗黙の 53-bit 精度落ちを防止 |
| `zts.BigInt(i64 / u64 / i128)` | `"9007199254740993"` | `bigint` | 生成クライアントが自動で `BigInt(s)` / `.toString()` 変換 |
| `[]const u8` | `"hello"` | `string` | `.alloc_if_needed` により非エスケープ時はゼロコピー |
| `zts.Bytes` | Raw 経路 or Base64/Array | `Uint8Array` | バイナリ専用型（文字列と混同しない） |
| `zts.OsPath` | `{ display, raw_token }` or UTF-8 | `string \| OsPath` | 非 UTF-8 / WTF-8 パスの破壊ゼロ往復 |
| `T` (フィールド初期値なし) | 必須キー `val` | `prop: T` | |
| `?T` (フィールド初期値なし) | 必須キー `val \| null` | `prop: T \| null` | |
| `T = default` | 省略可能キー | `prop?: T` | `exactOptionalPropertyTypes: true` 準拠 |
| `zts.Patch(T) = .unchanged` | 省略 / `null` / `val` | `prop?: T \| null` | Zig 側で 3 状態を完全識別 |
| `enum { a, b }` | `"a"` / `"b"` | `"a" \| "b"` | `erasableSyntaxOnly: true` 準拠 |
| `union(enum)` | `{ kind: "a", ... }` 等 | `{ kind: "a"; ... } \| ...` | TS `switch (x.kind)` 直結 |
| `zts.core.Handle(Tag)` | `u53` 数値 | ` Branded<number, Tag>` | 世代番号付き + TS 側でも異種ハンドル誤渡しを型エラー化！ |
