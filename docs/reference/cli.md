# コマンドリファレンス

Z-Ts のコマンドは 2 系統あります。

1. **`./zigw`** — ゼロ設定の Zig ラッパー（このリポジトリ専用・Python 3 だけ必要）
2. **`zig build <step>`** — `build.zig` が定義するステップ

`zts`（アプリ作者向けの CLI）は `M5-02` として実装中で、引数解析と `init` テンプレートまで
出来ています（[`../tasks/M5-02-cli.md`](../tasks/M5-02-cli.md)）。

---

## `./zigw`

Zig 0.17.0 を PyPI の wheel から自動導入し、`zig` の代わりに何でも受けます。

| コマンド | 内容 | 所要時間（コールド） |
|---|---|---|
| `./zigw quick-test [args…]` | **`std.Build` を介さず** に全モジュールの単体テストを実行 | 約 8 秒（2 回目以降 0.03 秒） |
| `./zigw full-test [args…]` | `zig build test` と同じ（全ステップ・E2E 含む） | 初回 90 秒以上（CI はキャッシュで高速） |
| `./zigw build [step] [opts…]` | `build.zig` のステップを実行 | ステップ次第 |
| `./zigw build-exe <file>` | 単一ファイルをそのままコンパイル | 数秒 |
| `./zigw version` | Zig のバージョン（= 導入確認） | 4 秒 / 0 秒 |

`quick-test` が回すモジュール（すべて `link_libc = false` の純 Zig）:

```text
src/webview/mod.zig  src/tauri/mod.zig  src/wasm/mod.zig  src/ssg/mod.zig
src/cli/mod.zig      src/docsite/mod.zig  src/root.zig
```

## `zig build` のステップ

### 既定（`./zigw build`）

デスクトップ本体・Live Preview サーバ・wasm バンドル・SSG の `dist/` をまとめて
`zig-out/` に出力します。

### テスト

| ステップ | 内容 |
|---|---|
| `test` | 全パッケージの単体テスト + C99 ABI 検証 + Node 22 / WebKit2GTK の E2E + `check-bindings` |
| `quick-test`（`./zigw` 側） | 上記のうち `std.Build` を必要としない部分だけを高速に |

### フロントエンド / 型

| ステップ | 内容 |
|---|---|
| `tsgen` | スキーマから `examples/counter/web/bindings.gen.ts` を再生成 |
| `check-bindings` | 生成物が古ければ **exit 1**（`zig build test` が依存しているので CI で必ず走る） |

### ドキュメント

| ステップ | 内容 |
|---|---|
| `docs` | `docs/**/*.md` を `zig-out/docs/` に描画（リンク検査つき・81 ページ） |

### OS バックエンドの切り替え

| オプション | 既定 | 内容 |
|---|---|---|
| `-Dgtk=<bool>` | Linux では `pkg-config` で自動判定 | GTK3 + WebKit2GTK 4.1 バックエンド |
| `-Dmacos=<bool>` | macOS ターゲットで自動有効 | Cocoa + `WKWebView`（Objective-C シム） |
| `-Dwindows=<bool>` | Windows ターゲットで自動有効 | Win32 + Direct WebView2 |
| `-Dwasm-optimize=<mode>` | `small` | wasm デモバンドルの最適化（`debug`/`safe`/`fast`/`small`） |
| `-Dtarget=<triple>` | ホスト | 例: `-Dtarget=x86_64-windows-gnu`、`-Dtarget=aarch64-macos` |
| `-Doptimize=<mode>` | `Debug` | `Debug` / `ReleaseSafe` / `ReleaseFast` / `ReleaseSmall` |

```bash
# GPU の無い CI / コンテナで
WEBKIT_DISABLE_DMABUF_RENDERER=1 ZTS_WEBVIEW_SOFTWARE_RENDER=1 \
  xvfb-run -a ./zigw build test -Dgtk=true

# Linux から Windows 版をクロスコンパイル（単一 PE・DLL 不要）
./zigw build -Dtarget=x86_64-windows-gnu
```

### サンプル（`examples/*`）

各サンプルは独立した `build.zig` を持ち、ルートを `path = "../.."` で参照します。

```bash
cd examples/counter
../../zigw build desktop    # ネイティブ WebView の単一バイナリ
../../zigw build live       # Live Preview サーバ（SSE）
../../zigw build preview    # 0.0.0.0:8788 で起動
../../zigw build dist       # サーバ不要の静的サイト
../../zigw build test       # 単体 + 実 TCP + 実 WebAssembly E2E
```

## スクリプト

| スクリプト | 内容 |
|---|---|
| `bash scripts/status.sh` | ブランチ・未コミット・並列エージェント・直近 CI を 1 画面に |
| `bash scripts/setup-toolchains.sh --sysroot` | GTK3 / WebKit2GTK の sysroot を導入 |
| `bash scripts/setup-toolchains.sh --rust` | リファレンス実装（Rust）のビルド環境 |
| `bash scripts/setup-toolchains.sh --submodules` | `vendor/{tauri,wry,tao}` を浅く展開 |
| `bash scripts/ci-logs.sh <run_id>` | Check Run API 経由で CI の要約を取得 |
| `python3 scripts/check-docs.py` | ドキュメント構造と相対リンクの検証 |
| `node scripts/check-font-coverage.mjs` | 同梱フォントが全使用文字を網羅しているか |
| `node scripts/verify-screenshots.mjs <dir>` | PNG の画素比較（3 OS パリティ） |
| `node scripts/gen-framework-demos.mjs [name]` | 9 フレームワークのデモを再生成 |

## `zts`（実装中）

設計上のコマンド面（`src/cli/args.zig` でテスト済み）:

```text
zts init [dir]          最小構成のプロジェクトを生成
  --dir/--name/--zts-path/--force
zts dev                 web/ を配信 + Zig の変更監視 → 再起動
  --dir/--host/--port/--browser
zts build               フロントエンドのバンドル + 単一実行ファイル
  --dir/--target/--debug/--frontend-only
zts help / zts version
```

未実装の部分（実行ファイル本体・`dev` の監視ループ・`build` の `zig build` 起動）は
[`../tasks/M5-02-cli.md`](../tasks/M5-02-cli.md) の DoD を参照してください。
