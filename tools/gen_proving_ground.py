#!/usr/bin/env python3
"""Generates project/tracks/proving_ground/proving_ground.tscn and docs/proving_ground_overview.svg.
Run: python3 tools/gen_proving_ground.py   (deterministic; commit the outputs)
Axes: +X right, +Z down on the overview, Godot forward is -Z."""
import math, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "project/tracks/proving_ground/proving_ground.tscn")
SVG = os.path.join(ROOT, "docs/proving_ground_overview.svg")

PAD = 400.0
COL = {"tarmac": (0.25, 0.25, 0.27), "tarmac_patch": (0.12, 0.12, 0.14),
       "gravel": (0.62, 0.55, 0.42), "mud": (0.33, 0.22, 0.12),
       "ring": (0.9, 0.9, 0.95), "cone": (1.0, 0.45, 0.05), "landing": (0.2, 0.6, 0.9)}
nodes, svg_items, sub, mats = [], [], [], {}
counter = [0]


def mat(key):
    mats.setdefault(key, f"mat_{key}")
    return mats[key]


def uid(prefix):
    counter[0] += 1
    return f"{prefix}_{counter[0]}"


def vec(size):
    return f"Vector3({size[0]:.4f}, {size[1]:.4f}, {size[2]:.4f})"


def sub_box(name, size):
    sub.append(f'[sub_resource type="BoxShape3D" id="{name}"]\nsize = {vec(size)}\n')


def sub_boxmesh(name, size):
    sub.append(f'[sub_resource type="BoxMesh" id="{name}"]\nsize = {vec(size)}\n')


def tf(pos, rot_y=0.0, rot_z=0.0):
    """Basis = Ry(rot_y) * Rz(rot_z), Godot conventions."""
    cy, sy, cz, sz = math.cos(rot_y), math.sin(rot_y), math.cos(rot_z), math.sin(rot_z)

    def ry(v):
        return (cy * v[0] + sy * v[2], v[1], -sy * v[0] + cy * v[2])
    X, Y, Z = ry((cz, sz, 0)), ry((-sz, cz, 0)), ry((0, 0, 1))
    vals = [X[0], Y[0], Z[0], X[1], Y[1], Z[1], X[2], Y[2], Z[2]] + list(pos)
    return "Transform3D(" + ", ".join(f"{v:.6f}" for v in vals) + ")"


def body(name, parent, size, pos, sid, color, rot_y=0.0, rot_z=0.0):
    s, m = uid("shape"), uid("mesh")
    sub_box(s, size)
    sub_boxmesh(m, size)
    nodes.append(f'[node name="{name}" type="StaticBody3D" parent="{parent}" groups=["surface_{sid}"]]\n'
                 f'transform = {tf(pos, rot_y, rot_z)}\nmetadata/surface_id = "{sid}"\n')
    nodes.append(f'[node name="Collision" type="CollisionShape3D" parent="{parent}/{name}"]\nshape = SubResource("{s}")\n')
    nodes.append(f'[node name="Mesh" type="MeshInstance3D" parent="{parent}/{name}"]\nmesh = SubResource("{m}")\n'
                 f'surface_material_override/0 = SubResource("{mat(color)}")\n')


def node3d(name, parent, pos=(0, 0, 0), meta=None):
    t = f'[node name="{name}" type="Node3D" parent="{parent}"]\n'
    if pos != (0, 0, 0):
        t += f'transform = {tf(pos)}\n'
    for k, v in (meta or {}).items():
        t += f'metadata/{k} = {v}\n'
    nodes.append(t)


def visual(name, parent, size, pos, color, rot_y=0.0, rot_z=0.0):
    m = uid("mesh")
    sub_boxmesh(m, size)
    nodes.append(f'[node name="{name}" type="MeshInstance3D" parent="{parent}"]\n'
                 f'transform = {tf(pos, rot_y, rot_z)}\nmesh = SubResource("{m}")\n'
                 f'surface_material_override/0 = SubResource("{mat(color)}")\n')


def spawn(name, pos, face):
    psi = math.atan2(-face[0], -face[1])  # forward (-Z local) -> face
    nodes.append(f'[node name="{name}" type="Marker3D" parent="." groups=["spawn_point"]]\n'
                 f'transform = {tf((pos[0], 0.4, pos[1]), psi)}\n')
    svg_items.append(("spawn", name, pos, face))


def hexcol(key):
    return "#%02x%02x%02x" % tuple(int(c * 255) for c in COL[key])


