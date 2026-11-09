# Task M5-17: Zig ソース編集時のインクリメンタルビルドを高速化する

- **Status**: `in_progress`
- **Branch**: `arena/e32503eb-z-ts`（main `aa2a054` 起点）
- **Scope**: `src/cli/{devserver,main,template,mod,incremental}.zig`, `scripts/bench-dev-loop.py`（新規）, `docs/reference/cli{,.en}.md`, `docs/learn/{ja,en}/{start,tutorials/counter}.md`, `docs/architecture/incremental-dev-build.md`（新規）, `docs/decisions/0020-incremental-dev-build.md`（新規）, `scripts/doc-sync.json`
- **Upstream Reference**: [`../architecture/00-overview.md`](../architecture/00-overview.md) / `AGENTS.md` §2（キャッシュ揮発）
- **Next Step**: 技術選定の実測を終えた。`src/cli/incremental.zig` を新規作成し、依存グラフ + dirty flag + 決定ロジックを実装する。

---

## 1. 依頼と完了条件

> 「Zigのソースをいじった時のインクリメンタルビルドを高速化して（dirty flag なり依存グラフなり
> 良さげな技術を検討してから実装（ちゃんとその実装で早くなったか？バグがないかなどはしっかり検証して））」

- [ ] 候補技術を**実測してから**選定する（完了・下記 §2）
- [ ] 実装して、`zts dev` の Zig 編集→リロードまでの時間が短縮されたことを**再現可能なベンチ**で示す
- [ ] 型エラーを依然として検出できること、失敗後に回復できること、不要な再ビルドが起きないことを検証
- [ ] 既存の挙動（CSS 差し替え / `web/` リロード / 3 OS 同じポーリング）を壊さない
- [ ] `./zigw quick-test` / `build test` / `docs-check` / `fmt --check` / 3 OS CI が緑
- [ ] 設計判断を ADR・設計メモ・タスク票に残す

## 2. 技術選定（実測）

生成プロジェクト（`/tmp/ztsbench/bench-app`, Zig 0.17.0, ウォームキャッシュ）で
`src/main.zig` に 1 行足して 7 回計測。

| 手法 | 中央値 | 判定 |
|---|---|---|
| 現状 `zig build`（install: LLVM codegen + link + copy） | **832 ms** | baseline |
| **`zig build check`**（emit されない compile step → `-fno-emit-bin`、型検査のみ） | **426 ms** | ✅ 採用（約 2.0x） |
| `zig build -fincremental` | 1956 ms | ❌ 2.4x **遅い**。0.17 の experimental incremental は小規模プロジェクトでは逆効果 |
| `zig build check -fincremental` | 1512 ms | ❌ 同上 |
| `zig build --watch`（Zig 自身のファイル監視 + 常驻ビルドサーバ） | panic `reached unreachable code` | ❌ この環境で不安定。しかも inotify/FSEvents 依存になり 3 OS 同一挙動の設計方針に反する |
| `zig build-exe -fno-emit-bin` をスタブ依存で直接実行 | 約 370 ms | 参考：これが **コンパイラ起動 + `std` 意味解析の下限**。build runner を bypass しても大差なし |
| 変更なし `zig build` | 29 ms | dirty flag が効けば 0 ms にできる |
| `zig build --list-steps` | 8 ms | `check` step の有無検出に使える |

`--summary all` の内訳: install は `compile exe … 836ms`、check は `compile exe … 367ms`。
つまりボトルネックは **プロセス起動ではなく LLVM codegen/link** だった。
`zts dev` は `web/` をディスクから配信しており Zig の実行ファイルを使わない
（[`../learn/ja/tutorials/counter.md`](../learn/ja/tutorials/counter.md) に明記）ので、
インクリメンタル時は **型検査だけで十分**。初回ビルドと `zts build` は従来どおり完全ビルド。

### 採用する 4 つの手法

1. **check-only build step**（上記。最大の効果）
   - 生成 `build.zig` に `check` step を追加。`b.addExecutable` したstep の出力を誰も要求しないと
     Zig 0.17 は自動で `-fno-emit-bin` を付ける（`lib/compiler/Maker/Step/Compile.zig:618`）。
   - 古いテンプレートのプロジェクトには `check` step が無い → `zig build --list-steps` で検出し、
     無ければ完全ビルドにフォールバック（**安全側**）。
   - `ZTS_DEV_BUILD=full` で完全ビルドに固定（リンクエラーまで見たい人 / ベンチの baseline 用）。
2. **dirty flag（内容ハッシュ）**
   - 現状の `mtime ^ size` だけだと `touch` やフォーマッタの同一内容書き戻しで再ビルドする。
     `src/**/*.zig` / `build.zig` / `build.zig.zon` は **内容ハッシュ**で比較し、stat は
     安価な事前フィルタに格下げ。内容が同じなら再ビルド 0 回。
   - `web/` は stat のまま（CSS 差し替えは無害なので読み増やしを避ける）。
3. **依存グラフ**
   - `src/main.zig` から相対 `@import` / `@embedFile` を辿り、到達可能なファイル集合を作る。
     到達不能な `src/scratch.zig` 等の編集はビルドもリロードもスキップ。
   - 解決できない import / ファイル追加削除 / `build.zig*` 変更は **完全ビルドにフォールバック**
     （誤ってスキップするより遅い方を選ぶ）。
4. **デバウンのバグ修正 + `build.zig*` の監視追加**
   - 現状は「1 回目の scan で差分を取って 120 ms 待ち、2 回目の scan を baseline にする」ため、
     **待機中に起きた変更が永遠に無視される**。最終 scan に対して差分を取るように直し、
     バーストを 1 回のビルドに畳む。
   - `build.zig` / `build.zig.zon` は今は監視対象外（ビルドグラフが変わっても無視される）。追加する。

### 却下した手法

- `-fincremental`: 実測で遅い。
- `--watch` / `--listen=-` 常驻ビルドサーバ: panic ＋ OS 依存のファイル監視。プロトコル実装の複雑さに
  見合う利点もない（下限 370 ms は意味解析そのもの）。
- スタブ `embedded_frontend` で直接 `build-exe`: build runner を bypass しても 370 ms の下限は変わらず、
  `build.zig` のモジュール構成を CLI が推測することになり壊れやすい。

## 3. 検証計画

- 再現可能ベンチ `scripts/bench-dev-loop.py`: `zts dev` を起動し、`src/main.zig` を編集して
  `/__zts_dev__/state` の `v` が進むまでの**実時間**を N 回計測。`ZTS_DEV_BUILD=full`（旧挙動）と
  既定（新挙動）を同じバイナリで比較。
- 回帰: 型エラーを混入 → `ok:false` / `v` 据え置き → 修正 → `ok:true` / `v` 加算。
- dirty flag: `touch` のみ → `v` 不変。到達不能ファイル編集 → `v` 不変。
- `build.zig` 変更 → 完全ビルド。`web/**/*.css` → 差し替えのみ（ビルドなし）。
- 単体テスト: 内容ハッシュ、構造変化、依存グラフ（循環・未解決 import・`@embedFile`）、`plan()` の全分岐。

## 4. 進捗チェックポイント

- **完了**: 現状調査・候補技術の実測・選定。このタスク票の作成と push（分散ロック）。
- **作業中**: `src/cli/incremental.zig` の実装。
- **未着手**: 実装・単体テスト・統合ベンチ・ドキュメント・ADR・同期台帳の再同期・PR。
