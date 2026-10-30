# ADR-0011: `plugin:fs` を「正規化 → シンボリックリンク解決 → 包含判定」で実装する

- **Status**: Accepted（`M4-02`）
- **Date**: 2026-10-28
- **関連**: [`../tasks/M4-02-scoped-fs.md`](../tasks/M4-02-scoped-fs.md)、
  [`../architecture/tauri-fs-plugin.md`](../architecture/tauri-fs-plugin.md)、
  [`0004-tauri-v2-wire-and-deterministic-tsgen.md`](0004-tauri-v2-wire-and-deterministic-tsgen.md)

---

## 1. 背景

`@tauri-apps/plugin-fs` v2 は「フロントエンドから任意のパスを渡せる」プラグインであり、
**ケーパビリティ（スコープ）で許可された範囲外へ出られないこと**が唯一のセキュリティ境界になる。
本家は `tauri-plugin-fs` の `Scope` / `GlobalScope` / `CommandScope` でこれを実現している。

Z-Ts では `zts_tauri` が **`link_libc = false` の Pure Zig** で、GTK / Cocoa / Win32 に一切依存しない。
したがってスコープ判定も「OS 固有 API に頼らない純粋なアルゴリズム」として実装できる必要がある。

危険な実装は次の 3 つ。いずれも **文字列 prefix 比較** に起因する:

| 素朴な実装 | 突破される例 |
|---|---|
| `startsWith(root)` | `root = /srv/app`, `target = /srv/app-evil/x` |
| `..` を消さずに判定 | `root/a/../../etc/passwd` |
| 字句解決だけで判定 | `root/link -> /etc`（リンク自体は root 内） |

## 2. 決定事項

### 2.1 3 段階の解決を必ずこの順で通す

1. **字句正規化** — `path.normalizeWithStyle`（`M1-07` で実装済み、POSIX / Windows 両対応）で
   `.` / `..` / 重複セパレータを畳む。相対パスは `PathState.cwd` を基準に絶対化する。
2. **シンボリックリンク解決** — 絶対パスの各成分を先頭から `lstat` し、`sym_link` を見つけたら
   その**リンク先を展開して字句再正規化**する。これを [`max_symlink_hops`](../../src/tauri/fs/scope.zig)
   （40）回まで繰り返す。相対リンクは「リンクを含むディレクトリ」基準で解決する。
3. **包含判定** — 解決後のパスを**成分単位**で比較する（`/a/b` は `/a/bc` を含まない）。
   Windows のみ ASCII 大文字小文字を畳む（NTFS が大文字小文字を区別しないため）。

**存在しない末尾成分は許す**（`create` / `mkdir` のため）。ただし
「存在するのに `stat` が失敗した」場合は **`error.CannotVerify` で拒否** し、
検証できていないパスへフォールバックしない（fail-closed）。

### 2.2 リソースは既存 `ResourceTable` を再利用する

`open` / `create` が返す `rid` は `zts_tauri.resources.ResourceTable` の通常リソースとして登録する。
- 生成カウンタ付きハンドルなので、**偽造 rid・二重 close** は `BadResourceId` になる（Use-After-Free 無し）。
- `plugin:resources|close` をそのまま使えるので、`@tauri-apps/api` の `File.close()` が無改造で動く。
- 型 ID 照合があるため、`plugin:window` のリソースを `fs.read` に渡しても `BadResourceId` で落ちる。

### 2.3 ファイル位置は Zig 側で持つ

Zig 0.17 の `std.Io.File` は `seek` の syscall ラッパーを公開していない（`fileSeekTo` は vtable のみ）。
そこで `FileHandle.pos` を自前で管理し、読み書きは `readPositional` / `writePositional` で行う。

- `seek(offset, whence)` は `Start` / `Current` / `End` を `pos` と `file.length()` から計算する。
- `seek` の戻り値は「新しい位置」（本家と同じ）。
- 位置指定 I/O なので、同じ `rid` を並行利用しても **OS のファイルオフセット競合が起きない**。

### 2.4 バイナリは「戻り値は raw、引数は Base64」

| 方向 | 形式 | 理由 |
|---|---|---|
| `read_file` / `read` の戻り値 | `application/octet-stream` の生バイト列 | `zts_rpc` は `Bytes` をトップレベルで返すと base64 を付けず raw body にする。本家 Tauri の `ipc::Response::new(Vec<u8>)` と一致 |
| `write_file` / `write` の引数 | Base64 文字列（`rpc.Bytes`） | invoke の引数は JSON オブジェクト。構造体フィールド内の `Bytes` は Base64 |

### 2.5 名前は本家のまま（誤植も含む）

`FileInfo` は本家 v2 の `fileAttribues`（正しくは `file_attributes`）という綴りを **そのまま踏襲** する。
フロントエンドの `FileInfo` 型定義がこの名前で参照しているため、直すと互換性が壊れる。

## 3. 影響

- `src/tauri/fs/` は `zts_rpc` / `zts_tauri.path` / `zts_tauri.resources` のみに依存し、
  `link_libc = false` を維持する（`zts_webview` の「foundation のみ依存」制約とは独立）。
- `zts_rpc.naming.snakeToCamel` の comptime 分岐上限を 20,000 に引き上げた
  （`FileInfo` の 17 フィールドで既定の 1000 を超えたため。`O(len)` のループなので安全）。
- 未使用コマンドは DCE で 0 バイトになる（`src/tauri` の既存方針どおり）。

## 4. 却下した代替案

| 案 | 却下理由 |
|---|---|
| 字句正規化のみ（リンク解決なし） | `root/link -> /` を置かれた時点で全ファイルが読める |
| リンク解決に `realPath`（OS 任せ）を使う | 対象が存在しないと失敗する（`create` / `mkdir` で使えない）。ループ検出の可否も OS 依存 |
| `startsWith` による prefix 比較 | `/srv/app` と `/srv/app-evil` を区別できない |
| スコープ検査を JavaScript 側で行う | フロントは信頼できない入力元。境界はネイティブ側に置く |
