## Quarry readability markers (#214, greybox; final art is #35). Visual only: MeshInstance3D /
## MultiMeshInstance3D nodes with no physics bodies, shared meshes and materials, one MultiMesh
## per kind so the draw-call cost stays constant:
##   EdgeLines  - continuous white strips just inside both road edges (main route + joker detour)
##   EdgePosts  - posts every POST_STEP m outside both edges (main: left white / right red; joker: magenta)
##   CornerMarkers - yellow chevron boards CORNER_BEFORE m before the turn-in of every corner with
##                radius < CORNER_RADIUS, on the outside of the bend, facing the approach
##   StartFinish - chequered gantry + chequered line at s = 0; the joker split keeps the tall magenta
##                gantry added by Quarry (JokerEntry / JokerRejoin).
class_name QuarryMarkers
extends Node3D

const POST_STEP := 10.0 ## m between edge posts along a route
const LINE_STEP := 4.0 ## m between edge line strip centres
const POST_OFFSET := 0.8 ## m outside the road edge
const LINE_INSET := 0.4 ## m inside the road edge
const CORNER_RADIUS := 100.0 ## corners tighter than this get a warning board (acceptance floor: 60 m)
const CORNER_BEFORE := 60.0 ## board distance before the turn-in (acceptance window 40-80 m)
const CORNER_SIDE := 3.0 ## m beyond the road edge, on the outside of the bend
const CURV_SPAN := 4 ## centre-line points either side used for the curvature estimate (1.5 m apart)
const JOKER_COLOR := Color(0.85, 0.1, 0.95)
const LINE_COLOR := Color(1, 1, 1)
const POST_LEFT := Color(1, 1, 1)
const POST_RIGHT := Color(0.9, 0.1, 0.1)
const BOARD_COLOR := Color(1.0, 0.82, 0.0)
const CHEVRON_COLOR := Color(0.05, 0.05, 0.05)

var corners: Array[Dictionary] = [] ## {s_in, s_out, r_min, turn (+1 right / -1 left), s_marker, position, forward}
var post_counts := {} ## route name -> posts per side


func build(q: Quarry) -> void:
	name = "Markers"
	q.add_child(self)
	var main_pts := _walk(q, &"main", POST_STEP)
	var main_lines := _walk(q, &"main", LINE_STEP)
	var joker_pts := _walk(q, &"joker", POST_STEP)
	var joker_lines := _walk(q, &"joker", LINE_STEP)
	_posts(q, &"EdgePostsMain", main_pts, POST_LEFT, POST_RIGHT, q.terrain)
	_posts(q, &"EdgePostsJoker", joker_pts, JOKER_COLOR, JOKER_COLOR, q.terrain)
	_lines(q, &"EdgeLinesMain", main_lines, LINE_STEP, q.terrain)
	_lines(q, &"EdgeLinesJoker", joker_lines, LINE_STEP, q.terrain)
	post_counts = {&"main": main_pts.size(), &"joker": joker_pts.size()}
	corners = find_corners(q)
	_corner_boards(q)
	_start_finish(q)


