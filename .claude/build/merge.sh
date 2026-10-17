#!/usr/bin/env bash
# Merge one QA-passed (and reviewed) PR and clean up after it.
# Usage: .claude/build/merge.sh <pr> <issue> [agent-id ...]
#   agent-id: the Agent tool ids of this item's worktree agents (builder, QA, reviewer, fix rounds).
# Exit codes: 0 merged, 2 checks not all passing (nothing done), 1 merge failed.
# It does not judge QA/review verdicts or whether main moved in the same area: the orchestrator does.
set -uo pipefail

pr="${1:?pr number}"
issue="${2:?issue number}"
shift 2
root="$(cd "$(dirname "$0")/../.." && pwd)"
cfg="$root/.claude/build/config.json"
repo=$(jq -r .repo "$cfg")
main=$(jq -r .main_checkout "$cfg")
base=$(jq -r .base_branch "$cfg")

# 1. Every check must be `pass` (or `skipping`). Pending or failing -> stop without touching anything.
states=$(gh pr checks "$pr" -R "$repo" --json bucket --jq '.[].bucket' 2>/dev/null || true)
if [[ -z "$states" ]]; then
  echo "merge: #$pr has no checks reported yet"; exit 2
fi
bad=$(grep -cvE '^(pass|skipping)$' <<<"$states" || true)
if [[ "$bad" != "0" ]]; then
  echo "merge: #$pr checks not all passing: $(sort <<<"$states" | uniq -c | tr -s ' \n' ' ')"; exit 2
fi

# 2. Ready + squash-merge. Judge by PR state, not the exit code (local branch deletion
#    fails while a worktree still holds the branch).
[[ "$(gh pr view "$pr" -R "$repo" --json isDraft --jq .isDraft)" == "true" ]] && gh pr ready "$pr" -R "$repo" >/dev/null
gh pr merge "$pr" -R "$repo" --squash --delete-branch >/dev/null 2>&1 || true
state=$(gh pr view "$pr" -R "$repo" --json state --jq .state)
if [[ "$state" != "MERGED" ]]; then
  echo "merge: #$pr not merged (state $state)"; exit 1
fi
head_branch=$(gh pr view "$pr" -R "$repo" --json headRefName --jq .headRefName)

# 3. Update the main checkout and the board.
git -C "$main" fetch -q && git -C "$main" pull -q --ff-only origin "$base"
"$root/.claude/build/board.sh" "$issue" done || echo "merge: board update failed for #$issue"

# 4. Remove this item's agent worktrees and branches, then the PR's local branch.
for a in "$@"; do
  wt="$main/.claude/worktrees/agent-$a"
  [[ -d "$wt" ]] && git -C "$main" worktree remove -f -f "$wt" 2>/dev/null
  git -C "$main" branch -D "worktree-agent-$a" >/dev/null 2>&1
done
git -C "$main" worktree prune
git -C "$main" branch -D "$head_branch" >/dev/null 2>&1

left=$(git -C "$main" worktree list | wc -l | tr -d ' ')
echo "merge: #$pr MERGED as $(git -C "$main" log --oneline -1); worktrees left: $left"
