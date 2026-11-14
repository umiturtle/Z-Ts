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
  （`zig-out/dist`）を起動して headless Chrome で `live-counter.png` / `ssg-counter.png` を撮る。
  - **Live Preview には `--virtual-time-budget` を付けない**。SSE の接続が開きっぱなしだと
    仮想時間が永久に進まず Chrome が終了しない（Run `#40519060481` で実際にジョブが固まった）。
    ページは `load` 時点でスタイルシート適用済みなので、そのまま撮って非空白を検証すればよい。
  - SSG `dist/` は完全な静的配信なので `--virtual-time-budget=6000` で wasm 描画の完了を待つ。
  - 撮影は `timeout 90` でラップし、PNG が無ければ `SKIP browser-shot <name> <理由>` を出す。
    2 枚中 1 枚も撮れなかった場合だけ `::error::` + exit 1（**無言スキップ禁止**）。
    成功時は `OK browser-shots captured=n/2`。
  - Chrome が無い runner では `SKIP browser-shots no chrome/chromium on this runner`（exit 0）。
    ギャラリー本体のマーカーは別途必須なので、この SKIP で検証が消えることはない。
- 3 ジョブとも `timeout-minutes: 45` を持つ。ツールがハングしても runner を既定の 360 分
  占有しないため（実測: Linux のブラウザ撮影が無限待機した）。

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
| Linux のブラウザ撮影ステップが終わらない | Live Preview の SSE により `--virtual-time-budget` の仮想時間が進まない | Live には budget を付けず、`timeout 90` + `SKIP browser-shot` で必ず前進する |

> 失敗時の切り分けは `bash scripts/ci-logs.sh <run_id>` の `gallery:` 行を見る。
> 各パターンについて `no ready report (timed wait)` が出ていれば §3.3 の 1 行目、
> `bytes` が極端に小さいまま `OK` していれば撮影対象が空白、と判断できる。

---

## 4. OS 間パリティ・ジョブ（`M5-05`）

`ci-parity` は 3 つの OS ジョブが **すべて終わってから** 走り、成果物を 1 か所で比較する。

```yaml
ci-parity:
  if: always() && !cancelled()      # 1 つ落ちても「どこが違うか」を出す
  needs: [ci-linux, ci-macos, ci-windows]
  timeout-minutes: 15
  steps:
    - actions/download-artifact@v4  # pattern: screenshots-*
    - node scripts/verify-screenshots.mjs artifacts/screenshots-<os> --require-native --require-counts 17
    - node scripts/compare-screenshots.mjs artifacts/screenshots-linux artifacts/screenshots-macos \
        artifacts/screenshots-windows --max-diff 0.06 --max-mad 6 --json parity.json
    - Gate on the parity marker       # `OK parity hosts=…` が無ければ exit 1
    - actions/upload-artifact@v4      # parity-report（parity.json + parity.log、14 日）
```

- **マーカーが唯一の合格条件**: `OK parity hosts=linux,cocoa,win32 patterns=17 …`。
  `grep` に失敗したら `::error::` を出して落とす（無言スキップ禁止）。
- 比較に失敗したときのログはそのまま原因になる（例: `layout differs by 5px at box #3`）。
- `bash scripts/ci-logs.sh <run_id>` でも `parity.log` と同じ内容が読める。

### 4.1 3 OS のギャラリーが満たすべきこと

| 項目 | マーカー / フィールド | 落ちたときの意味 |
|---|---|---|
| ネイティブ描画 | `OK gallery host=gtk3\|cocoa\|win32 patterns=17 captured=17` | 1 パターンでも撮れていない |
| フォント | `manifest.font_ok === true` | 同梱 woff2 が読めていない（= Linux は豆腐） |
| レイアウト指紋 | `manifest.layout` が存在 | `document.fonts.ready` が発火していない |
| PNG 検証 | `OK screenshots host=… patterns=17 loose=N` | 白紙・寸法違い・SHA 不一致 |
| 3 OS 一致 | `OK parity …` | レイアウト / 画素 / 背景色の差 |

### 4.2 フォントを更新したとき

1. `pip install --break-system-packages fonttools brotli`
2. `python3 scripts/build-fonts.py`（`examples/gallery/src/web/fonts/` と `coverage.txt` を更新）
3. `node scripts/check-font-coverage.mjs` で緑を確認 → コミット

CI は生成物をそのまま使う（`npm`/`pip` を追加しない）。

### 4.3 9 フレームワークの再生成

`node scripts/gen-framework-demos.mjs [name…]`（ネットワーク必要）。
`examples/gallery/src/web/fw/<name>/` と `src/fw_assets.zig` が更新されるので、
`examples/frameworks/node_modules` と各 `dist/` はコミットしない（`.gitignore` 済み）。


---

## 5. リポジトリ改名と Check Run ログ公開（規約 18）

Arena サンドボックスからは Actions の生ログを置いてある Blob ホストに到達できないため、
各ジョブは `ci-output.log` / `cli-smoke.log` / `parity.log` を Check Run の `output.summary`
にもミラーしています。ここは**診断専用**で、ビルドの合否を左右してはいけません。

### 5.1 起きた障害

`main` へのマージで始まった run の実行中にリポジトリが改名されました。
`GITHUB_REPOSITORY` と `actions/github-script` の `context.repo` は**ラン開始時点の名前で固定**
されるため、改名後に `PATCH /repos/{旧名}/check-runs/{id}` を送ると
`HttpError: fetch failed` / HTTP 500 になります（GET はリダイレクトされるので
`listJobsForWorkflowRun` は通ってしまうのが厄介な点）。
実際に 6 ジョブが「Publish … to Check Run API」ステップだけで failure になり、
ビルド・テスト・スクリーンショット・parity 本体はすべて成功していました。

### 5.2 現在の契約

- 5 本の公開ステップは [`scripts/publish-check-run-summary.js`](../../scripts/publish-check-run-summary.js)
  を 1 箇所から呼ぶだけ。重複した Octokit 呼び出しは置かない。
- ヘルパーは最初に `GET /repos/{owner}/{repo}` を行い、レスポンスの `full_name` を
  **現在の正規名**として使う。イベントペイロードの名前は fallback にすぎない。
- すべての公開ステップに `continue-on-error: true` を付け、API 不通・改名競合・
  レート制限でもジョブを赤くしない。3 回（初回 + 2 リトライ）失敗したら `core.warning` を出す。
- 同じログを `$GITHUB_STEP_SUMMARY` にも書く。Check Run API が完全に落ちても記録は残る。
- `output.summary` は UTF-8 バイト数で 60000 に丸める（日本語ログで 65535 制限を超えないため）。
- `.github/workflows/pages.yml` も `gh api repos/${GITHUB_REPOSITORY}` の `full_name` を
  解決してから `…/pages` を呼ぶ。POST は旧名だと失敗し得る。
- `node --test tests/ci/publish-check-run-summary.test.cjs` が旧名解決・リトライ・
  永続失敗・UTF-8 丸め・ジョブ名不一致を検証する。
- `check-docs.py` の規約 18 がヘルパー・5 ステップ・Pages・テスト・本ページの一致を
  機械検査する。

> 旧リポジトリ URL とチェックアウトのパス名は規約 14 により据え置きです。
> `github.com` 側はリダイレクトされますが、GitHub Pages のサブパスは変わるので、
> 公開サイトの URL を変更する場合は別タスクで扱います。

<!-- zts-doc-meta: source-version=0.1.1 verified=2026-10-21 last-rewritten=2026-11-14 -->
