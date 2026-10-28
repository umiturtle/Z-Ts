# Task M4-02: スコープ付きファイルシステムプラグイン（`src/tauri/fs/`）

- **Status**: `review` <!-- todo | in_progress | review | done | blocked -->
- **Branch**: `arena/16ce0c2f-z-ts`
- **Scope**: `src/tauri/fs/`（`mod.zig` / `scope.zig` / `commands.zig`）, `src/tauri/mod.zig`, `docs/tasks/M4-02-scoped-fs.md`, `docs/architecture/tauri-fs-plugin.md`, `docs/decisions/0011-scoped-fs-plugin.md`, `docs/INDEX.md`, `docs/roadmap/m2-m5-platform-and-ecosystem.md`
- **Upstream Reference**: `@tauri-apps/plugin-fs` v2（`plugins-workspace/plugins/fs/src/commands.rs` / `guest-js/index.ts`）
- **Next Step**: CI（Linux / macOS / Windows）で `plugin:fs` のシンボリックリンク検査が通ることを確認する（Windows は Developer Mode 無効なら該当テストのみスキップされる）。

---

## 1. 目的と完了条件（Definition of Done）

**目的**: Tauri v2 の `plugin:fs|*` を Pure Zig（`link_libc = false`）で再実装し、
**シンボリックリンク経由のスコープ脱出を構造的に不可能**にする。

- [x] `OsPath`（WTF-8 / 非 UTF-8）対応のパス解決（`src/tauri/path.zig` の正規化・`BaseDirectory` を再利用）
- [x] スコープ判定: 字句正規化 → シンボリックリンク解決（ホップ上限あり）→ ルート包含判定
- [x] 読み書き・ディレクトリ走査・メタデータ・リソース（`rid`）ベースのストリーム入出力
- [x] 単体テスト: 正常系 / `..` 脱出 / シンボリックリンク脱出 / リンク内包 / Windows 形式パス / リーク検査
- [x] `./zigw quick-test` / `./zigw build test` / `python3 scripts/check-docs.py` / `./zigw fmt --check` のパス
- [ ] 3 OS CI グリーン

---

## 2. 現在の進捗チェックポイント（Context Reset 復元用）

- **完了したこと**:
  - 上流 `commands.rs` / `guest-js/index.ts` のワイヤ仕様を確認（コマンド名・引数・戻り値・`FileInfo` フィールド名）。
  - `scope.zig`: `splitRoot`（POSIX / ドライブ / UNC）、`pathEql`（Windows は ASCII 畳み）、`allowsPath`（成分単位）、
    `canonicalizeAlloc`（`lstat` → `readLink` → 字句再正規化を 40 ホップまで）、`Scope.init/initCanonical/resolveAlloc`。
  - `commands.zig`: 20 コマンド（`read_text_file` / `read_file` / `write_*` / `exists` / `stat` / `lstat` / `size` /
    `mkdir` / `remove` / `rename` / `copy_file` / `read_dir` / `create` / `open` / `read` / `write` / `seek` /
    `fstat` / `truncate` / `ftruncate`）、`FsState.resolve`、`FileHandle`（`ResourceTable` 上の `rid`）。
  - テスト 19 件（`zts_tauri`）: 純粋な包含判定 3 件 + 実 FS 3 件 + RPC 往復 3 件。`./zigw quick-test` 全緑。
- **作業中・直前の状態**:
  - `./zigw build test` 41/41 ステップ成功、`check-docs` 44 ファイル OK、`fmt --check` OK。CI 待ち。

---

## 3. 設計判断・技術メモ・ハマりどころ

- **`std.Io.File` に `seek` が無い**（vtable の `fileSeekTo`/`fileSeekBy` はあるが公開ラッパーが無い）。
  → `FileHandle.pos` を自前で持ち、`readPositional` / `writePositional` で I/O する。OS のオフセットを共有しないので並行利用も安全。
- **トップレベルの `Bytes` 戻り値は raw body**（`serializeCommandResult` が `application/octet-stream` を返す）。
  本家 Tauri の `ipc::Response::new(Vec<u8>)` と同じ挙動なので、テストは Base64 ではなく生バイト列で検証する。
  invoke の **引数** は JSON なので `write_file` / `write` の `data` は Base64。
- **`snakeToCamel` の comptime 分岐上限**: `FileInfo` の 17 フィールドで既定 1000 を超え
  `error: evaluation exceeded 1000 backwards branches`（`src/rpc/naming.zig:56`）。→ `snakeToCamel` 内で
  `@setEvalBranchQuota(20_000)` を設定（呼び出し側ごとに書くと漏れるため関数内に置く）。
- **`Dir.rename` の引数順**は `(old_dir, old_sub_path, new_dir, new_sub_path, io)`。`io` が最後。
- **`statFile` のエラーに `OutOfMemory` は無い**ので `catch |err| switch (err)` に `error.OutOfMemory` を書くとコンパイルエラー。
- **Windows は `symLink` に Developer Mode か管理者権限が必要**。テストは `error.AccessDenied` / `PermissionDenied` を
  受けたらリンク部分だけスキップする（他の OS では必ず実行される）。
- **`error.PrivilegeNotHeld` は `symLink` のエラー集合に含まれない**ので catch に書くとコンパイルエラー。
