"""Generate the M0 pipeline-test car (issue #56).

Run:  blender -b --python art-source/test/build_test_car.py
Outputs: art-source/test/test_car.blend, project/test/test_car/test_car.glb
Authored values below are mirrored in project/tests/check_test_car.gd - keep in sync.
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
BODY_SIZE = (1.8, 4.0, 1.3)       # X width, Y length, Z height (Blender)
BODY_BOTTOM = 0.25                # ground clearance
WHEEL_RADIUS = 0.32
WHEEL_WIDTH = 0.22
TRACK_HALF = 0.85                 # wheel hub |x|
WHEELBASE_HALF = 1.3              # wheel hub |y|; front = -Y

bpy.ops.wm.read_factory_settings(use_empty=True)
scn = bpy.context.scene
scn.unit_settings.system = 'METRIC'
scn.unit_settings.scale_length = 1.0

mat = bpy.data.materials.new("test_car_paint")
mat.use_nodes = True
mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.8, 0.1, 0.1, 1)


def link(obj, parent=None):
    scn.collection.objects.link(obj)
    if parent:
        obj.parent = parent
    return obj


def box_mesh(name, size, center):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2])) + Vector(center)
    bm.to_mesh(me)
    bm.free()
    return me


def empty(name, loc, parent, kind='PLAIN_AXES', size=0.1):
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = kind
    e.empty_display_size = size
    e.location = loc
    return link(e, parent)


root = link(bpy.data.objects.new("Car_test", None))
root.empty_display_type = 'ARROWS'
root["wheel_radius"] = WHEEL_RADIUS

centre = (0, 0, BODY_BOTTOM + BODY_SIZE[2] / 2)
body = link(bpy.data.objects.new("body", box_mesh("body", BODY_SIZE, centre)), root)
body.data.materials.append(mat)

# convex collision hull (collision only, never rendered): same extents as the body
hull = link(bpy.data.objects.new("body-convcolonly", box_mesh("body-convcolonly", BODY_SIZE, centre)), root)

# wheels: origin at hub centre; mesh rotated so the axle runs along X
for tag, sx, sy in (("FL", 1, -1), ("FR", -1, -1), ("RL", 1, 1), ("RR", -1, 1)):
    pos = (sx * TRACK_HALF, sy * WHEELBASE_HALF, WHEEL_RADIUS)
    me = bpy.data.meshes.new(f"wheel_{tag}")
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=24, radius1=WHEEL_RADIUS,
                          radius2=WHEEL_RADIUS, depth=WHEEL_WIDTH)
    bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.pi / 2, 3, 'Y'))
    bm.to_mesh(me)
    bm.free()
    w = bpy.data.objects.new(f"wheel_{tag}", me)
    w.location = pos
    w["wheel_radius"] = WHEEL_RADIUS
    link(w, root)
    empty(f"caliper_{tag}", pos, root, 'CUBE', 0.05)

# markers (Blender coords; -Y is the nose)
markers = {
    "marker_com": (0, 0, 0.45),
    "marker_cam_bonnet": (0, -0.9, 1.2),
    "marker_cam_bumper": (0, -2.0, 0.5),
    "marker_cam_cockpit": (0.35, 0.1, 1.15),
    "marker_exhaust_L": (0.5, 2.0, 0.35),
    "marker_exhaust_R": (-0.5, 2.0, 0.35),
    "marker_light_head": (0, -2.0, 0.7),     # front reference
    "marker_light_brake": (0, 2.0, 0.8),     # rear reference
    "marker_driver": (0.4, 0.1, 0.8),
}
for n, p in markers.items():
    empty(n, p, root)

for o in scn.objects:
    assert tuple(o.scale) == (1, 1, 1) and tuple(o.rotation_euler) == (0, 0, 0), o.name

bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "test_car.blend"))
export_racing_glb(os.path.join(ROOT, "project", "test", "test_car", "test_car.glb"))
print("tris:", sum(len(o.data.loop_triangles) if False else sum(len(p.vertices) - 2 for p in o.data.polygons)
                   for o in scn.objects if o.type == 'MESH'))
print("DONE")
