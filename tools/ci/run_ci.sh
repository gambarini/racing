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

# Local runs from parallel agent worktrees serialize on one machine-wide lock: three concurrent
# runs pushed the load average to 8-14 and failed the wall-time checks (session 2026-10-18).
# GitHub CI ($CI set) and RUN_CI_NO_LOCK=1 skip it. A lock whose owner pid is gone is stale.
if [ -z "${CI:-}" ] && [ -z "${RUN_CI_NO_LOCK:-}" ]; then
  LOCK="${RUN_CI_LOCK:-/tmp/racing-run-ci.lock}"
  waited=0
  until mkdir "$LOCK" 2>/dev/null; do
    if [ ! -d "$LOCK" ]; then echo "run_ci: can't create $LOCK, running without the lock"; LOCK=; break; fi
    owner="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
    [ $((waited % 60)) -eq 0 ] && echo "run_ci: waiting for another local run (pid ${owner:-?}, $(cat "$LOCK/dir" 2>/dev/null)); ${waited}s"
    sleep 5; waited=$((waited + 5))
  done
  if [ -n "$LOCK" ]; then
    echo $$ > "$LOCK/pid"; echo "$ROOT" > "$LOCK/dir"
    trap 'rm -rf "$LOCK"' EXIT
    trap 'exit 130' INT TERM
  fi
fi

# Sharding (#194): SHARD="i/n" (0-based i) runs only the steps assigned to shard i; unset runs all.
# Heavy steps are pinned (measured wall seconds in parentheses), the rest go round-robin.
# Import always runs. The ai_lap pair and its determinism compare stay together in shard 1.
SHARD_I=0; SHARD_N=1
if [ -n "${SHARD:-}" ]; then SHARD_I="${SHARD%/*}"; SHARD_N="${SHARD#*/}"; fi
rr=0
in_shard() { # name -> 0 if this run should execute it
  [ "$SHARD_N" -le 1 ] && return 0
  local want
  case "$1" in
    import) want=$SHARD_I ;;                         # every shard imports
    ai_personality_check) want=0 ;;                  # (116)
    ai_tactics_check|ai_lap_check_*) want=1 ;;       # (58) (27+27)
    tests|ai_driver_check|quarry_*) want=2 ;;        # (33) (38) (19+19+11+9)
    *) want=$((rr % SHARD_N)); rr=$((rr + 1)) ;;
  esac
  [ $((want % SHARD_N)) -eq "$SHARD_I" ]
}

# Wall-clock-sensitive checks: locally, a failure is retried once and logged as RETRY, so a
# load spike from a benchmark or a single-check run elsewhere doesn't fail the gate. CI never retries.
TIMING_STEPS=" quarry_timetrial_check telemetry_check surface_cache_timing_check "

run_once() { # tag, name, log, command...  (tag: "STEP FAILED", or "ATTEMPT FAILED" before a retry)
  local tag="$1" name="$2" log="$3"; shift 3
  echo "::group::$name"
  "$@" 2>&1 | tee "$log"
  local code=${PIPESTATUS[0]}
  echo "::endgroup::"
  if [ "$code" -ne 0 ]; then echo "$tag: $name (exit $code)"; return 1; fi
  if grep -E "(SCRIPT ERROR|ERROR):" "$log" >/dev/null; then
    echo "$tag: $name (ERROR in output)"; grep -nE "SCRIPT ERROR|ERROR:" "$log" | head -20; return 1
  fi
}

TIMES="$LOGDIR/step-times.txt"; : > "$TIMES"
run_step() { # name, then command...
  local name="$1"; shift
  in_shard "$name" || return 0
  local t0=$SECONDS
  run_step_inner "$name" "$@"
  echo "$((SECONDS - t0)) $name" >> "$TIMES"
}
run_step_inner() {
  local name="$1"; shift
  local log="$LOGDIR/$name.log"
  if [ -z "${CI:-}" ] && [[ "$TIMING_STEPS" == *" $name "* ]]; then
    run_once "ATTEMPT FAILED" "$name" "$log" "$@" && return 0
    echo "RETRY: $name (timing check, load: $(uptime | sed 's/.*load averages*: //'))"
  fi
  run_once "STEP FAILED" "$name" "$log" "$@" && return 0
  rc=1
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
if [ -z "${SKIP_IMPORT:-}" ]; then
echo "::group::import-warmup"
"$GODOT" --headless --path project --import --quit > "$LOGDIR/import-warmup.log" 2>&1 || true
echo "::endgroup::"
run_step import "$GODOT" --headless --path project --import --quit
fi
# GitHub CI (#194): the serial run exceeded the 10-min workflow timeout (the workflow file can't be
# changed by the agent token), so run 3 shards as parallel processes on the 4-vCPU runner after the
# single import. RUN_CI_SERIAL=1 or an explicit SHARD keeps the old serial behaviour.
if [ -n "${CI:-}" ] && [ -z "${SHARD:-}" ] && [ -z "${RUN_CI_SERIAL:-}" ]; then
  pids=()
  for i in 0 1 2; do
    SHARD="$i/3" SKIP_IMPORT=1 bash "$0" "$LOGDIR/shard$i" > "$LOGDIR/shard$i.out" 2>&1 &
    pids+=($!)
  done
  for k in 0 1 2; do
    wait "${pids[$k]}" || rc=1
    echo "::group::shard $k output"; cat "$LOGDIR/shard$k.out"; echo "::endgroup::"
  done
  echo "== per-step wall time (s), slowest first =="; cat "$TIMES" "$LOGDIR"/shard*/step-times.txt | sort -rn | head -25
  echo "total: $SECONDS s"
  if [ "$rc" -eq 0 ]; then echo "RESULT OK"; else echo "RESULT FAILED"; fi
  exit $rc
fi
run_step tests "$GODOT" --headless --path project -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
for f in project/tests/*_check.gd project/tests/check_*.gd; do
  n="$(basename "$f" .gd)"
  [ "$n" = "ai_lap_check" ] && continue  # run twice below (determinism)
  run_step "$n" "$GODOT" --headless --fixed-fps 120 --path project -s "res://tests/$n.gd"
done
# Headless AI lap test (#34): the whole test runs twice (two processes) and the lap CSVs must be
# identical. CSVs land in $LOGDIR/ai_lap_1 and ai_lap_2 for archiving (~45 s each).
for k in 1 2; do
  AI_LAP_OUT="$LOGDIR/ai_lap_$k" run_step "ai_lap_check_$k" "$GODOT" --headless --fixed-fps 120 --path project -s res://tests/ai_lap_check.gd
done
if [ "$SHARD_N" -gt 1 ] && [ "$SHARD_I" -ne 1 ]; then :
elif cmp -s "$LOGDIR/ai_lap_1/ai_lap_laps.csv" "$LOGDIR/ai_lap_2/ai_lap_laps.csv" && [ -s "$LOGDIR/ai_lap_1/ai_lap_laps.csv" ]; then
  echo "PASS: ai_lap_check lap ticks identical across two runs"
else
  echo "STEP FAILED: ai_lap_check determinism (lap CSVs differ or missing)"; diff "$LOGDIR/ai_lap_1/ai_lap_laps.csv" "$LOGDIR/ai_lap_2/ai_lap_laps.csv" | head; rc=1
fi
echo "== per-step wall time (s), slowest first =="; sort -rn "$TIMES"; echo "total: $SECONDS s"
exit $rc
