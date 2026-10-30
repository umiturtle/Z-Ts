# `plugin:fs` — スコープ付きファイルシステム

`src/tauri/fs/` は `@tauri-apps/plugin-fs` v2 の wire 互換実装で、**Pure Zig（`link_libc = false`）**。
ファイルに触れる前に必ず **字句正規化 → シンボリックリンク解決 → 包含判定** を通す（設計判断は
[ADR-0011](../decisions/0011-scoped-fs-plugin.md)）。

```text
フロントエンド      Zig
  invoke('plugin:fs|read_text_file', { path: '../etc/passwd' })
        │
        ▼
   FsState.resolve(scratch, raw, base_dir)
        1. BaseDirectory (1..23) を PathState で解決 → 絶対化
        2. path.normalizeWithStyle           … `.` / `..` を畳む
        3. scope.canonicalizeAlloc           … 各成分の sym_link を最大 40 ホップ展開
        4. scope.allowsPath                  … 成分単位で roots に含まれるか
        │
   ┌────┴────┐
   │ 許可     │ 拒否 → {"code":"OutOfScope"}（HTTP 400）
   ▼
  Io.Dir / Io.File で実 I/O（root 内であることは確定済み）
```

## 1. モジュール構成

| ファイル | 役割 |
|---|---|
| `scope.zig` | `Root`（recursive 可否つき）、`Scope`、`canonicalizeAlloc`、`allowsPath`、`splitRoot`、`pathEql` |
| `commands.zig` | `FsState`（scope + `ResourceTable` + `PathState`）、`FileHandle`、`FileInfo`、`plugin:fs|*` 全コマンド |
| `mod.zig` | 再エクスポートと使用例 |

## 2. 配線

```zig
var scope = try fs.Scope.initCanonical(alloc, io, .current(), &.{
    .{ .path = app_data_dir },                     // ディレクトリ丸ごと
    .{ .path = config_file, .recursive = false },  // 単一ファイル
});
defer scope.deinit();

var fs_state = fs.FsState.init(alloc, io, scope, &resources, &paths);
defer fs_state.deinit();

const App = rpc.merge(.{ MySchema, rpc.Schema(.{ .fs = fs.Commands }) });
var router = App.bind(.{ .my_command = &my_state, .fs = &fs_state });
```

`Scope.init` は **字句正規化のみ**（ルートが symlink を含まないと分かっている場合）、
`initCanonical` は **起動時に一度だけ** ルートを実パスへ解決する（通常はこちら）。

## 3. コマンド一覧

`rpc_prefix = "plugin:fs|"`。引数は `@tauri-apps/plugin-fs` v2 の `camelCase` と 1:1。

| コマンド | 引数 | 戻り値 |
|---|---|---|
| `read_text_file` | `path`, `options?{baseDir}` | `string` |
| `read_file` | 同上 | 生バイト列（`application/octet-stream`） |
| `write_text_file` | `path`, `data`, `options?{baseDir,append,create,createNew}` | `null` |
| `write_file` | `path`, `data`（Base64）, 同上 | `null` |
| `exists` | `path`, `options?` | `bool` |
| `stat` / `lstat` | `path`, `options?` | `FileInfo` |
| `size` | `path`, `options?` | `number`（ディレクトリは再帰合計、64k エントリ上限） |
| `mkdir` | `path`, `options?{baseDir,recursive}` | `null` |
| `remove` | `path`, `options?{baseDir,recursive}` | `null` |
| `rename` | `oldPath`, `newPath`, `options?{oldPathBaseDir,newPathBaseDir}` | `null` |
| `copy_file` | `fromPath`, `toPath`, `options?` | `null` |
| `read_dir` | `path`, `options?{baseDir}` | `DirEntry[]` |
| `create` | `path`, `options?{baseDir}` | `rid` |
| `open` | `path`, `options?{baseDir,read,write,append,truncate,create,createNew}` | `rid` |
| `read` | `rid`, `len` | 生バイト列 |
| `write` | `rid`, `data`（Base64） | `number`（書いたバイト数） |
| `seek` | `rid`, `offset`, `whence`（0=Start,1=Current,2=End） | `number`（新位置） |
| `fstat` | `rid` | `FileInfo` |
| `truncate` / `ftruncate` | `path`+`len` / `rid`+`len` | `null` |
| `plugin:resources|close` | `rid` | `null`（ハンドル解放） |

`FileInfo` は本家と同じ `camelCase`。**`fileAttribues` は上流の綴り（誤植）をそのまま維持** する。
`birthtime` は `std.Io.File.Stat` が公開していないため常に `null`。

## 4. エラー

`error.T` は `{"code":"T"}`（HTTP 400）に変換される。

| コード | 発生条件 |
|---|---|
| `OutOfScope` | 正規化・リンク解決後のパスがすべての root の外 |
| `SymLinkLoop` | リンク展開が 40 ホップを超えた |
| `CannotVerify` | 存在する成分の `lstat` / `readlink` が権限等で失敗（fail-closed） |
| `InvalidPath` | 空パス / NUL を含む / 未知の `baseDir` / `whence` / 負の `seek` |
| `NotFound`, `AlreadyExists`, `AccessDenied`, `NotADirectory`, `IsADirectory`, `DirectoryNotEmpty`, `ReadOnlyFileSystem`, `NameTooLong` | OS エラーの写像 |
| `FileTooLarge` | 1 回の読み書きが 16 MiB 超、またはサイズ計算が 64k エントリ超 |
| `BadResourceId` | 偽造 / 二重 close / 別プラグインの `rid` |

## 5. セキュリティ上の注意

- **`read_dir` はリンク自身を報告する**。リンク先が scope 外でもエントリ名は返るが、
  その先を読むには別コマンドが必要で、そこでもう一度スコープ判定が走る。
- **`size` はリンクを辿らない**（scope 外の巨大ファイルのサイズを漏らさない）。
- **書き込み先は「解決後のパス」**。`open` 時のリンク解決と実際の書き込みの間にリンクを差し替える
  TOCTOU は理論上残る（本家も同じ）。信頼できないディレクトリを root にしないこと。
- ハンドルは `ResourceTable` の型 ID で守られるため、`plugin:window` の `rid` を渡しても通らない。