# --- root + ground pad (default surface tarmac)
nodes.append('[node name="ProvingGround" type="Node3D"]\nmetadata/pad_size = Vector2(400, 400)\n')
body("Ground", ".", (PAD, 1.0, PAD), (0, -0.5, 0), "tarmac", "tarmac")
svg_items.append(("pad", "Ground (tarmac) 400x400 m"))

# --- surface patches 50x50, top at y=+0.02, axis aligned
PS, TH = 50.0, 0.1
for nm, sid, cx, col in (("Patch_Tarmac", "tarmac", -110, "tarmac_patch"),
                         ("Patch_Gravel", "gravel", -30, "gravel"),
                         ("Patch_Mud", "mud", 50, "mud")):
    body(nm, ".", (PS, TH, PS), (cx, 0.02 - TH / 2, -20), sid, col)
    svg_items.append(("rect", nm, (cx, -20), (PS, PS), hexcol(col)))
spawn("Spawn_Flat", (0, 160), (0, -1))
spawn("Spawn_Gravel", (-30, 25), (0, -1))
spawn("Spawn_Mud", (50, 25), (0, -1))

# --- circle: centreline r=30, width 8, drawn as 64 flat segments on the tarmac pad
CC, R, W, N = (-100, 100), 30.0, 8.0, 64
node3d("Circle", ".", (CC[0], 0, CC[1]),
       {"radius": R, "width": W, "surface_id": '"tarmac"', "segments": N})
seg_len = 2 * R * math.sin(math.pi / N) * 1.04
for i in range(N):
    a = 2 * math.pi * i / N
    visual(f"Seg_{i:02d}", "Circle", (seg_len, 0.02, W),
           (R * math.cos(a), 0.03, R * math.sin(a)), "ring",
           rot_y=math.atan2(-math.cos(a), -math.sin(a)))
svg_items.append(("ring", CC, R, W))
spawn("Spawn_Circle", (CC[0] + R, CC[1]), (0, 1))

# --- slalom: 8 cones, 18 m spacing, +/-3 m alternating, along +X at z=-100
node3d("Slalom", ".", (0, 0, -100), {"spacing": 18.0, "lateral_offset": 3.0, "cone_count": 8})
x0 = -60.0
for i in range(8):
    x, z = x0 + 18 * i, 3.0 * (1 if i % 2 == 0 else -1)
    s, m = uid("cshape"), uid("cmesh")
    sub.append(f'[sub_resource type="CylinderShape3D" id="{s}"]\nradius = 0.25\nheight = 0.7\n')
    sub.append(f'[sub_resource type="CylinderMesh" id="{m}"]\ntop_radius = 0.02\nbottom_radius = 0.25\nheight = 0.7\n')
    nodes.append(f'[node name="Cone_{i+1}" type="StaticBody3D" parent="Slalom"]\ntransform = {tf((x, 0.35, z))}\n')
    nodes.append(f'[node name="Collision" type="CollisionShape3D" parent="Slalom/Cone_{i+1}"]\nshape = SubResource("{s}")\n')
    nodes.append(f'[node name="Mesh" type="MeshInstance3D" parent="Slalom/Cone_{i+1}"]\nmesh = SubResource("{m}")\n'
                 f'surface_material_override/0 = SubResource("{mat("cone")}")\n')
    svg_items.append(("cone", i, (x, -100 + z)))
spawn("Spawn_Slalom", (x0 - 20, -100), (1, 0))

# --- slope: 10.0 deg, 40 m along incline, 10 m wide, 20 m flat run-in (pad), rises +X
TH10 = math.radians(10.0)
L, SW, sx, sz = 40.0, 10.0, 70.0, 100.0
node3d("Slope", ".", (0, 0, 0), {"angle_deg": 10.0, "length": L, "width": SW, "run_in": 20.0})
d = (math.cos(TH10), math.sin(TH10))
n = (-math.sin(TH10), math.cos(TH10))
body("Surface", "Slope", (L, 1.0, SW),
     (sx + d[0] * L / 2 - n[0] * 0.5, d[1] * L / 2 - n[1] * 0.5, sz), "tarmac", "tarmac_patch", rot_z=TH10)
svg_items.append(("rect", "Slope 10 deg", (sx + d[0] * L / 2, sz), (d[0] * L, SW), "#7a4a8a"))
# Marker sits on the ramp surface 10 m (horizontal) past its foot, 0.4 m above it, pitched with the slope (#109).
_m = 10.0
_x, _y = sx + _m + n[0] * 0.4, _m * math.tan(TH10) + n[1] * 0.4
_vals = [0, n[0], -d[0], 0, n[1], -d[1], 1, 0, 0, _x, _y, sz]
nodes.append('[node name="Spawn_Slope" type="Marker3D" parent="." groups=["spawn_point"]]\n'
             'transform = Transform3D(' + ", ".join(f"{v:.6f}" for v in _vals) + ')\n')
