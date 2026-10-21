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
