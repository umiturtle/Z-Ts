# `tauri.conf.json` インポート & ACL（`plugin:menu` の隣の移行レイヤ）

`src/tauri/config_import.zig` と `src/tauri/acl.zig` は、**既存の Tauri v2 プロジェクトを
書き換えずに Z-Ts へ移行する**ための互換レイヤ（`M4-04`）。設計判断は
[ADR-0014](../decisions/0014-config-import-and-acl.md)。

```text
src-tauri/
├── tauri.conf.json          ── config_import.parse / load ──►  Config
│                                  ├─ app.windows[]  ──► core.WindowSpec
│                                  ├─ app.security.{csp,assetProtocol,…}
│                                  └─ identifier / productName / build / bundle
└── capabilities/*.json      ── acl.Policy.init ───────────►  Policy
                                        └─ allows(command, window, origin)
                                             ▲
                     rpc.Router.withAuthCtx(policy.context(), Policy.authorizeCtx)
```

## 1. 原則: 「未知は警告、型違いはエラー」

Tauri はマイナーごとに設定キーを増やす。移行レイヤが未知キーで落ちると使い物にならないので:

| 入力 | 挙動 |
|---|---|
| 未知のトップレベルキー / 未対応キー（`windowEffects` 等） | `Diagnostics` に**警告**を積み、続行 |
| 既知キーの型違い（`"width": "800"`） | `error.InvalidConfig` + `app.windows[0].width` という**パス付き**警告 |
| 壊れた JSON | `error.InvalidJson` |
| `capabilities/*.json` の壊れた JSON | そのファイルだけ警告して続行（他は移行できる） |

## 2. `Config` ⇄ Z-Ts ランタイム

| `tauri.conf.json` | Z-Ts |
|---|---|
| `identifier` / `productName` / `version` | `tauri.app.AppConfig`（`plugin:app|getIdentifier` 等の応答） |
| `app.windows[]` | `core.WindowSpec`（`windowSpecs()`、`create: false` は除外） |
| `app.security.assetProtocol.scope` | `fs.Scope` の root へ渡す生パターン |
| `app.security.capabilities` | `acl.Policy`（識別子参照 or インライン） |
| `app.trayIcon` | `tray.TrayIconOptions` 相当（`M4-03`） |
| `build.{devUrl,frontendDist,…}` | ビルド時のヒント（`beforeDevCommand` などは CLI が実行） |
| `plugins` / `security.csp` | 生 JSON として保持（Z-Ts のプラグイン設定はコードで書く） |

`url` は上流の 3 形態（`"index.html"` / `{"url": …}` / `{"app": …}`）を受け、
絶対 URL はそのまま `WindowSpec.initial_url` へ入る。

## 3. ACL は opt-in

既存アプリも本リポジトリのテストも ACL を設定していないため、`Policy` を**渡したときだけ**
`AuthorizeFn` が有効になる。渡さない場合の挙動は従来どおり（全許可）で、
これは「コード書き換え最小」という `M4-04` の目的に沿う。

```zig
var imported = try tauri.config_import.load(gpa, io, "src-tauri");
defer imported.deinit();

var policy = try tauri.acl.Policy.fromImported(gpa, &imported);
defer policy.deinit();

var router = FullSchema
    .bind(.{ … })
    .withAuthCtx(policy.context(), tauri.acl.Policy.authorizeCtx);
```

## 4. 権限識別子は「実コマンド表」から機械生成

手書きの対応表はコマンド追加で必ず腐る。Z-Ts は wire コマンド名から上流の識別子を機械的に作る:

| wire コマンド | 権限識別子 |
|---|---|
| `plugin:fs\|read_text_file` | `fs:allow-read-text-file` |
| `plugin:window\|set_title` | `core:window:allow-set-title` |
| `plugin:menu\|set_as_app_menu` | `core:menu:allow-set-as-app-menu` |
| `plugin:dialog\|open`（deny） | `dialog:deny-open` |

`core:` が付くのは `withCorePlugins` が束ねる 7 名前空間（`window` / `event` / `path` /
`app` / `resources` / `menu` / `tray`）。集合体も解決する: `<plugin>:default`、
`core:<plugin>:default`、`core:default`。アプリ独自コマンドは権限名 = コマンド名。

**テストで保証していること**: `CorePluginsSchema` の全コマンドが一意な識別子に写像される
（2 つのコマンドが同じ識別子を共有すると、片方の allow がもう片方まで許可してしまう）。

## 5. 判定規則（fail-closed）

```text
allows(command, window, origin) =
  ∃ capability: matchesPlatform ∧ matchesWindow ∧ matchesOrigin ∧ allows(command)
  ∧ ¬∃ capability: matchesPlatform ∧ matchesWindow ∧ matchesOrigin ∧ denies(command)
```

- **deny が allow に勝つ**（上流 `Authority` と同じ）。1 つでも deny があれば拒否。
- `windows` / `webviews` は `*` / `?` の glob。両方空の capability は全ウィンドウに適用。
- `platforms` 未指定は全プラットフォーム一致（`Policy.withPlatform` でテスト時に切替可能）。
- `local` は `tauri://`・`http://tauri.localhost`・`asset://`・`file://`・`about:`・オリジン無しを
  ローカル扱い。`remote.urls` は `https://*.example.com` 形式のパターン。
- コマンド未知名・権限未知名・どの capability にも一致しない → **拒否**。

## 6. 現状のスコープ

| 項目 | 状態 |
|---|---|
| `tauri.conf.json`（v2）の読み込み | ✅ `productName` / `version` / `identifier` / `app` / `build` / `bundle` / `plugins` |
| `app.windows[]` → `WindowSpec` | ✅ 20+ フィールド（サイズ・位置・装飾・テーマ・URL） |
| `capabilities/*.json`（3 形態） | ✅ 単体 / 配列 / `{capabilities:[…]}` |
| 権限識別子の生成・判定 | ✅ allow / deny / default 集合 / core 接頭辞 |
| `rpc` への接続 | ✅ `withAuthCtx` + `Policy.authorizeCtx` |
| `tauri.conf.json` の `bundle.*`（署名・アイコン・WiX 等） | ⏳ 読み取るだけ（バンドラは未実装） |
| `security.pattern` / `dangerousDisableAssetCspModification` | ⏳ 警告のみ |
| 権限の `allow` / `deny` スコープ（`{path: …}`） | ⏳ JSON として保持（`plugin:fs` 側で解釈予定） |
