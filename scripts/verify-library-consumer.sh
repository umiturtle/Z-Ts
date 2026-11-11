#!/usr/bin/env bash
# Prove that the source archive a release ships is usable as a plain library dependency.
#
# `tests/library-consumer/` is a real, separate Zig package. During development it depends on
# this checkout via `.path`; here we replace that with the `.url` + `.hash` of the archive, then
# build and run it with a *cold* global cache so nothing can be resolved from a local checkout.
#
# Usage: scripts/verify-library-consumer.sh <z_ts-VERSION.tar.gz>
# Env:   ZTS_ZIG (optional) — the zig binary to use; defaults to `zig` on PATH.

set -euo pipefail

archive=${1:?usage: verify-library-consumer.sh <z_ts-VERSION.tar.gz>}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zig=${ZTS_ZIG:-$(command -v zig || true)}
if [ -z "$zig" ]; then
    echo "error: zig not found — set ZTS_ZIG or put Zig 0.17.0 on PATH" >&2
    exit 1
fi

archive=$(realpath "$archive")
if [ ! -f "$archive" ]; then
    echo "error: archive not found: $archive" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

hash=$("$zig" fetch "file://$archive" 2>/dev/null)
case "$hash" in
    z_ts-*) ;;
    *) echo "error: unexpected zig fetch hash for $(basename "$archive"): $hash" >&2; exit 1 ;;
esac
echo "archive: $archive"
echo "hash:    $hash"

cp -R "$root/tests/library-consumer" "$work/consumer"
rm -rf "$work/consumer/.zig-cache" "$work/consumer/zig-out"

python3 - "$work/consumer/build.zig.zon" "$archive" "$hash" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
placeholder = '.z_ts = .{ .path = "../.." },'
if placeholder not in text:
    raise SystemExit("consumer build.zig.zon lost its .path placeholder")
replacement = (
    '.z_ts = .{ .url = "file://' + sys.argv[2] + '", .hash = "' + sys.argv[3] + '" },'
)
path.write_text(text.replace(placeholder, replacement), encoding="utf-8")
PY

echo "consumer dependency:"
grep '.z_ts' "$work/consumer/build.zig.zon"

cd "$work/consumer"
ZIG_GLOBAL_CACHE_DIR="$work/cache" "$zig" build verify 2>&1 | tee "$work/run.log"
if ! grep -q 'OK library consumer modules=4' "$work/run.log"; then
    echo "error: library consumer marker missing" >&2
    exit 1
fi
echo "OK library consumer: release archive resolved from a cold cache"
