"""Shared helper: export the open scene with the "Racing glb" preset (headless-safe)."""
import os
import types
import bpy

PRESET = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Racing_glb.py")


def preset_options(path=PRESET):
    """Execute the operator-preset file against a stub operator and return its options dict."""
    class _Op:
        pass
    op = _Op()
    stub = types.SimpleNamespace(context=types.SimpleNamespace(active_operator=op))
    with open(path) as f:
        src = "\n".join(l for l in f.read().splitlines() if l.strip() != "import bpy")
    exec(compile(src, path, "exec"), {"bpy": stub})
    return dict(vars(op))


def export_racing_glb(filepath, **overrides):
    opts = preset_options()
    opts.update(overrides)
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=filepath, **opts)
