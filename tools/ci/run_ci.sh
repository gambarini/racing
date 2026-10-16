#!/usr/bin/env bash
# Headless import + GUT + *_check.gd scripts. Used by CI and runnable locally.
# Usage: GODOT=/path/to/godot tools/ci/run_ci.sh [logdir]
# Fails on non-zero exit or any "ERROR:" / "SCRIPT ERROR" in the output.
set -u
GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOGDIR="${1:-$ROOT/ci-logs}"
mkdir -p "$LOGDIR"
rc=0

run_step() { # name, then command...
  local name="$1"; shift
  local log="$LOGDIR/$name.log"
  echo "::group::$name"
  "$@" 2>&1 | tee "$log"
  local code=${PIPESTATUS[0]}
  echo "::endgroup::"
  if [ "$code" -ne 0 ]; then echo "STEP FAILED: $name (exit $code)"; rc=1; fi
  if grep -E "(SCRIPT ERROR|ERROR):" "$log" >/dev/null; then
    echo "STEP FAILED: $name (ERROR in output)"; grep -nE "SCRIPT ERROR|ERROR:" "$log" | head -20; rc=1
  fi
}

cd "$ROOT"
# Warm-up: on a fresh clone the first import emits spurious font/plugin ERRORs (resources are
# imported while plugins already load them). Not gating; the second pass below is.
echo "::group::import-warmup"
"$GODOT" --headless --path project --import --quit > "$LOGDIR/import-warmup.log" 2>&1 || true
echo "::endgroup::"
run_step import "$GODOT" --headless --path project --import --quit
run_step tests "$GODOT" --headless --path project -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
for f in project/tests/*_check.gd project/tests/check_*.gd; do
  n="$(basename "$f" .gd)"
  run_step "$n" "$GODOT" --headless --fixed-fps 120 --path project -s "res://tests/$n.gd"
done
exit $rc
