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
# Import always runs. 
SHARD_I=0; SHARD_N=1
if [ -n "${SHARD:-}" ]; then SHARD_I="${SHARD%/*}"; SHARD_N="${SHARD#*/}"; fi
rr=0
in_shard() { # name -> 0 if this run should execute it
  [ "$SHARD_N" -le 1 ] && return 0
  local want
  case "$1" in
    import) want=$SHARD_I ;;                         # every shard imports
    ai_personality_check) want=0 ;;                  # (116)
    ai_tactics_check|ai_lap_check) want=1 ;;         # (58) (~55)
    tests|ai_driver_check|quarry_*) want=2 ;;        # (33) (38) (20+20+12+12+9)
    *) want=$((rr % SHARD_N)); rr=$((rr + 1)) ;;
  esac
  [ $((want % SHARD_N)) -eq "$SHARD_I" ]
}

# Time budgets (#198): max seconds per check, so the PR that adds a slow check fails instead of main.
# Set from the measured step times of a CI=1 3-shard run with >= 1.5x headroom; unlisted checks get
# BUDGET_DEFAULT. Overrides for testing: CI_BUDGET_OVERRIDE="telemetry_check=1 tests=5" (name=seconds,
# space or comma separated), CI_BUDGET_DEFAULT=<s>. CI_TOTAL_CEILING=<s> (default 480, below the
# 10-min workflow timeout) bounds the whole run's wall time (lock waiting excluded).
BUDGET_DEFAULT="${CI_BUDGET_DEFAULT:-45}"
CEILING="${CI_TOTAL_CEILING:-480}"
BUDGET_TABLE=" import=60 tests=90 ai_personality_check=420 ai_tactics_check=330 ai_lap_check=140 ai_driver_check=125 "
budget_for() { # name -> seconds
  local name="$1" kv
  local ov="${CI_BUDGET_OVERRIDE:-}"; for kv in ${ov//,/ }; do
    [ "${kv%%=*}" = "$name" ] && { echo "${kv#*=}"; return; }
  done
  kv="${BUDGET_TABLE##* $name=}"
  if [ "$kv" != "$BUDGET_TABLE" ]; then echo "${kv%% *}"; return; fi
  case "$name" in quarry_*) echo 70 ;; *) echo "$BUDGET_DEFAULT" ;; esac
}
START=$SECONDS

# Wall-clock-sensitive checks: a failure is retried once and logged as RETRY, so a load spike (or the
# 3 parallel shards sharing 4 vCPUs, #198) doesn't fail the absolute-time gates. This applies inside
# shards and on GitHub CI too: the retry only costs time when the first attempt failed.
TIMING_STEPS=" quarry_timetrial_check telemetry_check surface_cache_timing_check terrain_alloc_check "

run_once() { # tag, name, log, command...  (tag: "STEP FAILED", or "ATTEMPT FAILED" before a retry)
  local tag="$1" name="$2" log="$3"; shift 3
  [ "$SHARD_N" -le 1 ] && echo "::group::$name"
  echo "STEP START: $name"
  "$@" 2>&1 | tee "$log"
  local code=${PIPESTATUS[0]}
  [ "$SHARD_N" -le 1 ] && echo "::endgroup::"
  if [ "$code" -ne 0 ]; then echo "$tag: $name (exit $code)"; return 1; fi
  if grep -E "(SCRIPT ERROR|ERROR):" "$log" >/dev/null; then
    echo "$tag: $name (ERROR in output)"; grep -nE "SCRIPT ERROR|ERROR:" "$log" | head -20; return 1
  fi
}

TIMES="$LOGDIR/step-times.txt"; : > "$TIMES"
run_step() { # name, then command...
  local name="$1"; shift
  in_shard "$name" || return 0
  local t0=$SECONDS dt budget
  run_step_inner "$name" "$@"
  dt=$((SECONDS - t0)); budget="$(budget_for "$name")"
  echo "STEP END: $name ${dt}s (budget ${budget}s)"
  echo "$dt $budget $name" >> "$TIMES"
  if [ "$dt" -gt "$budget" ]; then echo "BUDGET EXCEEDED: $name ${dt}s > ${budget}s"; rc=1; fi
}
print_times() { # files...: merged per-check table, slowest first
  echo "== per-check wall time vs budget (s), slowest first =="
  printf '%6s %6s  %s\n' time budget check
  cat "$@" 2>/dev/null | sort -rn | awk '{printf "%6d %6d  %s%s\n", $1, $2, $3, ($1 > $2 ? "  OVER BUDGET" : "")}'
}
check_ceiling() {
  local total=$((SECONDS - START))
  echo "total: ${total}s (ceiling ${CEILING}s)"
  if [ "$total" -gt "$CEILING" ]; then echo "CEILING EXCEEDED: total ${total}s > ceiling ${CEILING}s"; rc=1; fi
}
run_step_inner() {
  local name="$1"; shift
  local log="$LOGDIR/$name.log"
  if [[ "$TIMING_STEPS" == *" $name "* ]]; then
    # CI_FORCE_FIRST_FAIL=<name>: make the first attempt fail, to prove the retry path (also with CI=1).
    if [ "${CI_FORCE_FIRST_FAIL:-}" = "$name" ]; then run_once "ATTEMPT FAILED" "$name" "$log" false && return 0
    else run_once "ATTEMPT FAILED" "$name" "$log" "$@" && return 0; fi
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
  # Shard output streams live, prefixed [sN], with STEP START/END markers; a killed run's last marker
  # names the running check. Each shard's full output also lands in $LOGDIR/shardN.out.
  for i in 0 1 2; do
    ( SHARD="$i/3" SKIP_IMPORT=1 bash "$0" "$LOGDIR/shard$i" 2>&1 | tee "$LOGDIR/shard$i.out" \
        | awk -v p="[s$i] " '{print p $0; fflush()}'; exit "${PIPESTATUS[0]}" ) &
    pids+=($!)
  done
  kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill "$1" 2>/dev/null; }
  trap 'for p in "${pids[@]}"; do kill_tree "$p"; done; echo "KILLED"; exit 143' INT TERM
  for k in 0 1 2; do wait "${pids[$k]}" || rc=1; done
  trap - INT TERM
  print_times "$TIMES" "$LOGDIR"/shard*/step-times.txt
  check_ceiling
  if [ "$rc" -eq 0 ]; then echo "RESULT OK"; else echo "RESULT FAILED"; fi
  exit $rc
fi
run_step tests "$GODOT" --headless --path project -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
for f in project/tests/*_check.gd project/tests/check_*.gd; do
  n="$(basename "$f" .gd)"
  [ "$n" = "ai_lap_check" ] && continue  # run below with its CSV output dir
  run_step "$n" "$GODOT" --headless --fixed-fps 120 --path project -s "res://tests/$n.gd"
done
# Headless AI lap test (#34): ai_lap_check runs every combo twice in ONE process and asserts identical
# lap ticks (in-process determinism, #179). CSVs land in $LOGDIR/ai_lap for archiving (~55 s).
AI_LAP_OUT="$LOGDIR/ai_lap" run_step ai_lap_check "$GODOT" --headless --fixed-fps 120 --path project -s res://tests/ai_lap_check.gd
print_times "$TIMES"
check_ceiling
exit $rc
