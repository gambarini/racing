#!/usr/bin/env bash
# Windowed per-surface VFX screenshots (#128). Usage: tools/vfx/capture.sh [out_dir]  (default docs/vfx)
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/docs/vfx}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
# The script is copied into the project's tests dir temporarily so res:// paths and class names resolve.
cp "$ROOT/tools/vfx/capture_surface_vfx.gd" "$ROOT/project/capture_surface_vfx_tmp.gd"
trap 'rm -f "$ROOT/project/capture_surface_vfx_tmp.gd" "$ROOT/project/capture_surface_vfx_tmp.gd.uid"' EXIT
"$GODOT" --fixed-fps 60 --resolution 1280x720 --path "$ROOT/project" -s res://capture_surface_vfx_tmp.gd -- "$OUT"
