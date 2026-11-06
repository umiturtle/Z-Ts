# セキュリティ — 既定は拒否

> **対象読者**: アプリを配布する前に、何が守られて何が守られないかを知りたい人。
> **所要時間**: 5 分。

Tauri のセキュリティモデルの核は **capability（許可証）** です。Z-Ts はこれをそのまま
実装しています。**capability に書かれていないコマンドは、フロントエンドから呼べません。**

## 1. 3 つの層

```text
  ① WebView のサンドボックス
     OS が提供する境界。Z-Ts はここに手を出さない（素の WebView と同じ）

  ② capability（ACL）      ← Z-Ts が実装
     「ウィンドウ main は plugin:fs|read_text_file を呼んでよい」
     権限名 + scope（どのパスか）で決まる。既定は拒否

  ③ CSP / ヘッダ          ← zts_web が生成
     script-src のハッシュ、X-Frame-Options、COOP/COEP など
```

## 2. capability を書く

Tauri と同じ JSON です。既存プロジェクトからは**そのまま**読めます。

```json
{
  "identifier": "main-capability",
  "windows": ["main"],
  "permissions": [
    "core:default",
    "fs:allow-read-text-file",
    {
      "identifier": "fs:scope",
      "allow": [{ "path": "$APPDATA/**" }]
    }
  ]
}
```

Zig 側では、読み込んで判定するだけです。

```zig
const imported = try tauri.config_import.load(allocator, io, "src-tauri");
defer imported.deinit();

var policy = try tauri.acl.Policy.init(allocator, .{
    .files = imported.capabilities,
    .platform = .linux,
});
defer policy.deinit();

if (!policy.allows("main", "plugin:fs|read_text_file")) return error.Forbidden;
```

> [!WARNING]
> **scope を空にすると `fs` は常に失敗します。** 「動かない」のではなく「拒否されている」ので、
> エラーは `forbidden path` になります。`$APPDATA/**` のような glob を必ず書いてください。

## 3. 何を守り、何を守らないか

| 守る | 守らない |
|---|---|
| capability に無いコマンドの実行 | フロントエンドの JavaScript 自体（XSS は WebView の領分） |
| scope の外のパスへの読み書き | ネットワーク越しの攻撃（CSP とサーバ設定の責任） |
| 未知のパーミッション名の警告 | 依存ライブラリの脆弱性 |
| 型違いのパーミッション（エラー） | OS の権限（ファイルシステムの ACL など） |

「守らない」を明記するのは Tauri 本家と同じ流儀です。**過信させないこと**が安全に効きます。

## 4. CSP とヘッダ

`zts_web` は埋め込んだアセットから CSP を組み立てます。インラインスクリプトには
**ハッシュ**が付き、`unsafe-inline` は使いません。

| ヘッダ | 既定 | 意味 |
|---|---|---|
| `Content-Security-Policy` | 生成 | `script-src` にハッシュ、`default-src 'self'` |
| `X-Frame-Options` | `DENY` | iframe に埋め込ませない |
| `Cross-Origin-Opener-Policy` | 任意 | `cross_origin_isolated = true` で有効 |
| `Content-Type: application/wasm` | 静的サイト | `_headers` に出力（Cloudflare / Netlify） |

デスクトップでは効かないヘッダもあります（WebView が HTTP を通らないため）。**配布形態ごとに
効く範囲が違う**ことを意識してください。

## 5. チェックリスト

配布前に、次の 5 つを確認します。

1. capability は**必要な権限だけ**か（`core:default` を漫然と入れていないか）
2. `fs` の scope は `$APPDATA/**` などに絞られているか
3. CSP の `unsafe-inline` / `unsafe-eval` が無いか（生成物を確認）
4. `zts doctor` が通るか
5. 未知のパーミッション警告を CI で見ているか

```bash
zts build && grep -r "unsafe-inline" zig-out/ || echo "no inline"
```

## 次に読むもの

- [プラグイン](plugins.md) — どのコマンドがどんな権限名か
- [ガイド: 移行](../guides/migrate-from-tauri.md) — 既存の `capabilities/` をそのまま使う
- API → [`acl`](../../../api/zts_tauri/acl.html) / [`config_import`](../../../api/zts_tauri/config_import.html)