## Samples along a route every `step` m: {p: Vector2, f: Vector2 (forward), s: float, hw: float}.
## Main: closed lap by main-line s. Joker: the detour polyline (s = distance along the detour).
static func _walk(q: Quarry, route: StringName, step: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var xz: PackedVector2Array = q._xz if route == &"main" else q.joker_xz
	var ss: PackedFloat32Array = q._ss if route == &"main" else q.joker_s
	var m := xz.size()
	var next := 0.0
	for i in m:
		if ss[i] + 1e-4 < next:
			continue
		var t := xz[(i + 1) % m] - xz[(i + m - 1) % m] if route == &"main" else xz[mini(i + 1, m - 1)] - xz[maxi(i - 1, 0)]
		var f := t.normalized()
		var hw := q.road_half(ss[i]) if route == &"main" else Quarry.JOKER_HALF
		out.append({"p": xz[i], "f": f, "s": ss[i], "hw": hw})
		next = ss[i] + step
	if route == &"joker": # always end on the rejoin so both ends of the detour are marked
		var last := m - 1
		if out.is_empty() or float(out[-1]["s"]) < ss[last] - 0.5:
			var t := xz[last] - xz[last - 1]
			out.append({"p": xz[last], "f": t.normalized(), "s": ss[last], "hw": Quarry.JOKER_HALF})
	return out


static func _unshaded(col := Color(1, 1, 1), vertex := false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = vertex
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _mm(node_name: StringName, mesh: Mesh, count: int, colours: bool) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colours
	mm.mesh = mesh
	mm.instance_count = count
	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mm


func _posts(_q: Quarry, node_name: StringName, pts: Array[Dictionary], left_col: Color, right_col: Color, terrain: HeightmapTerrain) -> void:
	var box := BoxMesh.new()
	box.size = Vector3(0.3, 1.2, 0.3)
	box.material = _unshaded(Color(1, 1, 1), true)
	var mm := _mm(node_name, box, pts.size() * 2, true)
	var k := 0
	for e in pts:
		var f: Vector2 = e["f"]
		var right := Vector2(-f.y, f.x)
		for side in [-1.0, 1.0]:
			var p: Vector2 = e["p"] + right * side * (float(e["hw"]) + POST_OFFSET)
			var y := terrain.height_at(p.x, p.y)
			mm.set_instance_transform(k, Transform3D(Basis.looking_at(Vector3(f.x, 0, f.y), Vector3.UP), Vector3(p.x, y + 0.6, p.y)))
			mm.set_instance_color(k, left_col if side < 0.0 else right_col)
			k += 1


func _lines(_q: Quarry, node_name: StringName, pts: Array[Dictionary], step: float, terrain: HeightmapTerrain) -> void:
	var box := BoxMesh.new()
	box.size = Vector3(0.3, 0.04, step + 0.2)
	box.material = _unshaded(LINE_COLOR)
	var mm := _mm(node_name, box, pts.size() * 2, false)
	var k := 0
	for e in pts:
		var f: Vector2 = e["f"]
		var right := Vector2(-f.y, f.x)
		for side in [-1.0, 1.0]:
			var p: Vector2 = e["p"] + right * side * (float(e["hw"]) - LINE_INSET)
			var y := terrain.height_at(p.x, p.y)
			mm.set_instance_transform(k, Transform3D(Basis.looking_at(Vector3(f.x, 0, f.y), Vector3.UP), Vector3(p.x, y + 0.08, p.y)))
			k += 1


## Corners of the main centre line with radius < CORNER_RADIUS: runs of tight curvature, merged when
## less than 20 m apart. Radius from the circle through points CURV_SPAN * 1.5 m either side.
static func find_corners(q: Quarry) -> Array[Dictionary]:
	var xz := q._xz
	var ss := q._ss
	var m := xz.size()
	var out: Array[Dictionary] = []
	var tight := PackedByteArray()
	var turn := PackedFloat32Array()
	var rad := PackedFloat32Array()
	tight.resize(m)
	turn.resize(m)
	rad.resize(m)
	for i in m:
		var a := xz[(i + m - CURV_SPAN) % m]
		var b := xz[i]
		var c := xz[(i + CURV_SPAN) % m]
		var ab := b - a
		var bc := c - b
		var cr := ab.x * bc.y - ab.y * bc.x # >0 = clockwise on screen in x/z = right turn
		var r := (ab.length() * bc.length() * (c - a).length()) / (2.0 * absf(cr)) if absf(cr) > 1e-6 else 1e9
		rad[i] = r
		turn[i] = signf(cr)
		tight[i] = 1 if r < CORNER_RADIUS else 0
	# Start the scan at a straight point so a corner is never split by the array seam.
	var start := 0
	while start < m and tight[start] == 1:
		start += 1
	var i := 0
	var cur := {}
	while i < m:
		var k := (start + i) % m
		if tight[k] == 1:
			if cur.is_empty() or (ss[k] - float(cur["s_out"]) + (q.track_length if ss[k] < float(cur["s_out"]) else 0.0)) > 20.0:
				if not cur.is_empty():
					out.append(cur)
				cur = {"s_in": ss[k], "s_out": ss[k], "r_min": rad[k], "turn": int(turn[k]), "i_in": k}
			cur["s_out"] = ss[k]
			cur["r_min"] = minf(float(cur["r_min"]), rad[k])
		i += 1
	if not cur.is_empty():
		out.append(cur)
	for c in out:
		var s_mark := fposmod(float(c["s_in"]) - CORNER_BEFORE, q.track_length)
		var j := q._index_at(s_mark) % m
		var f := (xz[(j + 1) % m] - xz[(j + m - 1) % m]).normalized()
		var right := Vector2(-f.y, f.x)
		var outside := -float(c["turn"]) # right turn -> outside is on the left (-1 along `right`)
		var p := xz[j] + right * outside * (q.road_half(ss[j]) + CORNER_SIDE)
		c["s_marker"] = ss[j]
		c["position"] = Vector3(p.x, 0.0, p.y)
		c["forward"] = Vector3(f.x, 0.0, f.y)
	return out


static func _chevron_mesh(dir: float) -> ArrayMesh:
	# Two bars forming a ">" (dir +1, points to local +X) or "<" (dir -1), in the board plane (XY).
	var v := PackedVector3Array()
	var idx := PackedInt32Array()
	var w := 0.35
	var pts := [[Vector2(-0.6, -0.8), Vector2(0.6, 0.0)], [Vector2(0.6, 0.0), Vector2(-0.6, 0.8)]]
	for seg in pts:
		var a: Vector2 = seg[0]
		var b: Vector2 = seg[1]
		a.x *= dir
		b.x *= dir
		var n := (b - a).normalized()
		var o := Vector2(-n.y, n.x) * w * 0.5
		var base := v.size()
		for p in [a - o, a + o, b + o, b - o]:
			v.append(Vector3(p.x, p.y, 0.0))
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _unshaded(CHEVRON_COLOR))
	return mesh


## Marker boards: a yellow 3 x 2.4 m board on a post with a black chevron pointing into the bend,
## facing the approach (local +Z = back toward the driver).
func _corner_boards(q: Quarry) -> void:
	var board := BoxMesh.new()
	board.size = Vector3(3.2, 2.6, 0.12)
	board.material = _unshaded(BOARD_COLOR)
	var post := BoxMesh.new()
	post.size = Vector3(0.2, 1.4, 0.2)
	post.material = _unshaded(Color(0.25, 0.25, 0.25))
	var n := corners.size()
	var mm_b := _mm(&"CornerBoards", board, n, false)
	var mm_p := _mm(&"CornerPosts", post, n, false)
	var lefts: Array[Transform3D] = []
	var rights: Array[Transform3D] = []
	for k in n:
		var c := corners[k]
		var pos: Vector3 = c["position"]
		pos.y = q.terrain.height_at(pos.x, pos.z)
		var basis := Basis.looking_at(c["forward"], Vector3.UP)
		mm_p.set_instance_transform(k, Transform3D(basis, pos + Vector3(0, 0.7, 0)))
		var tb := Transform3D(basis, pos + Vector3(0, 2.7, 0))
		mm_b.set_instance_transform(k, tb)
		var face := Transform3D(basis, tb.origin + basis.z * 0.1)
		(rights if int(c["turn"]) > 0 else lefts).append(face)
		c["board_transform"] = tb
		c["position"] = pos
	for pair in [[&"ChevronsRight", 1.0, rights], [&"ChevronsLeft", -1.0, lefts]]:
		var list: Array[Transform3D] = pair[2]
		var mm := _mm(pair[0], _chevron_mesh(pair[1]), list.size(), false)
		for k in list.size():
			mm.set_instance_transform(k, list[k])


## Start/finish: chequered gantry across the road and a chequered line on it at s = 0.
func _start_finish(q: Quarry) -> void:
	var xz := q._xz[0]
	var f := (q._xz[1] - q._xz[q._xz.size() - 1]).normalized()
	var hw := q.road_half(0.0)
	var root := Marker3D.new()
	root.name = "StartFinish"
	var y := q.terrain.height_at(xz.x, xz.y)
	root.position = Vector3(xz.x, y, xz.y)
	root.basis = Basis.looking_at(Vector3(f.x, 0.0, f.y), Vector3.UP)
	add_child(root)
	var tex := _checker_texture(16, 2)
	var checker := _unshaded()
	checker.albedo_texture = tex
	checker.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var dark := _unshaded(Color(0.08, 0.08, 0.08))
	var half := hw + 2.0
	for side in [-1.0, 1.0]:
		var p := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.7, 7.0, 0.7)
		bm.material = dark
		p.mesh = bm
		p.position = Vector3(side * half, 3.5, 0.0)
		root.add_child(p)
	var banner := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(half * 2.0, 1.6)
	qm.material = checker
	banner.mesh = qm
	banner.position = Vector3(0.0, 6.2, 0.0)
	root.add_child(banner)
	var line := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(hw * 2.0, 2.0)
	pm.material = checker
	line.mesh = pm
	line.position = Vector3(0.0, 0.09, 0.0)
	root.add_child(line)


static func _checker_texture(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		for x in w:
			img.set_pixel(x, y, Color(1, 1, 1) if (x + y) % 2 == 0 else Color(0.05, 0.05, 0.05))
	return ImageTexture.create_from_image(img)
