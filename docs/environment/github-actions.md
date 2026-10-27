# GitHub Actions 活用ガイド（永続キャッシュ CI・マルチOS検証・ログ取得）

Arena ローカル環境は「Linux x86_64 ヘッドレス・毎チャットキャッシュ揮発・`crates.io` 非接続」という特性を持つため、**[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)** と役割分担して開発を進めます。

---

## 1. ローカル vs GitHub Actions の役割分担

| 検証項目 | Arena ローカル | GitHub Actions |
|---|---|---|
| Pure Zig 単体テスト・TDD ループ | ◎ **主戦場**（`./zigw quick-test`：コールド 5.0s / 2回目 **0.02s**） | ○ 回帰検証 |
| `build.zig` パッケージビルド検証 (`zig build test`) | △ コールド時 94s かかるため `build.zig` 編集時のみ | ◎ **`actions/cache@v4` 永続キャッシュにより 19秒〜で常時自動検証** |
| Linux GTK3 / WebKit2GTK E2E 検証 | ○ `--sysroot` でリンク検証（4.8s） | ◎ **`xvfb-run` 仮想 X11 画面で実ウィンドウ・WebView 起動 E2E 実行** |
| macOS (`AppKit` / `WKWebView`) ビルド & テスト | △ クロスコンパイル構文確認のみ | ◎ **`macos-latest` (arm64) 実機でネイティブビルド & 実行** |
| Windows (`Win32` / `WebView2`) ビルド & テスト | △ PE クロスコンパイル確認のみ | ◎ **`windows-latest` (x64) 実機でネイティブビルド & 実行** |
| 本家 Rust Tauri（`crates.io` 依存込み）との差分テスト・ベンチマーク | △ 単体クレート FFI のみ | ◎ **フルインターネット & 安定 CPU 環境で正確に計測・比較** |

---

## 2. エージェントからの CI 実行・ログ取得手順（重要）

macOS / Windows 固有コード、`build.zig`、GUI E2E テスト、ベンチマークを変更した際は、現在の作業ブランチへ push して CI 結果を必ず確認すること：

```bash
# 1. 現在のセッションブランチに push して CI をトリガー
git push -u origin "$(git branch --show-current)"

# 2. 実行中のワークフロー Run ID を確認
gh run list --branch "$(git branch --show-current)" --limit 5

# 3. 完了まで待機し、終了コードで成否を判定
gh run watch <run_id> --exit-status

# 4. 全ジョブ（Linux / macOS / Windows）の標準出力・エラー出力・ベンチマーク結果を取得
bash scripts/ci-logs.sh <run_id>
```

> **重要（Arena ファイアウォール対策・実機検証済み）**:
> `gh run view <run_id> --log` は外部ストレージ `results-receiver.actions.githubusercontent.com` へリダイレクトされるため、Arena サンドボックスからは `EOF` でブロックされます。
> そのため、`.github/workflows/ci.yml` の全ジョブはビルド・テスト・ベンチマーク出力を **`$GITHUB_STEP_SUMMARY` へ自動ミラーリング** しており、`bash scripts/ci-logs.sh` は許可ホストである `api.github.com` の Check Runs API 経由で全出力を確実に取得します。新しく CI ジョブ・ステップを追加する際も、必ず `| tee -a "$GITHUB_STEP_SUMMARY"` パターンを維持してください。

---

## 3. スクリーンショット回帰（`M5-04`）

3 OS すべてで **実描画を PNG に落とし、機械検証して artifact に残す**。ローカルの Arena 環境には
`DISPLAY` が無く、macOS SDK / Windows 実機も無いため、**画像が得られるのは CI だけ**である。

### 3.1 ジョブ構成（全 OS 共通の 3 ステップ）

| ステップ | 内容 | 出力マーカー |
|---|---|---|
| `Screenshot gallery — native …` | `examples/gallery` を build → `zts_gallery --out $RUNNER_TEMP/shots --require-native` → `node scripts/verify-screenshots.mjs … --require-native --require-counts 8` | `OK gallery host=<gtk3\|cocoa\|win32> patterns=8 captured=8` / `OK screenshots host=… patterns=8 loose=N` |
| `Gate on the screenshot markers` | 上の 2 マーカーを `grep` で必須化（無ければ `::error::` + exit 1） | — |
| `Upload screenshots (<OS>)` | `actions/upload-artifact@v4`、`name: screenshots-<os>`、`retention-days: 14`、`if: always()` | — |

- Linux は `xvfb-run -a` + `WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_COMPOSITING_MODE=1
  ZTS_WEBVIEW_SOFTWARE_RENDER=1` で仮想 X11 上に GTK ウィンドウを出す。
- `--require-native` は「`HeadlessMock` にフォールバックしたら即 exit 1」のスイッチ。
  `verify-screenshots.mjs` 側も `host=mock` を拒否するので、**仮想ディスプレイの取りこぼしが
  無言の成功にならない**。
- Linux のみ追加で `Browser captures of the Live Preview & SSG builds` ステップを持ち、
  `counter-live --port 8791`（BridgeServer + SSE）と `python3 -m http.server 8792`
  （`zig-out/dist`）を起動して headless Chrome（`--virtual-time-budget=6000`）で
  `live-counter.png` / `ssg-counter.png` を撮る。Chrome が無い runner では
  `SKIP browser-shots …`（exit 0）を出し、他のマーカーは依然必須。

### 3.2 artifact の見方

- GitHub UI: Actions → 該当 Run → Artifacts → `screenshots-linux` / `screenshots-macos` /
  `screenshots-windows` をダウンロード。展開すると `index.html`（コンタクトシート）が入っており、
  8 パターン + manifest の実寸・SHA-256 が 1 画面で確認できる。
- エージェント（Arena サンドボックス）: artifact のダウンロードは外部ストレージへ
  リダイレクトされるため **不可**。代わりに `bash scripts/ci-logs.sh <run_id>` で
  `OK gallery …` / `OK screenshots …` と各パターンの `name WxH bytes messages=N -> file` 行を読む。
  画素レベルの失敗は verifier が `FAIL screenshots <pattern>: <理由>` で落とすので、ログだけで原因が分かる。

### 3.3 失敗しやすいポイント（実測）

| 症状 | 原因 | 対処 |
|---|---|---|
| Windows で 8 枚とも 1 色（数百 bytes） | WebView2 の起動が遅く、固定 sleep では `ContentLoading` 前に `CapturePreview` を呼んでいた（S_OK のままハンドラが来ない） | ページが `load` 時に `{ready,w,h,dpr}` を投稿 → ギャラリーが最大 20 秒待つ |
| macOS で中心画素が期待値と違う | runner の画面が 1024×674 でウィンドウがクランプされ、中央にカードが来ていた | 要求サイズを縮小し、撮影はページ申告の実ビューポート。カードは下端寄せ |
| Windows だけ真っ白・`messages=0` | `gallery://` は WebView2 が解釈できない（写像されるのは `tauri`/`ipc`/`asset` のみ） | ギャラリーのスキームを `tauri` にし、ページは相対 URL で `fetch('/api/state')` |
| `SKIP … no chrome/chromium` が Linux で出る | runner イメージに Chrome が無い | 許容（`SKIP` は exit 0）。ギャラリー本体のマーカーは別途必須 |

> 失敗時の切り分けは `bash scripts/ci-logs.sh <run_id>` の `gallery:` 行を見る。
> 各パターンについて `no ready report (timed wait)` が出ていれば §3.3 の 1 行目、
> `bytes` が極端に小さいまま `OK` していれば撮影対象が空白、と判断できる。
