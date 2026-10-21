# GitHub Actions 活用ガイド（CI・キャッシュ供給・マルチOS検証）

Arena ローカル環境は「Linux x86_64 ヘッドレス・毎チャットキャッシュ揮発・`crates.io` 非接続」という特性を持つため、**[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)** と役割分担して開発を進めます。

---

## 1. ローカル vs GitHub Actions の役割分担

| 検証項目 | Arena ローカル | GitHub Actions |
|---|---|---|
| Pure Zig 単体テスト・TDD ループ | ◎ 主戦場（`./zigw test` で 0.1 秒） | ○ 回帰検証 |
| Linux GTK3 / WebKit2GTK リンク検証 | ○ `--sysroot` でビルド・リンク検証可 | ◎ **`xvfb-run` 仮想 X11 画面で実ウィンドウ・WebView 起動 E2E 実行** |
| macOS (`AppKit` / `WKWebView`) ビルド & テスト | △ クロスコンパイル構文確認のみ | ◎ **`macos-latest` 実機でネイティブビルド & 実行** |
| Windows (`Win32` / `WebView2`) ビルド & テスト | △ PE クロスコンパイル確認のみ | ◎ **`windows-latest` 実機でネイティブビルド & 実行** |
| 本家 Rust Tauri（`crates.io` 依存込み）との差分テスト・ベンチマーク | △ 単体クレート FFI のみ | ◎ **フルインターネット & 永続キャッシュ環境で正確に計測・比較** |
| Zig グローバルキャッシュの事前ビルド供給 | 受信側（`codeload.github.com` 経由 1.5秒） | ◎ **`warm-zig-cache` ジョブが `ci-cache-linux-x64` ブランチへ自動発行** |

---

## 2. 事前ウォームアップキャッシュ (`ci-cache-linux-x64`) の仕組み

1. `main` または `arena/**` ブランチへ push されると、`warm-zig-cache` ジョブが Arena ローカルと同一の `ziglang==0.17.0` バイナリで `zig build test` および Linux `-lc` スタブをコンパイルします。
2. 生成された `~/.cache/zig` を `zig-cache.tar.gz` に圧縮し、Git 履歴を持たない単一コミットの orphan ブランチ **`ci-cache-linux-x64`** に `--force` push します（`main` や作業ブランチの履歴は一切肥大化しません）。
3. 新しい Arena チャットでエージェントが `./zigw build test` を実行すると、`./zigw` が `https://codeload.github.com/<owner>/<repo>/tar.gz/refs/heads/ci-cache-linux-x64` からキャッシュを自動取得して `~/.cache/zig` を即座に温めます。

---

## 3. エージェントからの CI 実行・ログ確認コマンド

macOS / Windows 固有コードや GUI E2E テストを変更した際は、現在の作業ブランチへ push して CI 結果を必ず確認すること：

```bash
# 1. 現在のセッションブランチに push して CI をトリガー
git push -u origin "$(git branch --show-current)"

# 2. 実行中のワークフロー Run ID を確認
gh run list --branch "$(git branch --show-current)" --limit 5

# 3. 完了まで待機し、終了コードで成否を判定
gh run watch <run_id> --exit-status

# 4. 失敗ジョブがある場合は失敗ステップのログだけを抽出して原因特定
gh run view <run_id> --log-failed
```
