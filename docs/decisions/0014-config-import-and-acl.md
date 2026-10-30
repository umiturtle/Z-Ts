# ADR-0014: Tauri 資産の移行は「読むだけの互換レイヤ + opt-in な ACL」で行う

- **Status**: Accepted（`M4-04`・バンドラ / スコープ解釈は段階実装）
- **Date**: 2026-10-29
- **関連**: [`../tasks/M4-04-config-import-acl.md`](../tasks/M4-04-config-import-acl.md)、
  [`../architecture/tauri-config-import-acl.md`](../architecture/tauri-config-import-acl.md)、
  [`0011-scoped-fs-plugin.md`](0011-scoped-fs-plugin.md)

---

## 1. 背景

Z-Ts の価値は「Tauri v2 のフロントエンド資産をそのまま動かせる」ことにある。だが実際の
プロジェクトは `src-tauri/tauri.conf.json` と `capabilities/*.json` に設定と権限を持っており、
移行時にこれらを書き直させると「数行の変更」では済まなくなる。

## 2. 決定事項

### 2.1 設定は「未知は警告、型違いはエラー」

Tauri はマイナーごとにキーを増やす。**未知キーで失敗する移行レイヤは使えない**ので、
未知・未対応キーは `Diagnostics` の警告に落とし、既知キーの型違いだけをエラーにする
（`app.windows[0].width` のようなパス付き）。移行 CLI は警告を一覧表示すればよい。

### 2.2 ACL は opt-in、渡した瞬間から fail-closed

既存アプリ（と本リポジトリの 200+ テスト）は ACL を設定していない。`Policy` を
`withAuthCtx` に渡したときだけ判定が有効になり、**渡した後は「許可が見つからない = 拒否」**。
これにより「移行はできるが、権限を書いた瞬間から本家と同じ厳しさ」という段階移行ができる。

### 2.3 権限識別子は実コマンド表から comptime 生成する

`fs:allow-read-text-file` のような識別子を手書きの表で持つと、コマンドを 1 つ足すたびに
表が腐り、**「allow したはずの無いコマンドが動く」**という最悪のバグになる。
`permissionIdFor(wire_command)` が `plugin:<name>|<snake_case>` から機械的に導出し、
テストが `CorePluginsSchema` の全コマンドについて**一意性**を検証する。

### 2.4 `rpc` に `withAuthCtx` を追加する

既存の `AuthorizeFn` は `fn(*const Ctx, []const u8) bool` で状態を持てない。ACL はアプリごとの
ポリシーを参照する必要があるため、`Router.withAuthCtx(userdata, fn)` を**追加**した
（`withAuth` はそのまま、後方互換）。

## 3. 検討した代替案

| 案 | 却下理由 |
|---|---|
| グローバル変数に `Policy` を置く | テストが並列実行されると干渉する。マルチアプリ構成も不可 |
| `AuthorizeFn` の型を userdata 付きに変更 | 既存の利用側（テスト・サンプル・ブリッジ）を壊す |
| 権限表を手書きで維持 | コマンド追加のたびに腐る（上記 2.3） |
| ACL を常時有効にする | 既存アプリが全コマンド拒否になり、移行の入口で詰む |
| `tauri.conf.json` を Zig の構造体に `std.json.parseFromSlice` で直接マップ | 未知フィールドで失敗する（Tauri の `serde` は `deny_unknown_fields` ではない） |

## 4. 結果

- `src-tauri/` をそのまま指すだけで、ウィンドウ定義・アプリ情報・CSP・ACL が Z-Ts に載る。
- ACL の判定は 1 関数（`Policy.allows`）に集約され、deny > allow・プラットフォーム・
  ローカル/リモート・glob を 1 か所で検証できる（3 OS の CI で同一結果）。
- トレードオフ: 権限の `allow` / `deny` スコープ（`{ "path": "$HOME/**" }`）は現状 JSON として
  保持するだけで、`plugin:fs` のスコープへはまだ流し込んでいない。
