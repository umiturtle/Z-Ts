#!/usr/bin/env bash
set -euo pipefail

# scripts/ci-logs.sh — Firewall-safe GitHub Actions status & full log reader for Arena
#
# NOTE: In Arena sandboxes, `gh run view --log` fails with EOF because raw log zip URLs
# redirect to `results-receiver.actions.githubusercontent.com` (outside the outbound allowlist).
# Every job in `.github/workflows/ci.yml` mirrors its build/test/benchmark output into
# `$GITHUB_STEP_SUMMARY`, which is served directly by `api.github.com` Check Runs API!

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

REPO_SLUG="$(git remote get-url origin | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
BRANCH="$(git branch --show-current)"
RUN_ID="${1:-}"

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(gh api "repos/${REPO_SLUG}/actions/runs?branch=${BRANCH}&per_page=1" --jq '.workflow_runs[0].id // empty')"
fi

if [[ -z "$RUN_ID" ]]; then
  echo "No workflow runs found for branch '${BRANCH}'." >&2
  exit 1
fi

RUN_META="$(gh api "repos/${REPO_SLUG}/actions/runs/${RUN_ID}")"
echo "=================================================================="
echo " Workflow Run #${RUN_ID}"
echo "$RUN_META" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(f" Name       : {d.get(\"name\")}")
print(f" Branch     : {d.get(\"head_branch\")} ({d.get(\"head_sha\", \"\")[:7]})")
print(f" Status     : {d.get(\"status\")} / conclusion={d.get(\"conclusion\")}")
print(f" URL        : {d.get(\"html_url\")}")
'
echo "=================================================================="

JOBS_JSON="$(gh api "repos/${REPO_SLUG}/actions/runs/${RUN_ID}/jobs")"
echo "$JOBS_JSON" | python3 - "$REPO_SLUG" << 'EOF'
import json, subprocess, sys

repo_slug = sys.argv[1]
data = json.load(sys.stdin)

for job in data.get("jobs", []):
    jid = job["id"]
    print(f"\n### Job: {job['name']} (id={jid}) -> {job['status']} / {job.get('conclusion')}")
    for st in job.get("steps", []):
        mark = {"success": "OK", "failure": "FAIL", "skipped": "SKIP"}.get(st.get("conclusion") or "", st.get("status", ""))
        print(f"  [{mark:<4}] {st['name']}")

    cr_raw = subprocess.check_output(["gh", "api", f"repos/{repo_slug}/check-runs/{jid}"], text=True)
    cr = json.loads(cr_raw)
    summary = (cr.get("output") or {}).get("summary") or ""
    if summary.strip():
        print("\n  --- Step Summary / Captured Output ---")
        for line in summary.strip().splitlines():
            print(f"  {line}")
EOF
