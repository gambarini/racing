#!/usr/bin/env bash
# Self-test for run_ci.sh's error gate (#72): FreeType font noise is ignored, real errors still fail.
# Uses a fake "godot" so no engine is needed. Usage: tools/ci/test_error_filter.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# run_ci.sh derives ROOT from its own path, so copy it next to a fake project.
mkdir -p "$T/tools/ci" "$T/project/tests"
cp "$ROOT/tools/ci/run_ci.sh" "$T/tools/ci/"
fake() { printf '#!/usr/bin/env bash\necho "%s"\nexit 0\n' "$1" > "$T/godot"; chmod +x "$T/godot"; }
run() { GODOT="$T/godot" bash "$T/tools/ci/run_ci.sh" "$T/logs" >/dev/null 2>&1; }
fail=0
fake "ERROR: FreeType: Error loading font: x"
if run; then echo "ok: font noise ignored"; else echo "FAIL: font noise gated"; fail=1; fi
fake "ERROR: Failed to load resource res://broken.tres"
if run; then echo "FAIL: real error ignored"; fail=1; else echo "ok: real error fails"; fi
fake "SCRIPT ERROR: Parse Error: x"
if run; then echo "FAIL: script error ignored"; fail=1; else echo "ok: script error fails"; fi
exit $fail
