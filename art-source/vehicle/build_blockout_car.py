"""Generate the M1 blockout car (issue #57).

Run:  blender -b --python art-source/vehicle/build_blockout_car.py
Outputs: art-source/vehicle/blockout_car.blend, project/vehicle/blockout_car/blockout_car.glb
Authored values below are mirrored in project/tests/check_blockout_car.gd - keep in sync.
Blender: nose toward -Y, driver's left is +X. Godot result: nose +Z, left +X.
"""
import math
import os
import sys
import bmesh
import bpy
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "blender"))
from racing_export import export_racing_glb  # noqa: E402

# --- authored real-world values (metres) ---
LENGTH, WIDTH = 4.1, 1.76
LOWER = (0.20, 0.80)              # lower body z range (Blender up)
CABIN = (0.80, 1.50)              # cabin z range
CABIN_W, CABIN_L, CABIN_Y = 1.40, 2.0, 0.25   # cabin width, length, centre offset toward the tail (+Y)
WHEEL_RADIUS = 0.32
WHEEL_WIDTH = 0.22
TRACK_HALF = 0.75                 # wheel hub |x|
WHEELBASE_HALF = 1.25             # wheel hub |y|; front = -Y
COM = (0.0, 0.0625, 0.45)         # Blender; Godot z = -0.0625 (com_from_front 0.525 of 2.5 m)

bpy.ops.wm.read_factory_settings(use_empty=True)
scn = bpy.context.scene
scn.unit_settings.system = 'METRIC'
scn.unit_settings.scale_length = 1.0


def material(name, rgb):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*rgb, 1)
    return m


mat_body = material("blockout_paint", (0.75, 0.08, 0.08))
mat_rubber = material("blockout_rubber", (0.03, 0.03, 0.03))
mat_rim = material("blockout_rim", (0.75, 0.75, 0.78))


def link(obj, parent=None):
    scn.collection.objects.link(obj)
    if parent:
        obj.parent = parent
    return obj


def add_box(bm, x0, x1, y0, y1, z0, z1):
    r = bmesh.ops.create_cube(bm, size=1.0)
    for v in r["verts"]:
        v.co = Vector(((x1 + x0) / 2 + v.co.x * (x1 - x0),
                       (y1 + y0) / 2 + v.co.y * (y1 - y0),
                       (z1 + z0) / 2 + v.co.z * (z1 - z0)))
    return r["verts"]


def empty(name, loc, parent, kind='PLAIN_AXES', size=0.1):
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = kind
    e.empty_display_size = size
    e.location = loc
    return link(e, parent)


root = link(bpy.data.objects.new("Car_blockout", None))
root.empty_display_type = 'ARROWS'
root["wheel_radius"] = WHEEL_RADIUS

# body: lower tub + cabin box
me = bpy.data.meshes.new("body")
bm = bmesh.new()
add_box(bm, -WIDTH / 2, WIDTH / 2, -LENGTH / 2, LENGTH / 2, LOWER[0], LOWER[1])
add_box(bm, -CABIN_W / 2, CABIN_W / 2, CABIN_Y - CABIN_L / 2, CABIN_Y + CABIN_L / 2, CABIN[0], CABIN[1])
bm.to_mesh(me)
hull_src = [v.co.copy() for v in bm.verts]
bm.free()
me.materials.append(mat_body)
body = link(bpy.data.objects.new("body", me), root)

# convex collision hull (collision only, never rendered)
bm = bmesh.new()
for co in hull_src:
    bm.verts.new(co)
bmesh.ops.convex_hull(bm, input=bm.verts)
hme = bpy.data.meshes.new("body-convcolonly")
bm.to_mesh(hme)
assert len(hme.vertices) <= 64
bm.free()
link(bpy.data.objects.new("body-convcolonly", hme), root)

# wheels: origin at hub centre; axle along X; tyre + rim disc + cross bar so spin is visible
for tag, sx, sy in (("FL", 1, -1), ("FR", -1, -1), ("RL", 1, 1), ("RR", -1, 1)):
    pos = (sx * TRACK_HALF, sy * WHEELBASE_HALF, WHEEL_RADIUS)
    me = bpy.data.meshes.new(f"wheel_{tag}")
    me.materials.append(mat_rubber)
    me.materials.append(mat_rim)
    bm = bmesh.new()
    rot = Matrix.Rotation(math.pi / 2, 3, 'Y')
    r = bmesh.ops.create_cone(bm, cap_ends=True, segments=24, radius1=WHEEL_RADIUS,
                              radius2=WHEEL_RADIUS, depth=WHEEL_WIDTH)
    bmesh.ops.rotate(bm, verts=r["verts"], cent=(0, 0, 0), matrix=rot)
    r2 = bmesh.ops.create_cone(bm, cap_ends=True, segments=16, radius1=0.20, radius2=0.20,
                               depth=WHEEL_WIDTH + 0.02)
    bmesh.ops.rotate(bm, verts=r2["verts"], cent=(0, 0, 0), matrix=rot)
    rim_verts = set(r2["verts"])
    # cross bar: thin box on the outer face, rim material
    sign = 1 if sx > 0 else -1
    bar = set(add_box(bm, min(sign * 0.10, sign * 0.125), max(sign * 0.10, sign * 0.125),
                      -0.03, 0.03, -0.30, 0.30))
    for f in bm.faces:
        in_rim = all(v in rim_verts or v in bar for v in f.verts)
        f.material_index = 1 if in_rim else 0
    bm.to_mesh(me)
    bm.free()
    w = bpy.data.objects.new(f"wheel_{tag}", me)
    w.location = pos
    w["wheel_radius"] = WHEEL_RADIUS
    link(w, root)
    empty(f"caliper_{tag}", pos, root, 'CUBE', 0.05)

# markers (Blender coords; -Y is the nose)
markers = {
    "marker_com": COM,
    "marker_cam_bonnet": (0, -1.1, 1.0),
    "marker_cam_bumper": (0, -2.1, 0.45),
    "marker_light_head": (0, -2.05, 0.65),
    "marker_light_brake": (0, 2.05, 0.7),
    "marker_exhaust_L": (0.5, 2.05, 0.3),
    "marker_exhaust_R": (-0.5, 2.05, 0.3),
    "marker_driver": (0.4, 0.1, 0.95),
}
for n, p in markers.items():
    empty(n, p, root)

for o in scn.objects:
    assert tuple(o.scale) == (1, 1, 1) and tuple(o.rotation_euler) == (0, 0, 0), o.name

tris = {o.name: sum(len(p.vertices) - 2 for p in o.data.polygons) for o in scn.objects if o.type == 'MESH'}
assert sum(tris.values()) <= 12000 and all(t <= 2000 for n, t in tris.items() if n.startswith("wheel_")), tris
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "blockout_car.blend"))
export_racing_glb(os.path.join(ROOT, "project", "vehicle", "blockout_car", "blockout_car.glb"))
print("tris:", tris, "total", sum(tris.values()))
print("DONE")
