# Task M5-11: `zts dev` のインクリメンタル更新（CSS ホットスワップ + web のみ変更でビルドしない）

- **Status**: `done`
- **Branch**: `arena/7ef6be00-z-ts`
- **Scope**: `src/cli/devserver.zig`, `src/cli/main.zig`, `src/cli/project.zig`, `docs/reference/cli.md`, `docs/learn/{ja,en}/{start,tutorials/counter,guides/troubleshooting}.md`
- **Upstream Reference**: Vite の HMR（CSS は `<link>` 差し替え、HTML はフルリロード）／Angular CLI の `ng serve`
- **Next Step**: なし（完了）。新しい変更種別を足すときは `devserver.Change` の enum と `classify` のテストから。

---

## 1. 目的と完了条件（Definition of Done）

- [x] 変更を**ファイル単位**で検出する（`Snapshot` が path → mtime^size を持つ）
- [x] `web/**/*.css` だけの変更では **`zig build` をしない**
- [x] そのときブラウザは**リロードせず** `<link>` を差し替える（スクロール位置・入力・コンソールが残る）
- [x] その他の `web/` 変更はビルドせずリロード（配信元はディスクなので再ビルドは無意味）
- [x] `src/` の変更だけ `zig build` して型を検査し、成功でリロード
- [x] 失敗時は `v` を進めない（壊れた画面を出さない）
- [x] `/__zts_dev__/state` が `{"v":N,"ok":bool,"hot":"css"|"full"}` を返す
- [x] 単体テスト（diff・分類・state JSON・CSS 差し替えスクリプトの生成）
- [x] ドキュメント（CLI リファレンス・学習ページ・トラブルシューティング）を実装に合わせる

## 2. 実測（Arena サンドボックス、ウォームキャッシュ）

| 編集 | 反映まで | 以前 |
|---|---|---|
| `web/style.css` | **0.38 s**（リロードなし） | 約 1.2 s + フルリロード |
| `web/index.html` | **0.37 s**（リロード） | 約 1.2 s + フルリロード |
| `src/main.zig`（コメント追加） | 1.2 s（ビルド + リロード） | 1.2 s |

走査は 250 ms 間隔、変更検知後に 120 ms 待って再走査（保存中の連続書き込みを畳む）。

## 3. 設計判断

- **ポーリングのまま**。inotify / FSEvents / ReadDirectoryChangesW は 3 OS で挙動が違い、
  「同じ入力なら同じ結果」を CI で確かめにくい。250 ms は体感で十分速い。
- **状態はコードで運ぶ**。`hot: "css"` は「リロードせず差し替えてよい」の合図で、
  拡張子の判断はサーバ側に 1 か所だけ置く（クライアントは判断しない）。
- **CSS だけ特別扱い**。HTML の `<style>` はページの一部なのでフルリロード。
  外部 `<link>` だけが差し替え可能。
- **`web/` でビルドしない**。`zts dev` はディスクを配信するので、埋め込みを作り直しても
  プレビューは 1 バイトも変わらない。ビルドの目的は Zig の型検査だけ。
- **`zts dev` はアプリを起動しない**（既知の制約）。`invoke` の往復を見るには
  `zts build` して実行ファイルを起動する。CLI リファレンスに明記した。
