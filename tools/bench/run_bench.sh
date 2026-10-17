#!/usr/bin/env bash
# Rerun the #17 vehicle-sim benchmarks (not part of tools/ci/run_ci.sh).
#   tools/bench/run_bench.sh            full 12-car tick + per-stage split (GDScript)
#   tools/bench/run_bench.sh core       4-wheel core: GDScript vs GDExtension C++ (builds it first)
#   tools/bench/run_bench.sh all
# Env: GODOT=/path/to/godot, BENCH_CARS / BENCH_WARMUP / BENCH_TICKS for the vehicle bench.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
cd "$ROOT"
git lfs pull >/dev/null 2>&1 || true
"$GODOT" --headless --path project --import --quit >/dev/null 2>&1 || true
mode="${1:-vehicle}"
if [ "$mode" = vehicle ] || [ "$mode" = all ]; then
  "$GODOT" --headless --fixed-fps 120 --path project -s ../tools/bench/vehicle_bench.gd
fi
if [ "$mode" = terrain ]; then # #22: needs a window for render numbers
  "$GODOT" --path project -s ../tools/bench/terrain_bench.gd
fi
if [ "$mode" = core ] || [ "$mode" = all ]; then
  tools/bench/gdext/build.sh || echo "native build failed: the core bench will report not measured"
  "$GODOT" --headless --fixed-fps 120 --path project -s ../tools/bench/wheel_core_bench.gd
fi
