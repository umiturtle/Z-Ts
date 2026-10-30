#!/usr/bin/env python3
"""`examples/gallery` の同梱フォント（ZTS Sans / ZTS Mono）を作り直す。

なぜフォントを同梱するのか
--------------------------
CI のスクリーンショットは **3 OS で同じ画素** になる必要がある。ところが OS ごとに
システムフォントが違う（macOS: Hiragino / Windows: Yu Gothic / Ubuntu: 何も無い＝豆腐）ため、
同じ HTML でも文字の形・幅・字間がすべて変わり、比較が成立しない。
本スクリプトは Noto Sans JP（CJK + Latin）と JetBrains Mono を **使う文字だけに絞って**
woff2 にし、`examples/gallery/src/web/fonts/` に置く。ギャラリーはこれを `@font-face` で
読み込むので、3 OS のブラウザは同じファイルを描画する。

依存（ローカルのみ・CI では走らせない）:
    pip install --break-system-packages fonttools brotli
    node/npm（`npm pack` で取得するため）

使い方:
    python3 scripts/build-fonts.py

カバレッジ:
    収録文字を `examples/gallery/src/web/fonts/coverage.txt` に書き出す。
    `node scripts/verify-screenshots.mjs --check-font-coverage` が
    「examples 配下のデモ HTML に出てくる文字がすべて収録されているか」を検証するので、
    文言を足したら本スクリプトを再実行すること。
"""

from __future__ import annotations

import io
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

from fontTools.ttLib import TTFont
from fontTools.subset import Options, Subsetter

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "examples" / "gallery" / "src" / "web" / "fonts"

# 収録する範囲（デモに必ず出る文字 + 将来の追記である程度耐える範囲）。
ALWAYS = "".join(chr(c) for c in range(0x20, 0x7F))  # printable ASCII
RANGES = [
    (0x00A0, 0x00FF),  # Latin-1
    (0x2010, 0x203A),  # dashes / quotes / bullets
    (0x2160, 0x217F),  # roman numerals
    (0x2190, 0x21FF),  # arrows
    (0x2500, 0x257F),  # box drawing
    (0x25A0, 0x25FF),  # geometric shapes
    (0x3000, 0x30FF),  # CJK punctuation + hiragana + katakana
    (0x4E00, 0x9FFF),  # 漢字（下で実際に使う文字だけに絞る）
    (0xFF01, 0xFF60),  # 全角英数記号
    (0xFFE0, 0xFFE6),  # 全角記号
]

SOURCES = [
    # (npm package, weight, type)
    ("@fontsource/noto-sans-jp", 400, "sans"),
    ("@fontsource/noto-sans-jp", 700, "sans"),
    ("@fontsource/noto-serif-jp", 400, "serif"),
    ("@fontsource/jetbrains-mono", 400, "mono"),
]

FAMILY = {"sans": "ZTS Sans", "serif": "ZTS Serif", "mono": "ZTS Mono"}


def demo_characters() -> str:
    """`examples/` 配下のデモ成果物に現れる非 ASCII 文字を集める。"""
    chars: set[str] = set()
    for pattern in ("**/*.html", "**/*.ts", "**/*.js", "**/*.md", "**/*.zig"):
        for path in (ROOT / "examples").glob(pattern):
            if "node_modules" in path.parts or "zig-out" in path.parts or ".zig-cache" in path.parts:
                continue
            try:
                chars.update(path.read_text(encoding="utf-8", errors="ignore"))
            except OSError:
                continue
    return "".join(sorted(c for c in chars if ord(c) > 0x7E))


def wanted_text() -> str:
    base = [ALWAYS]
    for lo, hi in RANGES[:7]:
        base.append("".join(chr(c) for c in range(lo, hi + 1)))
    # 漢字・全角記号は「デモで実際に使う文字」だけに絞る（フォントサイズを 1 桁 KB に保つ）。
    base.append(demo_characters())
    return "".join(base)


def npm_pack(spec: str, workdir: pathlib.Path) -> pathlib.Path:
    out = subprocess.run(
        ["npm", "pack", spec, "--pack-destination", str(workdir)],
        check=True, capture_output=True, text=True,
    ).stdout.strip().splitlines()[-1]
    return workdir / out


def font_member(tar: tarfile.TarFile, weight: int, kind: str) -> str:
    if kind == "mono":
        want = f"package/files/jetbrains-mono-latin-{weight}-normal.woff2"
    else:
        want = f"package/files/noto-{kind}-jp-japanese-{weight}-normal.woff2"
    for name in tar.getnames():
        if name == want:
            return name
    raise SystemExit(f"missing {want} in the npm tarball")


def rename(font: TTFont, family: str, weight: int) -> None:
    style = "Bold" if weight >= 700 else "Regular"
    ps = family.replace(" ", "") + "-" + style
    full = f"{family} {style}"
    table = font["name"]
    for record in list(table.names):
        if record.nameID == 1:
            record.string = family
        elif record.nameID == 2:
            record.string = style
        elif record.nameID == 3:
            record.string = f"{ps};{weight};ZTS"
        elif record.nameID == 4:
            record.string = full
        elif record.nameID == 6:
            record.string = ps
        elif record.nameID == 16:
            record.string = family
        elif record.nameID == 17:
            record.string = style
        elif record.nameID in (0, 7, 8, 9, 13, 14):
            continue
    font["OS/2"].usWeightClass = weight


def build() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    text = wanted_text()
    unique = "".join(dict.fromkeys(text))
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = pathlib.Path(tmp)
        for spec, weight, kind in SOURCES:
            tarball = npm_pack(spec, tmpdir)
            with tarfile.open(tarball) as tar:
                member = tar.extractfile(font_member(tar, weight, kind))
                data = io.BytesIO(member.read())  # type: ignore[union-attr]

            font = TTFont(data)
            options = Options()
            options.flavor = "woff2"
            options.desubroutinize = True
            options.layout_features = ["*"]
            options.name_IDs = ["*"]
            options.name_legacy = True
            options.notdef_outline = True
            options.recalc_bounds = True
            subsetter = Subsetter(options=options)
            subsetter.populate(text=unique)
            subsetter.subset(font)
            rename(font, FAMILY[kind], weight)

            suffix = f"{weight}"
            target = OUT_DIR / f"zts-{kind}-{suffix}.woff2"
            font.flavor = "woff2"
            font.save(target)
            covered = TTFont(target).getBestCmap()
            print(f"{target.relative_to(ROOT)}: {target.stat().st_size} bytes, {len(covered)} glyphs")

    (OUT_DIR / "coverage.txt").write_text(
        "# examples/gallery/src/web/fonts に収録されている文字（scripts/build-fonts.py が生成）\n"
        + "".join(sorted(set(text)))
        + "\n",
        encoding="utf-8",
    )
    print(f"coverage: {len(set(text))} characters")


if __name__ == "__main__":
    build()
