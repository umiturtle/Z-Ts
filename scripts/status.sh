#!/usr/bin/env bash
set -euo pipefail

# scripts/status.sh — Context Recovery & Multi-Agent Coordination Radar
# Run this FIRST on every new chat, after any context reset, and before claiming a task.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CUR_BRANCH="$(git branch --show-current 2>/dev/null || echo 'detached')"

echo "=================================================================="
echo " Z-Ts Agent Status & Parallel Coordination Radar"
echo "=================================================================="
echo "Current branch : ${CUR_BRANCH}"
echo "HEAD commit    : $(git log -1 --oneline 2>/dev/null || echo 'none')"
echo ""

echo "--- [1] Working Tree & Recent Branch Commits ---"
git status -s || true
git log -n 5 --oneline 2>/dev/null || true
echo ""

echo "--- [2] Active Task File(s) Modified on This Branch ---"
BASE_REF="origin/main"
git rev-parse --verify "$BASE_REF" >/dev/null 2>&1 || BASE_REF="main"
TOUCHED_TASKS="$( (git diff --name-only "${BASE_REF}...HEAD" -- 'docs/tasks/*.md' 2>/dev/null; git status -s -- 'docs/tasks/*.md' 2>/dev/null | awk '{print $2}') | sort -u | grep -v 'TEMPLATE.md' || true )"
if [[ -n "$TOUCHED_TASKS" ]]; then
  for tf in $TOUCHED_TASKS; do
    if [[ -f "$tf" ]]; then
      echo ">>> ${tf}"
      sed -n '1,35p' "$tf" | sed 's/^/    /'
    fi
  done
else
  echo "  (No task shard modified on this branch yet)"
fi
echo ""

echo "--- [3] All Task Shards in Local Workspace (docs/tasks/) ---"
python3 - << 'EOF'
import glob, os, re

files = sorted(glob.glob("docs/tasks/*.md"))
rows = []
for f in files:
    base = os.path.basename(f)
    if base == "TEMPLATE.md":
        continue
    txt = open(f, encoding="utf-8").read()
    st = re.search(r"^- \*\*Status\*\*:\s*(.+)$", txt, re.M)
    br = re.search(r"^- \*\*Branch\*\*:\s*(.+)$", txt, re.M)
    ow = re.search(r"^- \*\*Scope\*\*:\s*(.+)$", txt, re.M)
    rows.append((
        base[:-3],
        st.group(1).strip() if st else "unknown",
        br.group(1).strip() if br else "-",
        ow.group(1).strip() if ow else "-",
    ))
if not rows:
    print("  (No task shards yet)")
else:
    for tid, st, br, sc in rows:
        print(f"  [{st:<12}] {tid:<28} branch={br}  scope={sc}")
EOF
echo ""

echo "--- [4] Parallel Agents Radar (Remote Branches & Open PRs) ---"
git fetch --prune --quiet origin 2>/dev/null || echo "  (offline: showing cached remote refs)"
for ref in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ | grep -vE 'origin/(HEAD|main|ci-cache)' || true); do
  bname="${ref#origin/}"
  last_msg="$(git log -1 --format='%h %cr: %s' "$ref" 2>/dev/null || true)"
  b_tasks="$(git diff --name-only "${BASE_REF}...${ref}" -- 'docs/tasks/*.md' 'src/' 2>/dev/null | tr '\n' ' ' || true)"
  marker=" "
  [[ "$bname" == "$CUR_BRANCH" ]] && marker="*"
  echo " ${marker} branch: ${bname} (${last_msg})"
  [[ -n "$b_tasks" ]] && echo "     touched: ${b_tasks}"
done

if command -v gh >/dev/null 2>&1; then
  echo "  Open PRs:"
  gh pr list --state open --limit 15 --json number,title,headRefName,updatedAt \
    --template '{{range .}}    #{{.number}} [{{.headRefName}}] {{.title}} ({{timeago .updatedAt}}){{"\n"}}{{end}}' 2>/dev/null || echo "    (none or unavailable)"
fi
echo ""

echo "--- [5] Local Container Toolchains & Cache Health ---"
ZIG_ST="$(zig version 2>/dev/null || echo 'MISSING (auto-installed on ./zigw)')"
CACHE_ST="COLD"
[[ -d "${HOME}/.cache/zig/o" ]] && CACHE_ST="WARM ($(du -sh "${HOME}/.cache/zig" 2>/dev/null | awk '{print $1}'))"
RUST_ST="$(rustc --version 2>/dev/null || echo 'MISSING (run: bash scripts/setup-toolchains.sh --rust)')"
GTK_ST="MISSING (run: bash scripts/setup-toolchains.sh --sysroot)"
if pkg-config --exists gtk+-3.0 webkit2gtk-4.1 2>/dev/null; then
  GTK_ST="READY (gtk $(pkg-config --modversion gtk+-3.0), webkit2gtk $(pkg-config --modversion webkit2gtk-4.1))"
fi
SUBMOD_ST="MISSING (run: bash scripts/setup-toolchains.sh --submodules)"
[[ -f "vendor/tauri/Cargo.toml" && -f "vendor/wry/Cargo.toml" && -f "vendor/tao/Cargo.toml" ]] && SUBMOD_ST="READY (tauri, wry, tao)"

echo "  zig          : ${ZIG_ST}"
echo "  ~/.cache/zig : ${CACHE_ST}"
echo "  rust         : ${RUST_ST}"
echo "  linux-sysroot: ${GTK_ST}"
echo "  vendor/      : ${SUBMOD_ST}"
echo "=================================================================="
