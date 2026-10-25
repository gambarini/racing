#!/usr/bin/env bash
# Windowed per-surface VFX screenshots (#128). Usage: tools/vfx/capture.sh [out_dir]  (default docs/vfx)
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/docs/vfx}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
# The script is copied into the project's tests dir temporarily so res:// paths and class names resolve.
TMP="$ROOT/project/capture_surface_vfx_tmp.gd"
cleanup() { rm -f "$TMP" "$TMP.uid"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP # the EXIT trap then runs on Ctrl-C / kill too (not on kill -9)
rm -f "$TMP" "$TMP.uid" # a copy leaked by an earlier SIGKILL
cp "$ROOT/tools/vfx/capture_surface_vfx.gd" "$TMP"
"$GODOT" --fixed-fps 60 --resolution 1280x720 --path "$ROOT/project" -s res://capture_surface_vfx_tmp.gd -- "$OUT"
