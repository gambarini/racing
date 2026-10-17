#!/usr/bin/env bash
# Builds the #17 spike GDExtension with clang++ only (no godot-cpp, no scons) into
# project/bench_native/ (git-ignored by a local .gitignore). Needs: clang++ (or $CXX), python3
# and the Godot binary (to dump gdextension_interface.h and the resize method hash).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
OUT="$ROOT/project/bench_native"
mkdir -p "$OUT"
printf '*\n' > "$OUT/.gitignore"
WORK="$(mktemp -d)"
( cd "$WORK" && "$GODOT" --headless --dump-gdextension-interface --dump-extension-api >/dev/null 2>&1 )
HASH="$(python3 - "$WORK/extension_api.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
c=[c for c in d['builtin_classes'] if c['name']=='PackedFloat64Array'][0]
print([m['hash'] for m in c['methods'] if m['name']=='resize'][0])
PY
)"
case "$(uname -s)" in
  Darwin) EXT=dylib; FLAGS="-dynamiclib" ;;
  *) EXT=so; FLAGS="-shared" ;;
esac
${CXX:-clang++} -std=c++17 -O2 -fPIC -ffp-contract=off $FLAGS -DRESIZE_HASH="${HASH}" -I"$WORK" \
  "$HERE/wheel_core.cpp" -o "$OUT/libwheel_core.$EXT"
cat > "$OUT/wheel_core.gdextension" <<EOT
[configuration]
entry_symbol = "wheel_core_init"
compatibility_minimum = "4.2"

[libraries]
macos.debug = "res://bench_native/libwheel_core.$EXT"
macos.release = "res://bench_native/libwheel_core.$EXT"
linux.debug.x86_64 = "res://bench_native/libwheel_core.$EXT"
linux.release.x86_64 = "res://bench_native/libwheel_core.$EXT"
EOT
rm -rf "$WORK"
echo "built $OUT/libwheel_core.$EXT"
