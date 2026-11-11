#!/usr/bin/env bash
# Validate gitflow branch names and report the right PR base.
#
# This script NEVER creates, switches or pushes a branch. The repository owner owns the branch
# model; Arena agents work on a single `arena/*` ref per session and can only set a PR's *base*
# to whatever the owner created. Keeping validation here means CI can enforce the naming rules
# without any agent needing write access to another branch.
#
#   scripts/gitflow.sh                 # classify the current branch
#   scripts/gitflow.sh --check NAME    # validate one name (exit 1 when invalid)
#   scripts/gitflow.sh --self-test     # run the naming table (used by CI)

set -euo pipefail

is_slug() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; }
is_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; }

# Prints "<kind>|<pr-base>|<description>". The base is a recommendation, not an action.
classify() {
    local name=$1
    case "$name" in
        main)
            echo "trunk|main|the released branch; tags vX.Y.Z are cut here" ;;
        develop)
            echo "trunk|develop|integration branch for the next release" ;;
        feature/*)
            local slug=${name#feature/}
            is_slug "$slug" || return 1
            echo "feature|develop|one unit of work; merge into develop" ;;
        release/*)
            local v=${name#release/}
            is_version "$v" || return 1
            echo "release|main|version freeze; tag v$v on main, then back-merge to develop" ;;
        hotfix/*)
            local v=${name#hotfix/}
            is_version "$v" || return 1
            echo "hotfix|main|urgent fix; tag v$v on main, then back-merge to develop" ;;
        arena/*)
            local slug=${name#arena/}
            is_slug "$slug" || return 1
            echo "agent|main|Arena agent ref; the PR base follows the owner's branch model" ;;
        *)
            return 1 ;;
    esac
}

self_test() {
    local ok=(
        "main" "develop"
        "feature/window-state" "feature/rpc.retry"
        "release/0.1.1" "release/1.0.0-beta.1"
        "hotfix/0.1.2"
        "arena/c1ae6863-z-ts"
    )
    local bad=(
        "feature/Uppercase" "feature/" "release/beta-1.0"
        "hotfix/v1.0" "topic/thing" "main/extra"
    )
    local name
    for name in "${ok[@]}"; do
        classify "$name" >/dev/null || { echo "FAIL: expected valid: $name" >&2; return 1; }
    done
    for name in "${bad[@]}"; do
        if classify "$name" >/dev/null 2>&1; then
            echo "FAIL: expected invalid: $name" >&2
            return 1
        fi
    done
    # A version branch must name the same version the package declares.
    echo "OK gitflow names=${#ok[@]} rejected=${#bad[@]}"
}

case "${1:-}" in
    --self-test)
        self_test ;;
    --check)
        name=${2:?usage: gitflow.sh --check <branch-name>}
        if info=$(classify "$name"); then
            IFS='|' read -r kind base description <<<"$info"
            printf 'OK %s (%s) -> base %s — %s\n' "$name" "$kind" "$base" "$description"
        else
            echo "INVALID branch name: $name" >&2
            echo "expected: main | develop | feature/<slug> | release/<x.y.z> | hotfix/<x.y.z> | arena/<slug>" >&2
            exit 1
        fi ;;
    "")
        current=$(git branch --show-current)
        [ -n "$current" ] || { echo "error: detached HEAD" >&2; exit 1; }
        if info=$(classify "$current"); then
            IFS='|' read -r kind base description <<<"$info"
            printf 'branch: %s (%s)\nPR base: %s\n%s\n' "$current" "$kind" "$base" "$description"
        else
            echo "INVALID branch name: $current" >&2
            exit 1
        fi ;;
    *)
        echo "usage: gitflow.sh [--check NAME] [--self-test]" >&2
        exit 2 ;;
esac
