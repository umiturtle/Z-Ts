# Z-Ts アーキテクチャ全体概要（雛形）

> **本書は Tauri v2 を Zig (`0.17.0`) へ移植する `Z-Ts` の全体レイヤー構造とモジュール境界契約の雛形です。**
> **各モジュールの詳細設計は、並列開発時のコンフリクトを防ぐため `docs/architecture/<module>.md` に個別ファイルとして作成してください。**

---

## 1. レイヤー構造と上流リファレンス（`vendor/`）対応

依存方向は常に **上位レイヤー → 下位レイヤー（単方向）** とし、下位レイヤーが上位レイヤーを `@import` することを禁止します。

```text
┌──────────────────────────────────────────────────────────────────────┐
│ L6: CLI / Bundler / Build Step  (src/cli/, src/bundler/, build.zig)  │
├──────────────────────────────────────────────────────────────────────┤
│ L5: Core App / State / Comptime IPC / Plugin (src/app/, src/ipc/)    │
├──────────────────────────────────────────────────────────────────────┤
│ L4: Config / ACL / Capabilities / Assets / MIME (src/config/, acl/)  │  <-- Pure Zig (link_libc = false)
├──────────────────────────────────────────────────────────────────────┤
│ L3: Runtime Trait / Handle Abstraction  (src/runtime/)               │  <-- Mock Backend で GUI なしテスト可能
├──────────────────────────────────────────────────────────────────────┤
│ L2: Native WebView Backends (src/webview/{linux,macos,windows}/)     │  <-- OS C/ObjC/COM ABI 隔離層
├──────────────────────────────────────────────────────────────────────┤
│ L1: Native Window & EventLoop (src/window/{linux,macos,windows}/)    │  <-- OS C/ObjC/Win32 ABI 隔離層
└──────────────────────────────────────────────────────────────────────┘
```

| レイヤー | Z-Ts パス（予定） | 上流リファレンス（必読） | Pure Zig 単体テスト可否 |
|---|---|---|---|
| **L1: Windowing** | `src/window/` | `vendor/tao/src/` | OS 固有部は CI (`xvfb` / macOS / Windows) |
| **L2: WebView** | `src/webview/` | `vendor/wry/src/` | OS 固有部は CI (`xvfb` / macOS / Windows) |
| **L3: Runtime** | `src/runtime/` | `vendor/tauri/crates/tauri-runtime/`<br>`vendor/tauri/crates/tauri-runtime-wry/` | ◎ `HeadlessMockRuntime` 実装により 100% Pure Zig テスト可能 |
| **L4: Utils & ACL** | `src/config/`, `src/acl/`, `src/assets/` | `vendor/tauri/crates/tauri-utils/src/` | ◎ 100% Pure Zig (`link_libc = false`) |
| **L5: Core & IPC** | `src/ipc/`, `src/state/`, `src/event/`, `src/app/` | `vendor/tauri/crates/tauri/src/`<br>`vendor/tauri/crates/tauri-macros/` | ◎ `MockRuntime` 上で双方向 IPC ラウンドトリップまで Pure Zig テスト可能 |
| **L6: Build / Bundler** | `src/bundler/`, `src/cli/`, `build.zig` | `vendor/tauri/crates/tauri-build/`<br>`vendor/tauri/crates/tauri-bundler/` | ◎ アーカイブ・マニフェスト生成は Pure Zig テスト可能 |

---

## 2. 並列マルチエージェント開発を可能にする境界設計原則

複数のエージェントが同時に別モジュールを実装しても衝突せず結合できるよう、以下の 3 原則を守ります：

1. **L3 `Runtime` 境界によるフロント/バック完全分離**:
   - **OS バックエンド担当エージェント**は L1 (`window`) / L2 (`webview`) の実装に集中できる。
   - **コア機能担当エージェント**は `MockRuntime` を使って、実 GUI ウィンドウなしでも L4 (`config`, `acl`, `assets`) や L5 (`ipc`, `state`, `event`, `plugin`) を **0.1 秒の Pure Zig 単体テスト** で並列に作り込める。
2. **Rust proc-macro を Zig `comptime` 型リフレクションへ置き換える**:
   - `#[tauri::command]` 相当の仕組みは外部コード生成器ではなく、任意の Zig 関数 `fn myCmd(ctx: Context, name: []const u8) !Greeting` を `@typeInfo` で解析し、JSON 引数デシリアライズ → 実行 → JSON レスポンス/エラー変換を行う `comptime` ラッパー関数として実装する。
3. **1 モジュール = `src/<module>/mod.zig` 自己完結原則**:
   - モジュール間の接続は公開型とスライス/インターフェースのみで行い、内部実装詳細を漏らさない。

---

## 3. 未確定・今後合意すべき設計論点（Open Decisions）

- [ ] **JS ワイヤープロトコル互換性**: `@tauri-apps/api` v2（`window.__TAURI_INTERNALS__.invoke` / `transformCallback` / カスタムプロトコル `ipc://localhost` or `http://ipc.localhost`）との完全互換を第 1 目標とするか、Z-Ts 軽量 JS ブリッジを先行させるか
- [ ] **非同期コマンド実行モデル**: イベントループスレッドへのディスパッチキュー（`g_idle_add` / `dispatch_async_f` / `PostMessageW`）とスレッドプールの標準構成
- [ ] **モバイル対応スコープ**: デスクトップ 3 OS（Linux / macOS / Windows）完成後に iOS / Android を視野に入れるか
