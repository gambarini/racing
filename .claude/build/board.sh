#!/usr/bin/env bash
# Set an issue's Status on the roadmap Project board.
# Usage: .claude/build/board.sh <issue> <todo|in_progress|done>
# Reads IDs from .claude/build/config.json and caches item ids in <state_dir>/project_items.json.
# If the issue isn't cached, the cache is rebuilt; if it isn't on the board, it is added first.
set -euo pipefail

issue="${1:?issue number}"
status="${2:?todo|in_progress|done}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
cfg="$root/.claude/build/config.json"

repo=$(jq -r .repo "$cfg")
owner=$(jq -r .project.owner "$cfg")
number=$(jq -r .project.number "$cfg")
project_id=$(jq -r .project.id "$cfg")
field_id=$(jq -r .project.status_field "$cfg")
option_id=$(jq -r --arg s "$status" '.project.status[$s] // empty' "$cfg")
[[ -n "$option_id" ]] || { echo "board: unknown status '$status'" >&2; exit 2; }
cache="$(jq -r .state_dir "$cfg")/project_items.json"

rebuild_cache() {
  gh project item-list "$number" --owner "$owner" --limit 500 --format json \
    --jq '[.items[]|{key:(.content.number|tostring),value:.id}]|from_entries' > "$cache"
}

item_id() { [[ -f "$cache" ]] && jq -r --arg n "$issue" '.[$n] // empty' "$cache"; }

id=$(item_id || true)
if [[ -z "$id" ]]; then
  rebuild_cache
  id=$(item_id || true)
fi
if [[ -z "$id" ]]; then
  gh project item-add "$number" --owner "$owner" --url "https://github.com/$repo/issues/$issue" >/dev/null
  rebuild_cache
  id=$(item_id || true)
fi
[[ -n "$id" ]] || { echo "board: #$issue not found on project $number" >&2; exit 1; }

gh project item-edit --id "$id" --project-id "$project_id" --field-id "$field_id" \
  --single-select-option-id "$option_id" >/dev/null
echo "board: #$issue -> $status"
