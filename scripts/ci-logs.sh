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

python3 - "$REPO_SLUG" "$RUN_ID" << 'EOF'
import json, subprocess, sys

repo_slug, run_id = sys.argv[1], sys.argv[2]

run_meta = json.loads(subprocess.check_output(
    ["gh", "api", f"repos/{repo_slug}/actions/runs/{run_id}"], text=True
))
print("==================================================================")
print(f" Workflow Run #{run_id}")
print(f" Name       : {run_meta.get('name')}")
print(f" Branch     : {run_meta.get('head_branch')} ({(run_meta.get('head_sha') or '')[:7]})")
print(f" Status     : {run_meta.get('status')} / conclusion={run_meta.get('conclusion')}")
print(f" URL        : {run_meta.get('html_url')}")
print("==================================================================")

jobs_data = json.loads(subprocess.check_output(
    ["gh", "api", f"repos/{repo_slug}/actions/runs/{run_id}/jobs"], text=True
))

for job in jobs_data.get("jobs", []):
    jid = job["id"]
    print(f"\n### Job: {job['name']} (id={jid}) -> {job['status']} / {job.get('conclusion')}")
    for st in job.get("steps", []):
        mark = {"success": "OK", "failure": "FAIL", "skipped": "SKIP"}.get(
            st.get("conclusion") or "", st.get("status", "")
        )
        print(f"  [{mark:<4}] {st['name']}")

    cr = json.loads(subprocess.check_output(
        ["gh", "api", f"repos/{repo_slug}/check-runs/{jid}"], text=True
    ))
    summary = (cr.get("output") or {}).get("summary") or ""
    if summary.strip():
        print("\n  --- Step Summary / Captured Output ---")
        for line in summary.strip().splitlines():
            print(f"  {line}")
EOF
