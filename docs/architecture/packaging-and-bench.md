# パッケージャと対 Rust ベンチマーク（`M5-03`）

> **内部資料です。** アプリ作者が読む必要はありません。使い方は
> [`../guides/packaging.md`](../guides/packaging.md)、CLI の仕様は
> [`../reference/cli.md`](../reference/cli.md#zts-package) にあります。

このページは「なぜこの形にしたか」と「どこまで作り、どこをまだ作っていないか」の記録です。
タスクの進捗チェックリストは [`../tasks/M5-03-packager-and-bench.md`](../tasks/M5-03-packager-and-bench.md)
が正本で、このページは設計判断だけを持ちます。

---

## 1. 全体像

```text
src/bundler/                 純 Zig・`link_libc = false`・I/O は最後の 1 箇所だけ
├── app.zig      メタデータ（App）と、control / .desktop / Info.plist / AppRun の文字列
├── plan.zig     仮想パッケージ（Entry{path, mode, bytes} のソート済み配列）
├── deb.zig      ar + control.tar.gz + data.tar.gz（再現可能）
├── tree.zig     plan をディレクトリに書く唯一のモジュール
├── ico.zig      .ico の解析と GRPICONDIR 生成
├── pe.zig       完成済み PE に `.rsrc` セクションを追記
└── binary.zig   実行ファイルのコンテナ形式と CPU を読む

src/cli/main.zig             bundler を呼ぶだけ（文字列整形と `hdiutil` 以外のロジックを持たない）
```

`src/bundler/` は `src/cli/` からも `src/` の他モジュールからも独立した 1 モジュール
（`zts_bundler`）です。`build.zig` でモジュールを作り、`zts` の exe にだけ `imports` します。

**依存はゼロ。** `zts_foundation` すら使いません。パッケージャは「入力のバイト列 → 出力の
バイト列」の関数の集まりで、時刻も乱数も環境も読みません（実行ファイルの解析だけが入力依存）。

---

## 2. 判断と、却下した案

### 2.1 Windows のリソースは PE を後から書き換える

| 案 | 結果 |
|---|---|
| `std.Build.Step.Compile` の Win32 リソース API | **存在しない**（Zig 0.17 に `addWin32ResourceFile` は無い） |
| `.rc` を書いて `zig rc` でコンパイル | `zig rc` は無い。外部の `windres` は CI の 3 OS に揃わない |
| **PE の `.rsrc` を自前で追記**（採用） | ツールチェーン不要。3 OS のどこでも同じ結果。テストは合成 PE で完全に再現できる |

`pe.zig` は PE32 / PE32+ を 1 つのパーサで扱います（DataDirectory のオフセットが 96 / 112 と
違うだけ）。行うこと:

1. `NumberOfSections` を 1 増やし、`.rsrc` のセクションヘッダを書く
2. RVA = 既存最大セクション末尾を `SectionAlignment` に切り上げた値
3. `SizeOfInitializedData` と `SizeOfImage` を更新
4. DataDirectory[2] を新しい `.rsrc` に向ける
5. チェックサムを再計算（`SizeOfImage` を変えると無効になるため必須）

既に `.rsrc` がある実行ファイルは `error.ResourceSectionExists` で拒否します。二重注入は
リソース ID を壊すので、黙って追記しません。

### 2.2 アーキテクチャはホストではなく実行ファイルから読む

`zts build --target aarch64-linux && zts package` は普通に起きます。ホストの `builtin.cpu.arch`
を使うと `amd64` と嘘をつく `.deb` ができます。`binary.zig` は ELF の `e_machine`、Mach-O の
`cputype`、PE の `Machine` を読み、未知の値は `error.UnknownArchitecture` で止めます。
`--arch` フラグを足さなかったのは、**正解が常にバイト列の中にある**からです。

### 2.3 `Depends:` は実行ファイルの `DT_NEEDED` から作る

GTK を決め打ちすると、ウィンドウを開かないアプリに 100 MB の依存が付きます。ELF の文字列
テーブルに soname（`libgtk-3.so`、`libwebkit2gtk-4.1.so`）があるかだけを見て、
`Depends:` を組み立てます。見つからなければ行ごと省略します。

### 2.4 `control` に `License:` を書かない

Debian のバイナリ `control` に `License:` というフィールドは存在しません（`lintian` が警告
します）。ライセンスは `usr/share/doc/<pkg>/copyright`（machine-readable 形式）に書きます。
これは `dpkg-deb -I` が受理するかどうかとは別の話で、「通るが正しくない」を避けました。

### 2.5 再現性: mtime 0・所有者 0/0

`std.tar.Writer` の `Options.mtime` は既定が**現在時刻**です。`.{ .mtime = 0 }` を全エントリで
明示し、`ar` のヘッダも mtime 0・uid/gid 0 に固定しています。同じ実行ファイルからは同じ
`.deb` が出ます（テスト `deb.test.packaging the same payload twice is byte-identical`）。

### 2.6 `dmg` だけは外部ツールを呼ぶ

`.dmg` は HFS+/APFS のディスクイメージで、純 Zig で書く価値がありません。macOS の `hdiutil`
に `.app` を渡すだけにし、**macOS 以外のホストでは明示的に失敗**させます。

---

## 3. テスト戦略

| モジュール | 何を固定しているか | 本数 |
|---|---|---|
| `app` | 名前・版・識別子の検証、control / `.desktop` / `Info.plist` / `AppRun` のバイト列 | 12 |
| `plan` | 4 レイアウトのパス集合・モード・ソート順・重複排除 | 4 |
| `deb` | ar の 3 メンバ、gzip、md5sums の書式、再現性 | 5 |
| `tree` | 親ディレクトリ作成・実行ビット・上書き | 2 |
| `ico` | 256 の 0 表現、GRPICONDIR の 1 始まり ID、壊れた入力 | 3 |
| `pe` | セクション追加、リソースツリーの歩行、二重注入の拒否、非 PE 入力 | 4 |
| `binary` | ELF / Mach-O / PE の判定と未知アーキテクチャ | 4 |

すべて `std.testing.allocator`（リーク検出付き）で走ります。`ico`/`pe` のテストは合成ヘッダを
組み立てるので、実バイナリも OS も要りません。

CI では `ci-cli` ジョブが 3 OS で `zts init` → `zts build` → `zts package --format tar.gz` を
実際に流します（`zig-out/package/*.tar.gz` の生成と `zts doctor` の成功まで）。

---

## 4. 対 Rust 本家ベンチマーク（スライス C・未着手）

`M5-03` の後半は `vendor/tauri` の Rust 版との比較です。6 指標を GitHub Actions の
Check Summary に出します。

| 指標 | 測り方 | 注意 |
|---|---|---|
| クリーンビルド | `rm -rf .zig-cache zig-out` / `cargo clean` してからの wall clock | コールドスタートのキャッシュ権限を揃える |
| 1 行変更インクリメンタル | 1 ファイルに 1 行足して再ビルド | 編集対象を同じレイヤ（UI の 1 行）に揃える |
| バイナリサイズ | `ReleaseSmall` / `ReleaseFast` vs `cargo --release` + `strip` | macOS は `strip -x`、Windows は `llvm-strip` |
| 初回描画までの起動 | プロセス起動 → 最初のフレーム提示 | ヘッドレス CI では Xvfb + `zts_webview` のスクリーンショットで代替 |
| RSS（idle / load） | 起動 5 秒後と、負荷ページ表示後 | `/proc/<pid>/status` / `ps -o rss` |
| IPC | 小さい JSON 10,000 往復 + 64 MB Raw のスループット | 往復は `invoke` の round-trip、Raw は `Channel`/`RawPayload` |

Rust ツールチェーンは `scripts/setup-toolchains.sh --rust` でしか入らないため、このベンチは
**CI 専用ジョブ**にします。ローカルでは `--skip-rust` で Z-Ts 側だけ測ります。

数値を README に手で書かないこと。ベンチは必ず CI の Check Summary を正とします（手で書いた
数値は環境が変わると嘘になるため）。

---

## 5. 未解決・先送り

| 項目 | 状態 |
|---|---|
| `.icns` 生成 | 未対応。`iconutil` は macOS 専用なので PNG 同梱で代替中 |
| macOS のコード署名 / notarytool | 未対応（`zts` は署名しない）。配布手順で `codesign` を案内 |
| AppImage の実生成 | 未対応。AppDir まで作り `appimagetool` を案内 |
| MSI / MSIX | 未対応。`.exe` まで |
| ベンチ 6 指標 | スライス C。上記 §4 の設計のみ |
| `zts package` の `--arch` | 意図的に作らない（§2.2） |
