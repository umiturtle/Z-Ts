# AGENTS.md — Z-Ts（Tauri in Zig）開発ガイドライン（雛形）

> **このドキュメントは、AIエージェントおよび人間の開発者が `Z-Ts`（Tauri の Zig 移植プロジェクト）を開発する際のガイドライン雛形です。**
> **アーキテクチャ詳細・マイルストーンの確定に合わせて、本ドキュメント自体も継続的にアップデートしてください。**

---

## 0. プロジェクト概要と現在地

### 0.1 目的

**`Z-Ts`** は、クロスプラットフォーム WebView デスクトップ/モバイルアプリフレームワーク **[Tauri v2](https://github.com/tauri-apps/tauri)** を **Zig (`0.17.0`)** へ移植・再構築するプロジェクトです。

- **高速なビルドと単一ツールチェーン**: Rust の重量級 proc-macro（`syn` / `quote`）に依存していたコマンド生成・アセット埋め込み・設定検証を、Zig ネイティブの **`comptime` メタプログラミング**と **`build.zig` ビルドグラフ**で置き換える。
- **明示的なメモリ・ライフサイクル管理**: `std.mem.Allocator` と `errdefer` により、IPC メッセージバッファ・ステート・ウィンドウリソースの所有権と解放タイミングを完全に可視化する。
- **上流互換性と段階的検証**: リポジトリ内の `vendor/` に配置した本家 Rust 実装（`tauri` / `wry` / `tao`）を正確な仕様リファレンスとし、テスト駆動・差分テスト（Differential Testing）によって忠実かつ高品質に実装する。

### 0.2 上流リファレンス（`vendor/`）と移植レイヤー対応表

本家ソースコードは Git サブモジュールとして `vendor/` 配下にチェックアウト済みです。**推測で仕様を決めず、必ず対応する上流コードを読んでから設計・実装すること。**

| レイヤー | Z-Ts モジュール案 | 対応する上流リポジトリ / クレート | 主な責務 |
|---|---|---|---|
| **L1: Windowing** | `src/window/` | `vendor/tao` | OS ウィンドウ生成、イベントループ、DPI・モニター情報、メニュー・入力イベント（Linux: GTK3 / macOS: AppKit / Windows: Win32） |
| **L2: WebView** | `src/webview/` | `vendor/wry` | OS ネイティブ WebView 制御、初期化 JS 注入、IPC メッセージハンドラ、カスタムプロトコル処理（Linux: `webkit2gtk-4.1` / macOS: `WKWebView` / Windows: `WebView2`） |
| **L3: Runtime 抽象** | `src/runtime/` | `vendor/tauri/crates/tauri-runtime`<br>`vendor/tauri/crates/tauri-runtime-wry` | バックエンド非依存の `Runtime` インターフェース、ウィンドウ・WebView ハンドル管理、イベントディスパッチ |
| **L4: Config & Security** | `src/utils/`<br>`src/acl/` | `vendor/tauri/crates/tauri-utils` | `tauri.conf.json` パース、ACL（Capabilities / Permissions / Scope グロブ評価）、MIME 判定、アセット管理 |
| **L5: Core & Comptime IPC** | `src/app/`<br>`src/ipc/`<br>`src/plugin/` | `vendor/tauri/crates/tauri`<br>`vendor/tauri/crates/tauri-macros`<br>`vendor/tauri/crates/tauri-codegen`<br>`vendor/tauri/crates/tauri-plugin` | `App` / `Builder`、`State` 管理、`comptime` 型リフレクションによる Command 引数デシリアライズ＆ディスパッチ（`invoke` / `Channel` / `Event`）、`asset://` プロトコル、Plugin 機構 |
| **L6: Build & Tooling** | `build.zig`<br>`src/cli/`<br>`src/bundler/` | `vendor/tauri/crates/tauri-build`<br>`vendor/tauri/crates/tauri-cli`<br>`vendor/tauri/crates/tauri-bundler` | アセット埋め込み（`@embedFile` / codegen）、開発サーバー連携、パッケージング |
| **JS Frontend Bridge** | （互換維持 / 検証対象） | `vendor/tauri/packages/api` | `@tauri-apps/api`（`window.__TAURI_INTERNALS__`）との IPC ワイヤープロトコル互換性 |

### 0.3 設計上の要合意事項（雛形 TODO）

<!-- TODO: ユーザーとの議論により方針が固まり次第、以下のチェックボックスと決定内容を更新すること -->
- [ ] **ターゲット OS の実装順序**: Linux (`GTK3` + `WebKit2GTK 4.1`) 先行 → macOS / Windows 展開か、クロスプラットフォーム抽象を先に固めるか
- [ ] **フロントエンド JS API 互換レベル**: `@tauri-apps/api` v2（`__TAURI_INTERNALS__` プロトコル）との 100% ドロップイン互換を目指すか、Z-Ts 専用の軽量 TS SDK も併設するか
- [ ] **移植アプローチ**: 最初から Pure Zig + C API 直叩きで積み上げるか、過渡期に一部 `tao`/`wry` 等の C-ABI Rust ブリッジを比較・検証用に併用するか
- [ ] **非同期ランタイム設計**: イベントループ（GTK/AppKit/Win32 メインループ）とバックグラウンドワーカー・IPC 非同期コマンドの統合モデル

---

## 1. 実装フロー

### 1.1 実装の進め方

実装を行う際は、必ず以下のフローに従うこと：

```
1. 🧠 memory.md を確認
   └─ 前回までの進捗・設計判断・残課題・次のステップを把握

2. 📋 ROADMAP.md / マイルストーンを確認
   └─ 今回取り組む対象レイヤー・マイルストーンを選択

3. 🔍 上流コード（vendor/tauri, vendor/wry, vendor/tao）を精読
   └─ 対応する Rust 実装のデータ構造・エッジケース・セキュリティ境界を確認
   └─ docs/ARCHITECTURE.md の設計原則と照合

4. 📝 実装計画を立てる
   └─ 小さな検証可能タスクに分解し、完了基準（テスト項目）を明確化

5. 🔧 実装（TDD / 差分テスト駆動 / ベンチマーク駆動）
   └─ テストを先に書き、最小実装 → リファクタリング → 1タスクごとにコミット

6. 📚 ドキュメント & memory.md 更新
   └─ ARCHITECTURE.md / ROADMAP.md / AGENTS.md / memory.md をコードと同期
```

---

## 2. 設計原則と Zig 0.17 実装規約

### 2.1 Rust から Zig への翻訳指針（「直訳」ではなく「Zig ネイティブ設計」）

1. **Proc-macro を `comptime` リフレクションへ昇華させる**
   - Rust の `#[tauri::command]` が構文木変換で行っている「関数引数名・型の抽出 → JSON パース → `State<T>` / `Window` 注入 → 戻り値/エラーの JSON シリアライズ」は、Zig では `@typeInfo(@TypeOf(func)).@"fn"` を用いた `comptime` ハンドラ生成で簡潔・型安全に実装する。
2. **明示的アロケータとリークゼロ保証**
   - 動的確保を行う関数は必ず `allocator: std.mem.Allocator` を引数に受け取る（暗黙のグローバルアロケータ依存を避ける）。
   - 1 回の IPC リクエスト処理のような短命データは `std.heap.ArenaAllocator` を活用し、リクエスト完了時に一括解放する。
   - すべての単体テストで `std.testing.allocator` を使用し、**1 バイトのメモリリークも許さない**。
3. **関数の責務分類を意識する**
   - **PURE / COMPUTE**: I/O やグローバル状態を持たない純粋計算（URL ルーティング、ACL/Scope マッチング、JSON-RPC パース・シリアライズ等）。可能な限りロジックをここへ切り出し、OS GUI なしで高速単体テスト可能にする。
   - **MUTATE**: アプリケーション `State`、ウィンドウレジストリ、イベントリスナー表の状態遷移。スレッド安全性（Mutex / メインスレッド制約）を型レベルで明確にする。
   - **EFFECT**: GTK / WebKit2GTK / OS システムコール呼び出し。薄いプラットフォームバックエンド層に隔離する。

### 2.2 Zig `0.17.0` 必須注意事項（重要）

このプロジェクトは **Zig `0.17.0`** を使用します。古いバージョンの Zig 構文を混入させないこと：

1. **`@cImport` / `@cInclude` は廃止済み（使用不可）**
   - Zig `0.17.0` ではソースコード内の `@cImport` はコンパイルエラーになります。
   - C ヘッダ（GTK3, WebKit2GTK 等）を利用する場合は、必ず **`build.zig` 内で `b.addTranslateC(...)` を定義**し、`mod.addImport("c", tc.createModule())` としてモジュール経由で `@import("c")` するか、厳選した C ABI シンボルを直接 `extern fn ... callconv(.c)` で宣言すること。
2. **`build.zig.zon` 規約**
   - `.name = .z_ts` のように識別子リテラルを使用し、有効な `.fingerprint` と `.minimum_zig_version = "0.17.0"` を維持する。
3. **Rust `staticlib` リンク時の注意**
   - 差分テストや段階的ブリッジで Rust の `staticlib`（`.a`）を Zig バイナリにリンクする場合は、アンワインドシンボル解決のため `mod.linkSystemLibrary("gcc_s", .{})` と `link_libc = true` を指定する。

---

## 3. 開発手法とテスト戦略

### 3.1 開発手法の使い分け

1. **テスト駆動開発（TDD: 🔴 RED → 🟢 GREEN → 🔵 REFACTOR → 📝 COMMIT）**
   - IPC メッセージパーサー、`tauri.conf.json` バリデータ、ACL / Capability 認可エンジン、State 管理、イベントバスなどすべてのコアロジック。
2. **差分テスト（Differential Testing against Upstream Rust）**
   - 移植プロジェクト最大の武器。同じ入力（設定 JSON、IPC ペイロード、パス traversal 攻撃入力、Capability スコープ文字列など）を **Rust リファレンス実装** と **Zig 実装** の双方に与え、出力・エラー挙動が一致することを自動検証する。
3. **ベンチマーク駆動開発（📊 BASELINE → 🎯 TARGET → 🔧 OPTIMIZE → 📊 MEASURE）**
   - バイナリサイズ、起動時間、IPC ラウンドトリップスループット、メモリ使用量において本家 Rust 版を計測比較対象とする。

### 3.2 テストは「これでもか」というほど増やす

- **単体テスト**: 正常系・異常系・境界値・不正 UTF-8・巨大入力・アロケーション失敗（`std.testing.checkAllAllocationFailures`）まで網羅する（**目標：主要な公開関数ごとに最低 5〜10 ケース以上**）。
- **セキュリティ回帰テスト**: Tauri の核であるカスタムプロトコルのパストラバーサル防止、Origin 検証、ACL 権限拒否ケースを重点的にテストする。
- **統合テスト**: 実際の Linux `GTK3` + `WebKit2GTK 4.1` リンクを含めたビルド・ヘッドレス動作確認を行う。

---

## 4. 開発環境とツールチェーン

### 4.1 セットアップ済みツールチェーン（Debian 12 x86_64）

本環境には以下のツールチェーンと Linux GUI/WebView 開発 sysroot が整備されています：

| ツール / ライブラリ | バージョン | パス / 確認コマンド |
|---|---|---|
| **Zig** | `0.17.0` | `zig version` / `python3 -m ziglang version` |
| **Rust (`rustc` / `cargo`)** | `1.99.0` (Edition 2024 対応) | `rustc --version` / `cargo --version` |
| **Rust 補助ツール** | `rustfmt` / `clippy` / `wasm32` std | `rustfmt --version` / `cargo clippy --version` |
| **GTK3 / WebKit2GTK Sysroot** | GTK `3.24.38`, WebKit2GTK `2.50.6` (`4.1`) | `pkg-config --modversion gtk+-3.0 webkit2gtk-4.1` |

### 4.2 環境の自動復旧・検証コマンド

コンテナ再起動やスナップショット復元後にツールチェーンが見当たらない場合は、以下のスクリプト 1 コマンドで全環境（Zig + Rust + Linux GTK3/WebKit2GTK sysroot）をべき等に自動セットアップ＆リンク検証できます：

```bash
# ツールチェーン・sysroot の確認と自動セットアップ（フルリンク検証付き）
bash scripts/setup-toolchains.sh --verify
```

### 4.3 基本ビルド・テストコマンド

```bash
# Zig 単体テスト実行
zig build test

# コードフォーマットチェック
zig fmt --check src/ build.zig build.zig.zon
```

### 4.4 Arena サンドボックスにおけるネットワーク制約メモ

この開発環境から外部通信可能なホストは以下に限定されています：
- `github.com` / `codeload.github.com` / `api.github.com`
- `registry.npmjs.org`
- `pypi.org` / `files.pythonhosted.org`

> **注意**: `static.rust-lang.org`、`ziglang.org`、`deb.debian.org`、`crates.io` への直接通信はブロックされています。
> - Zig 本体: PyPI の `ziglang` ホイール経由で取得（`scripts/setup-toolchains.sh` 内蔵）
> - Rust 本体 & Linux WebKit2GTK sysroot: npm の `@toolchain-bin/*` パッケージ経由で取得（`scripts/setup-toolchains.sh` 内蔵）
> - Rust 外部クレートが必要な場合: `vendor/` 内のローカル path 依存、または `git = "https://github.com/..."` 依存を使用する。

---

## 5. ディレクトリ構成（初期案）

```text
Z-Ts/
├── AGENTS.md                 # AIエージェント・開発者向けガイドライン（本書）
├── memory.md                 # セッション間の進捗・設計意図・引き継ぎ記録
├── README.md                 # プロジェクト概要
├── ROADMAP.md                # マイルストーン・移植ロードマップ（今後策定）
├── build.zig                 # Zig 0.17 ビルド定義
├── build.zig.zon             # Zig パッケージマニフェスト
├── scripts/
│   └── setup-toolchains.sh   # Zig / Rust / GTK3 & WebKit2GTK sysroot セットアップスクリプト
├── docs/                     # アーキテクチャ設計・仕様対照ドキュメント（今後整備）
├── src/                      # Z-Ts 本体ソースコード（Zig）
│   └── root.zig              # ライブラリルート
└── vendor/                   # 上流リファレンス実装（Git Submodules）
    ├── tauri/                # tauri-apps/tauri (v2)
    ├── wry/                  # tauri-apps/wry (WebView 抽象)
    └── tao/                  # tauri-apps/tao (Window / EventLoop 抽象)
```

---

## 6. ドキュメント管理と引き継ぎ（`memory.md`）

### 6.1 ドキュメント同時更新の原則

コードや設計を変更したら、必ず関連ドキュメントも同一作業内で更新すること：
- `AGENTS.md` — 開発ルール・モジュール構成・ビルド手順の変更時
- `docs/ARCHITECTURE.md` — レイヤー設計・データフロー・API 変更時
- `ROADMAP.md` — マイルストーン進捗更新時
- `memory.md` — **毎回の区切り・コミットごとに必ず更新**

### 6.2 `memory.md` の運用

作業を開始する前に必ず `memory.md` を読み、作業完了時には以下を記録すること：
1. 今回完了したこと
2. 設計上の判断理由・発見した技術的知見・ハマりどころと解決策
3. 未解決の課題・次に着手すべき具体的ステップ

---

## 7. 品質姿勢とコミット規約

### 7.1 「言わなきゃいけないことを言う」

- 上流 Tauri の仕様上の複雑さやセキュリティ上の落とし穴を見つけたら曖昧にせず報告する。
- 設計原則に矛盾する方針や、Zig への無理な直訳になりそうな箇所があれば代替案とともに指摘する。
- テストが不十分なまま先に進まない。

### 7.2 コミット粒度とメッセージ規約

**1 コミット = 1 つの明確でテスト通過済みの変更** とし、Conventional Commits 形式を用いる：

```text
<type>(<scope>): <subject>

- 変更内容・設計意図の要約
- 検証したテスト項目
```

- **Type**: `feat`, `fix`, `docs`, `test`, `perf`, `refactor`, `chore`, `build`
