# `zts_rpc` 型システム & JSON 境界コーデック設計書 (`M1-03`)

- **対象スコープ**: `src/rpc/naming.zig`, `src/rpc/types.zig`, `src/rpc/codec.zig`
- **関連規約**: [`web-zig-boundary.md`](web-zig-boundary.md), [`00-overview.md`](00-overview.md)

---

## 1. 設計目的とレイヤ境界

`zts_rpc` のコーデック層（`naming.zig`, `types.zig`, `codec.zig`）は、OS WebView や GUI バックエンドに一切依存しない **`link_libc = false` の Pure Zig 実装** であり、Web 標準（JavaScript / TypeScript / JSON / HTML）と Zig `0.17.0` の言語仕様差によって生じるバグをコンパイル時およびワイヤープロトコル層で防止します。

---

## 2. モジュール構成と公開 API

### 2.1 `src/rpc/naming.zig`（識別子変換 & JS/TS 予約語検査）

| 関数 / 定数 | 役割 |
|---|---|
| `snakeToCamel(comptime snake: []const u8)` | `comptime` で `snake_case` を `camelCase` 文字列リテラルへ変換する。ハイフンを含む識別子（`@"aria-label"`, `@"data-id"`, `@"--bg"`）は無変換で保持し、先頭アンダースコア（`"_id"`, `"__typename"`）も維持する。 |
| `snakeToCamelBuf` / `snakeToCamelAlloc` | 実行時スライス向けの `camelCase` 変換。 |
| `camelToSnake(comptime camel: []const u8)` | `camelCase` / `PascalCase`（連続大文字アクロニム `parseHTMLDoc` 含む）を `snake_case` へ逆変換する（ハイフン識別子は保持）。 |
| `matchesFieldName` | JSON キーと Zig 構造体フィールド名の照合（デフォルト `camelCase` 厳格一致、`allow_snake_case_fields` 有効時は両方受理）。 |
| `isJsReservedWord` / `needsPropertyQuotes` / `escapeJsBindingIdentifier` | `M1-04` (`tsgen.zig`) 用の ECMAScript / TypeScript 予約語判定・識別子エスケープ・プロパティ引用符要否判定。 |

### 2.2 `src/rpc/types.zig`（Web 境界専用ラッパー型群）

| 型 / 関数 | JSON ワイヤー表現 | 対応 TS 型 | 設計ポイント |
|---|---|---|---|
| `BigInt(T)` (`i64`/`u64`/`i128`/`u128`/`isize`/`usize`) | 10進文字列 `"9007199254740993"` | `bigint` | IEEE 754 `f64` の 53-bit 精度限界を超える整数を精度劣化ゼロで往復転送する。生の JSON 数値トークンは `error.UnexpectedToken` で拒否する。 |
| `Bytes` | Base64 `"..."` または `[u8, ...]` | `Uint8Array` | 任意の生バイナリスライス `[]const u8`。エンコードはデフォルト Base64（オプションで数値配列）、デコードは Base64 文字列と数値配列の両方を自動受理する。 |
| `OsPath` | UTF-8 文字列 または `{"display":"...","rawToken":"<base64>"}` | `string \| OsPath` | 有効な UTF-8 パスはゼロコピー文字列として転送し、Linux 非 UTF-8 バイト列や Windows WTF-8（片割れサロゲート `0xED 0xA0..0xBF 0x80..0xBF`）は UI 表示用 `display`（`U+FFFD` 置換済み UTF-8）と `rawToken`（Base64 生バイト）のペアで 1 ビットも損なわず往復する。 |
| `Patch(T)` | キー省略 / `null` / `<T>` | `prop?: T \| null` | `union(enum) { unchanged, null, value: T }`。JSON オブジェクトのキー省略（`undefined`）と明示的 `null` を完全に識別し、`apply(&target_opt)` / `applyNonNull(&target_req)` ヘルパーを提供する。 |
| `UnionStyle` / `UnionConfig` / `TaggedUnion(U, cfg)` | `.internal` / `.adjacent` / `.external` / `.untagged` | Discriminated Union 等 | `union(enum)` の 4 表現モード。型宣言内の `pub const json_union` または `TaggedUnion` ラッパーで指定可能。 |
| `Handle(Tag)` / `isHandleType(T)` | `u53` 整数 (`0 .. 2^53 - 1`) | `Branded<number, Tag>` | `packed struct(u53) { index: u24, generation: u29 }`。`zts_core.HandlePool` のハンドル型とも `toU53`/`fromU53` ダックタイピングでシームレスに連携する。 |

### 2.3 `src/rpc/codec.zig`（ゼロコピー対応 `comptime` JSON エンコーダ / デコーダ）

1. **素の 64-bit / `usize` 整数のコンパイル時遮断 (`assertValidRpcType` / `checkRpcType`)**:
   - `bits > 53` の整数型（`i64`, `u64`, `i128`, `u128`, `i54`, `u54` 等）およびターゲット依存の `usize` / `isize` が構造体・配列・Union 内のどこかに含まれている場合、`@compileError` で `i53`/`u53` または `BigInt(T)` への置き換えを案内する。
2. **24 バイト軽量 `Cursor` によるヒープ確保ゼロ・ゼロコピーデコード**:
   - `std.json.Scanner` は `{` や `[` のネスト追跡にヒープ上の `BitStack` を使用するが、`codec.zig` の内部 `Cursor` はスタック上の `depth: usize` カウンタのみで動作する。
   - そのため、エスケープを含まない JSON 文字列スライス（`allocate = .alloc_if_needed`）を持つ構造体・Tagged Union・`Patch(T)`・UTF-8 `OsPath` のデコードは、`std.testing.failing_allocator` 下でも **ヒープ確保 0 バイト** で完了する。
3. **カーソル巻き戻しによるキー順序非依存 `.internal` / `.adjacent` Union デコードと `.untagged` バックトラック**:
   - JSON オブジェクト内で `"kind"` タグフィールドが末尾（例: `{"width":100,"height":200,"kind":"rect"}`）にある場合も、`Cursor` の `O(1)` コピー走査により事前バッファリングなしで対象バリアントを特定して単一パスでデコードする。
   - `.untagged` モードではバリアント試行中に途中フィールドで不一致が起きた場合、`errdefer` と `freeDecoded` により途中確保メモリを即座に解放してから次のバリアントへバックトラックする。
4. **片割れサロゲート (`\uD800`..`\uDFFF`) と `NaN`/`Inf` の厳格処理**:
   - 文字列内のペアにならない UTF-16 サロゲートは、デフォルト `.reject` で `error.LoneSurrogate` を返し、`.replace_with_fffd` 指定時は `U+FFFD`（``）へ置換、`OsPath` デコード時は 3 バイト WTF-8 として `raw` にロスレス保持する。
   - `f32`/`f64` はエンコード・デコード双方向で `std.math.isFinite` を検証し、`NaN`・`±Infinity`・指数オーバーフロー（`1e500`）をすべて `error.NonFiniteFloat` で捕捉する。
5. **カスタム `jsonParse` / `jsonStringify` フック互換**:
   - `M1-07` の `Channel(T)`（`"__CHANNEL__:<id>"` ワイヤー形式）など、標準 `std.json` の `jsonParse` / `jsonStringify` フックを定義する型もそのままシリアライズ・デシリアライズ可能。
