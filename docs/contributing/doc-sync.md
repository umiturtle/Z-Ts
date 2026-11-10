# ドキュメント同期台帳

> **対象読者**: ドキュメントを書き換える人・レビューする人。
> **このファイルは自動生成です。** 編集せず、`python3 scripts/check-docs.py --sync` を実行してください。

「いつ最後に書き換えたか」と「どのバージョンまで実装と無矛盾を確認したか」を、
**日英 1 組 = 1 行**で記録します。正本は [`scripts/doc-sync.json`](../../scripts/doc-sync.json) で、
`check-docs.py` の規約 13 が次を検査します。

1. すべての読者向けページに英語版があること（英語の H1 が日本語ではないこと、日本語版のコピーでないことも含む）
2. 日英それぞれの本文 sha256 が台帳と一致すること（**書き換えたのに日付を更新していない**ことを検出）
3. 実装ファイル群の sha256 が一致すること（**実装が変わったのに再確認していない**ことを検出）
4. `zts_version` / `zig_version` が `build.zig.zon` と一致すること
5. `last_rewritten` が確認日以前の ISO 日付であること

## 確認したバージョン

- **確認バージョン**: `ziggurats 0.1.0` / Zig `0.17.0`
- **確認日**: `2026-10-21`
- **基準コミット**: `c846f01`（確認開始時点の HEAD。実装の同一性は下のハッシュで判定）
- **確認コマンド**: `python3 scripts/check-docs.py` · `python3 scripts/gen-framework-tutorials.py --check` · `./zigw docs-check` · `./zigw quick-test` · `./zigw test -Mroot=src/cli/mod.zig` · `./zigw fmt --check src/ build.zig build.zig.zon`
- **実装ハッシュ**: `65108999801026540d9e18826b20d341fe0fc6b7290facfd77f9d1f91ed3e5f2`

実装として突き合わせたファイル: `build.zig`, `build.zig.zon`, `src/cli/args.zig`, `src/cli/main.zig`, `src/cli/template.zig`, `src/docsite/main.zig`, `src/docsite/learn_path.zig`, `src/docsite/i18n.zig`, `src/docsite/site.zig`, `src/docsite/frameworks.zig`, `src/docsite/frameworks.json`, `src/docsite/assets/site.js`, `src/docsite/assets/site.css`, `scripts/check-docs.py`, `scripts/gen-framework-tutorials.py`

## ページごとの記録

| 日本語 | English | 最終書き換え | 確認バージョン |
|---|---|---|---|
| `README.md` | `README.en.md` | 2026-10-21 | 0.1.0 |
| `docs/INDEX.md` | `docs/INDEX.en.md` | 2026-10-21 | 0.1.0 |
| `docs/contributing/README.md` | `docs/contributing/README.en.md` | 2026-10-21 | 0.1.0 |
| `docs/contributing/doc-sync.md` | `docs/contributing/doc-sync.en.md` | 2026-10-21 | 0.1.0 |
| `docs/contributing/repository-map.md` | `docs/contributing/repository-map.en.md` | 2026-10-21 | 0.1.0 |
| `docs/contributing/troubleshooting.md` | `docs/contributing/troubleshooting.en.md` | 2026-10-21 | 0.1.0 |
| `docs/contributing/writing-docs.md` | `docs/contributing/writing-docs.en.md` | 2026-10-21 | 0.1.0 |
| `docs/glossary.md` | `docs/glossary.en.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/concepts/architecture.md` | `docs/learn/en/concepts/architecture.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/concepts/commands.md` | `docs/learn/en/concepts/commands.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/concepts/index.md` | `docs/learn/en/concepts/index.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/concepts/plugins.md` | `docs/learn/en/concepts/plugins.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/concepts/security.md` | `docs/learn/en/concepts/security.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/index.md` | `docs/learn/en/guides/index.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/install.md` | `docs/learn/en/guides/install.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/migrate-from-tauri.md` | `docs/learn/en/guides/migrate-from-tauri.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/package.md` | `docs/learn/en/guides/package.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/plugins.md` | `docs/learn/en/guides/plugins.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/rpc.md` | `docs/learn/en/guides/rpc.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/static-site.md` | `docs/learn/en/guides/static-site.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/guides/troubleshooting.md` | `docs/learn/en/guides/troubleshooting.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/index.md` | `docs/learn/en/index.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/patterns/boundaries.md` | `docs/learn/en/patterns/boundaries.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/patterns/commands.md` | `docs/learn/en/patterns/commands.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/patterns/errors.md` | `docs/learn/en/patterns/errors.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/patterns/index.md` | `docs/learn/en/patterns/index.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/patterns/state.md` | `docs/learn/en/patterns/state.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/start.md` | `docs/learn/en/start.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/counter-angular.md` | `docs/learn/en/tutorials/counter-angular.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/counter-astro.md` | `docs/learn/en/tutorials/counter-astro.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/counter-next.md` | `docs/learn/en/tutorials/counter-next.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/counter-nuxt.md` | `docs/learn/en/tutorials/counter-nuxt.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/counter-react.md` | `docs/learn/en/tutorials/counter-react.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/counter-solid.md` | `docs/learn/en/tutorials/counter-solid.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/counter-solidstart.md` | `docs/learn/en/tutorials/counter-solidstart.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/counter-svelte.md` | `docs/learn/en/tutorials/counter-svelte.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/counter-sveltekit.md` | `docs/learn/en/tutorials/counter-sveltekit.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/counter.md` | `docs/learn/en/tutorials/counter.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/frameworks.md` | `docs/learn/en/tutorials/frameworks.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/index.md` | `docs/learn/en/tutorials/index.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/todo.md` | `docs/learn/en/tutorials/todo.md` | 2026-10-21 | 0.1.0 |
| `docs/learn/ja/tutorials/ui.md` | `docs/learn/en/tutorials/ui.md` | 2026-10-21 | 0.1.0 |
| `docs/reference/cli.md` | `docs/reference/cli.en.md` | 2026-10-21 | 0.1.0 |
| `docs/reference/tauri-internals.md` | `docs/reference/tauri-internals.en.md` | 2026-10-21 | 0.1.0 |
| `docs/reference/tauri-usage.md` | `docs/reference/tauri-usage.en.md` | 2026-10-21 | 0.1.0 |
| `examples/c_embed/README.md` | `examples/c_embed/README.en.md` | 2026-10-21 | 0.1.0 |
| `examples/counter/README.md` | `examples/counter/README.en.md` | 2026-10-21 | 0.1.0 |
| `examples/frameworks/README.md` | `examples/frameworks/README.en.md` | 2026-10-21 | 0.1.0 |
| `examples/gallery/README.md` | `examples/gallery/README.en.md` | 2026-10-21 | 0.1.0 |

## 更新のしかた

```bash
# 実装か Doc を変えたあと、再確認して台帳を更新する（日付は既定で当日）
python3 scripts/check-docs.py --sync
python3 scripts/check-docs.py --sync --date 2026-10-21   # 日付を明示するとき
python3 scripts/check-docs.py                             # 検査のみ（CI はこれ）
```

`--sync` は本文が変わったページの `last_rewritten` だけを更新し、変わっていないページの
日付は保持します。内部資料（ADR・設計メモ・タスク票）は日本語専用なので台帳の対象外です。

## 関連

- [ドキュメントの書き方](writing-docs.md) — 規約 13 と 2 言語の規約
- [リポジトリの地図](repository-map.md) — ファイル配置
- [ドキュメント索引](../INDEX.md) — サイトの並び