svg_items.append(("spawn", "Spawn_Slope", (sx + _m, sz), (1, 0)))

# --- jump: 12 deg ramp rising 1.0 m, 8 m wide, 30 m flat landing, along +Z at x=130
TH12 = math.radians(12.0)
RL, JW, jx, jz0 = 1.0 / math.sin(TH12), 8.0, 130.0, -100.0
node3d("Jump", ".", (0, 0, 0), {"angle_deg": 12.0, "rise": 1.0, "landing_length": 30.0})
d2 = (math.cos(TH12), math.sin(TH12))
n2 = (-math.sin(TH12), math.cos(TH12))
body("Ramp", "Jump", (RL, 1.0, JW),
     (jx, d2[1] * RL / 2 - n2[1] * 0.5, jz0 + d2[0] * RL / 2 - n2[0] * 0.5),
     "tarmac", "tarmac_patch", rot_y=-math.pi / 2, rot_z=TH12)
run = d2[0] * RL
visual("Landing", "Jump", (JW, 0.02, 30.0), (jx, 0.03, jz0 + run + 15.0), "landing")
svg_items.append(("rect", "Jump ramp", (jx, jz0 + run / 2), (JW, run), "#d0a020"))
svg_items.append(("rect", "Jump landing 30 m", (jx, jz0 + run + 15), (JW, 30), "#2a7ab0"))
spawn("Spawn_Jump", (jx, jz0 - 50), (0, 1))

# --- write tscn
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    f.write(f'[gd_scene load_steps={len(sub) + len(mats) + 1} format=3]\n\n')
    for key, mid in mats.items():
        c = COL[key]
        f.write(f'[sub_resource type="StandardMaterial3D" id="{mid}"]\nalbedo_color = Color({c[0]}, {c[1]}, {c[2]}, 1)\n\n')
    f.write("\n".join(sub) + "\n")
    f.write("\n".join(nodes))

# --- overview svg
S, ORG = 2.0, 200


def X(x): return (x + ORG) * S
def Z(z): return (z + ORG) * S


o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{PAD*S:.0f}" height="{PAD*S:.0f}" viewBox="0 0 {PAD*S:.0f} {PAD*S:.0f}" font-family="sans-serif" font-size="12">',
     '<rect width="100%" height="100%" fill="#2b2b30"/>']
for it in svg_items:
    k = it[0]
    if k == "pad":
        o.append(f'<text x="8" y="16" fill="#aaa">{it[1]} (+X right, +Z down)</text>')
    elif k == "rect":
        _, nm, c, sz, fill = it
        o.append(f'<rect x="{X(c[0]-sz[0]/2)}" y="{Z(c[1]-sz[1]/2)}" width="{sz[0]*S}" height="{sz[1]*S}" fill="{fill}" stroke="#fff" stroke-width="0.5"/>')
        o.append(f'<text x="{X(c[0])}" y="{Z(c[1])+4}" fill="#fff" text-anchor="middle">{nm}</text>')
    elif k == "ring":
        _, c, r, w = it
        o.append(f'<circle cx="{X(c[0])}" cy="{Z(c[1])}" r="{r*S}" fill="none" stroke="#e8e8f0" stroke-width="{w*S}" opacity="0.8"/>')
        o.append(f'<text x="{X(c[0])}" y="{Z(c[1])+4}" fill="#fff" text-anchor="middle">Circle r=30 w=8</text>')
    elif k == "cone":
        o.append(f'<circle cx="{X(it[2][0])}" cy="{Z(it[2][1])}" r="4" fill="#ff7300"/>')
        if it[1] == 0:
            o.append(f'<text x="{X(it[2][0])}" y="{Z(it[2][1])-14}" fill="#ff9a40">Slalom (8 cones, 18 m)</text>')
    elif k == "spawn":
        _, nm, p, f_ = it
        o.append(f'<circle cx="{X(p[0])}" cy="{Z(p[1])}" r="5" fill="#33ff33"/>'
                 f'<line x1="{X(p[0])}" y1="{Z(p[1])}" x2="{X(p[0]+f_[0]*12)}" y2="{Z(p[1]+f_[1]*12)}" stroke="#33ff33" stroke-width="2"/>'
                 f'<text x="{X(p[0])+8}" y="{Z(p[1])+4}" fill="#33ff33">{nm}</text>')
o.append('</svg>')
os.makedirs(os.path.dirname(SVG), exist_ok=True)
open(SVG, "w").write("\n".join(o))
print("wrote", OUT, SVG)
