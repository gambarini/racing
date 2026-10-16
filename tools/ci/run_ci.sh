#!/usr/bin/env bash
# Headless import + GUT + *_check.gd scripts. Used by CI and runnable locally.
# Usage: GODOT=/path/to/godot tools/ci/run_ci.sh [logdir]
# Without GODOT: uses `godot` from PATH, else the macOS app bundle.
# Fails on non-zero exit or any "ERROR:" / "SCRIPT ERROR" in the output.
set -u
MAC_GODOT=/Applications/Godot.app/Contents/MacOS/Godot
if [ -z "${GODOT:-}" ]; then
  if command -v godot >/dev/null 2>&1; then GODOT=godot
  elif [ -x "$MAC_GODOT" ]; then GODOT="$MAC_GODOT"
  else echo "Godot not found: set GODOT or put godot on PATH"; exit 1
  fi
fi
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
# Importing an LFS pointer instead of the real file makes Godot write an invalid .import
# (valid=false), which then gets committed by accident. Refuse to run until `git lfs pull`.
if command -v git-lfs >/dev/null 2>&1; then
  missing="$(git lfs ls-files 2>/dev/null | awk '$2 == "-" {print $3}')"
  if [ -n "$missing" ]; then
    echo "LFS objects not checked out (run: git lfs pull):"; echo "$missing" | head -20; exit 1
  fi
fi
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
