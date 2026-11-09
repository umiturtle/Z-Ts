# パッケージ構成 — 6 つの層と 3 つの成果物

> **対象読者**: ziggurats のどこに何を書くのか、なぜその分け方なのかを知りたい人。
> **所要時間**: 5 分。

[前のページ](index.md)で見た 3 つの登場人物（ページ / ブリッジ / コマンド）は、実際には
**6 つのパッケージ**に分かれています。このページはその地図です。分け方の理由は 1 つだけで、
**「3 つの成果物を同じコードから出す」**ためです。

## 1 枚で分かる依存関係

依存は **必ず上から下への 1 方向**です。逆流はありません。

```text
  ┌──────────────────────────────────────────────┐
  │ あなたのアプリ（src/main.zig + web/）        │
  └──────────────────────────────────────────────┘
        │                  │                  │
        ▼                  ▼                  ▼
  zts_webview         zts_bridge          zts_wasm
  （OS の WebView）    （HTTP + SSE）      （WebAssembly）
        │                  │                  │
        └──────────┬───────┴──────────────────┘
                   ▼
              zts_tauri        … Tauri v2 のプロトコルと 7 プラグイン
                   │
        ┌──────────┼──────────┐
        ▼          ▼          ▼
   zts_core     zts_rpc    zts_ssg     … 純 Zig。OS に触らない
        │          │
        ▼          ▼
     zts_web   zts_foundation             … 最小の土台
```

| パッケージ | 役割 | 依存先 | libc |
|---|---|---|---|
| `zts_foundation` | 時刻・ID・ログ・バイト列などの最小部品 | なし | 不要 |
| `zts_web` | HTML/CSS/JS をメモリ上で扱う（`Assets`、MIME、CSP ハッシュ） | foundation | 不要 |
| `zts_core` | `Host` 抽象（ウィンドウ・イベント・IPC の窓口） | foundation, web | 不要 |
| `zts_rpc` | コマンド定義・型検査・JSON・TypeScript 生成 | foundation | 不要 |
| `zts_bridge` | ブラウザと Zig をつなぐ HTTP/1.1 + SSE サーバ | foundation, web, core, rpc | 不要 |
| `zts_tauri` | Tauri v2 の IPC プロトコルと標準プラグイン | foundation, web, core, rpc | 不要 |
| `zts_webview` | GTK3 / WKWebView / WebView2 の実装 | foundation, core | **必要**（この層だけ） |
| `zts_wasm` | `wasm32-freestanding` 向けの C ABI と WASM ホスト | foundation, web, core, rpc, tauri | 不要 |
| `zts_ssg` | 静的サイト書き出し、プリレンダ、`_headers` | foundation, web, tauri, wasm | 不要 |

**libc を要求するのは `zts_webview` だけ**です。だから同じアプリコードが、OS のない
WebAssembly でも、サーバのない静的サイトでも動きます。

## なぜ 6 つに割るのか

3 つの理由があります。どれも「分けた結果」ではなく「分けないと成立しない」理由です。

1. **成果物ごとに OS への触り方が違う。** デスクトップは GTK/Win32/Cocoa、ブラウザは
   HTTP、WASM は線形メモリ。この 3 つを `Host` という 2 ワードの関数ポインタ対に押し込めば、
   アプリ側に `if (target)` が 1 行も要りません。
2. **テストを速く保つ。** `zts_rpc` と `zts_tauri` は OS を呼ばないので、CI の高速ループで
   全テストが 1 秒未満で回ります。ネイティブ WebView のテストだけが Xvfb を必要とします。
3. **使うものだけリンクできる。** コマンドが不要なら `zts_rpc` を入れません。静的サイトが
   不要なら `zts_ssg` を入れません。

## 3 つの成果物はどこで分かれるか

アプリのロジックは 1 ファイル（例: `src/app.zig`）に置き、**エントリポイントだけ**を
3 つ用意します。

| 成果物 | エントリポイント | `Host` の実装 | 状態の置き場所 |
|---|---|---|---|
| デスクトップ | `src/desktop.zig` | `WebviewHost` | プロセス内 |
| Live Preview | `src/live.zig` | `BridgeHost` | プロセス内 |
| 静的サイト | `src/wasm_app.zig` | `WasmHost` | ブラウザ内（WASM） |

```text
src/
├── app.zig        ← ロジック（コマンド・状態）。3 成果物で共有
├── desktop.zig    ← main() と WebviewHost
├── live.zig       ← HTTP サーバと BridgeHost
└── wasm_app.zig   ← C ABI の export と WasmHost
```

「デスクトップのときだけ別のコード」を書きたくなったら、それはたいてい
**`Host` の機能が足りていない**合図です。まず `zts_core` の `Host` を見てください。

## よくある誤解

| 誤解 | 実際 |
|---|---|
| 「Zig で全部書かないといけない」 | フロントエンドは TypeScript のまま。Zig が担当するのはバックエンドとビルド |
| 「Tauri のプラグインは使えない」 | 標準 7 プラグインは互換実装があります（[プラグイン](plugins.md)） |
| 「WASM 版は別のアプリを書く」 | 同じ `app.zig`。`Host` を差し替えるだけ |
| 「`zts_tauri` を入れれば OS ウィンドウが開く」 | ウィンドウを開くのは `zts_webview`。`zts_tauri` はプロトコルだけ |

## 次に読むもの

- [コマンドが届くまで](commands.md) — この構成の上で実際にコードを書く話
- [API: zts_core](../../../api/zts_core/index.html) — `Host` の全体
- [パッケージを自分で組む](../guides/static-site.md) — 実際の `build.zig`
