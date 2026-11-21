## Quarry readability (#214): road/verge/off-road colour separation from the colours the Quarry
## bakes into the terrain, edge markers (<= 12 m apart on both sides of every road segment), corner
## warning boards (R < 60 m corners matched 40-80 m before turn-in, outside, facing the approach),
## distinct start/finish and joker-split visuals at the expected stations, visual-only nodes and a
## small node/draw budget for the markers. The geometry is read back from the built scene.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/quarry_readability_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const MAX_SPACING := 12.0

var cu := CheckUtil.new()
var q: Quarry


func _initialize() -> void:
	_main()


## WCAG-style contrast ratio of two colours' relative luminances: (Lmax + 0.05) / (Lmin + 0.05).
static func _ratio(a: Color, b: Color) -> float:
	var la := _lum(a)
	var lb := _lum(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


static func _lum(c: Color) -> float:
	var l := c.srgb_to_linear()
	return 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b


func _main() -> void:
	await physics_frame
	q = (load("res://tracks/quarry/quarry.tscn") as PackedScene).instantiate()
	root.add_child(q)
	await physics_frame
	_colours()
	_edges()
	_corners()
	_stations()
	_budget()
	cu.finish(self)


func _colours() -> void:
	var grass: Color = Quarry.SURFACE_COLORS[&"grass"]
	var worst := 1e9
	for id: StringName in Quarry.SURFACE_COLORS:
		if id == &"grass":
			continue
		var c: Color = Quarry.SURFACE_COLORS[id]
		var ratio := _ratio(c, grass)
		worst = minf(worst, ratio)
		var achromatic := c.s < 0.15 and grass.s > 0.4
		var dh := absf(c.h - grass.h)
		dh = minf(dh, 1.0 - dh)
		cu.check(achromatic or dh >= 0.08, "%s hue differs from the verge (dh %.2f, s %.2f)" % [id, dh, c.s])
	cu.check_range("worst road surface vs verge luminance ratio", worst, 1.5, 1e6)
	var off := Quarry.OFFROAD_COLOR
	cu.check(_ratio(off, grass) >= 1.5 or absf(off.h - grass.h) >= 0.08, "off-road colour differs from the verge")
	# Baked terrain vertex colours: road centre vs the verge 3 m beyond the edge, along the lap.
	var t := q.terrain
	cu.check(t.vertex_colors.size() == t.n * t.n, "terrain carries per-vertex colours")
	var mat := (t.get_node("Chunk_0_0") as MeshInstance3D).mesh.surface_get_material(0) as StandardMaterial3D
	cu.check(mat.vertex_color_use_as_albedo, "terrain material uses vertex colours as albedo")
	var rmin := 1e9
	var len := q.track.length()
	for i in int(len / 10.0):
		var smp := q.track.sample(i * 10.0)
		var p: Vector3 = smp["position"]
		var right: Vector3 = (smp["forward"] as Vector3).cross(Vector3.UP)
		var hw := q.road_half(i * 10.0)
		var roadc := _vcol_at(p.x, p.z)
		if not _is_pure(roadc): # surface zone changes blend over ~12 m, mid-blend colours are not a surface albedo
			continue
		for side in [-1.0, 1.0]:
			var v: Vector3 = p + right * side * (hw + 3.0)
			if _near_joker(v):
				continue
			var vc := _vcol_at(v.x, v.z)
			var rr := _ratio(roadc, vc)
			if rr < 1.5:
				print("INFO: low ratio %.2f at s %.0f side %d road %s verge %s" % [rr, i * 10.0, side, roadc, vc])
			rmin = minf(rmin, rr)
	cu.check_range("baked road vs verge luminance ratio, worst of lap", rmin, 1.5, 1e6)


func _is_pure(c: Color) -> bool:
	for id: StringName in Quarry.SURFACE_COLORS:
		var s: Color = Quarry.SURFACE_COLORS[id]
		if absf(c.r - s.r) + absf(c.g - s.g) + absf(c.b - s.b) < 0.05:
			return true
	return false


func _vcol_at(x: float, z: float) -> Color:
	var t := q.terrain
	var ix := clampi(int(round((x - t.origin.x) / t.cell)), 0, t.n - 1)
	var iz := clampi(int(round((z - t.origin.y) / t.cell)), 0, t.n - 1)
	return t.vertex_colors[iz * t.n + ix]


## True when a point is within the joker road + verge (the detour lies 15 m outside the main road).
func _near_joker(v: Vector3) -> bool:
	for k in range(0, q.joker_xz.size(), 3):
		if Vector2(v.x, v.z).distance_to(q.joker_xz[k]) < Quarry.JOKER_HALF + 4.0:
			return true
	return false


func _mm(node_name: String) -> MultiMesh:
	return (q.markers.get_node(node_name) as MultiMeshInstance3D).multimesh


## Transform k of a marker MultiMesh. The headless RenderingServer is a dummy and returns identity from
## MultiMesh.get_instance_transform, so read the copy QuarryMarkers recorded when it wrote the instance.
func _xf(node_name: String, k: int) -> Transform3D:
	return (q.markers.xforms[node_name] as Array[Transform3D])[k]


## True when p (x, z) is on the road of the main route or the joker detour (half-width + margin).
func _on_road(p: Vector2, margin: float) -> bool:
	for i in q._xz.size():
		if p.distance_to(q._xz[i]) < q.road_half(q._ss[i]) + margin:
			return true
	for k in q.joker_xz.size():
		if p.distance_to(q.joker_xz[k]) < Quarry.JOKER_HALF + margin:
			return true
	return false


func _edges() -> void:
	var edge_pts := {} # route -> Array[Vector2] of the real edge (not covered by the other route), every 3 m
	for route in [&"main", &"joker"]:
		var xz: PackedVector2Array = q._xz if route == &"main" else q.joker_xz
		var ss: PackedFloat32Array = q._ss if route == &"main" else q.joker_s
		var pts: Array[Vector2] = []
		var next := 0.0
		for i in xz.size():
			if ss[i] < next:
				continue
			next = ss[i] + 3.0
			var f := (xz[(i + 1) % xz.size()] - xz[maxi(i - 1, 0) if route == &"joker" else (i + xz.size() - 1) % xz.size()]).normalized()
			var hw := q.road_half(ss[i]) if route == &"main" else Quarry.JOKER_HALF
			for side in [-1.0, 1.0]:
				var e: Vector2 = xz[i] + Vector2(-f.y, f.x) * side * hw
				# exposed edge = outside the other route's road (the roads overlap where the detour branches off)
				var other_hit := false
				if route == &"main":
					for k in q.joker_xz.size():
						other_hit = other_hit or e.distance_to(q.joker_xz[k]) < Quarry.JOKER_HALF + 4.0
				else:
					for j in q._xz.size():
						other_hit = other_hit or e.distance_to(q._xz[j]) < q.road_half(q._ss[j]) + 4.0
				if not other_hit:
					pts.append(e)
		edge_pts[route] = pts
	var overlap_total := 0
	for route in [&"main", &"joker"]:
		var posts_name := "EdgePostsMain" if route == &"main" else "EdgePostsJoker"
		var posts: Array[Transform3D] = q.markers.xforms[posts_name]
		var worst := 0.0
		var uncovered := 0
		for e: Vector2 in edge_pts[route]:
			var best := 1e9
			for xf in posts:
				best = minf(best, e.distance_to(Vector2(xf.origin.x, xf.origin.z)))
			worst = maxf(worst, best)
			if best > MAX_SPACING / 2.0 + 1.0: # a post within 12 m means every point is within ~7 m of one
				uncovered += 1
		print("INFO: %s: %d posts, exposed edge points %d, farthest edge point from a post %.1f m" % [route, posts.size(), (edge_pts[route] as Array).size(), worst])
		cu.check(uncovered == 0, "%s road: every exposed edge point (left and right) is within %.1f m of a post (%d uncovered)" % [route, MAX_SPACING / 2.0 + 1.0, uncovered])
		cu.check(posts.size() >= (edge_pts[route] as Array).size() / 4, "%s road: post count %d is at least one per 12 m per side" % [route, posts.size()])
		# consecutive posts of the same side along the route never more than 12 m apart (gaps across the
		# overlap with the other route are the only allowed exceptions)
		var sides: Array = q.markers.edge_sides[posts_name]
		var big_gaps := 0
		for side in [-1.0, 1.0]:
			var prev := Vector3.INF
			for k in posts.size():
				if float(sides[k]) != side:
					continue
				var o := posts[k].origin
				if prev != Vector3.INF and prev.distance_to(o) > MAX_SPACING:
					# allowed only when the segment between them is covered by the other route's road
					var mid := Vector2((prev.x + o.x) * 0.5, (prev.z + o.z) * 0.5)
					if not _on_road(mid, 0.5) and not _on_road(Vector2(prev.x, prev.z).lerp(Vector2(o.x, o.z), 0.25), 0.5):
						big_gaps += 1
						printerr("gap %.1f m after post at %s" % [prev.distance_to(o), prev])
				prev = o
		cu.check(big_gaps == 0, "%s posts: no gap > 12 m on an exposed edge (%d)" % [route, big_gaps])
	# Line strips: the same coverage on the exposed main edge, every <= LINE_STEP + 2 m.
	var lines: Array[Transform3D] = q.markers.xforms["EdgeLinesMain"]
	var line_gap := 0.0
	for e: Vector2 in edge_pts[&"main"]:
		var best := 1e9
		for xf in lines:
			best = minf(best, e.distance_to(Vector2(xf.origin.x, xf.origin.z)))
		line_gap = maxf(line_gap, best)
	cu.check_range("main edge line: farthest exposed edge point from a strip centre (m)", line_gap, 0.0, 6.0)
	# No marker stands on a drivable surface; edge lines are not inside the other route's road.
	var on_road := 0
	for node_name in ["EdgePostsMain", "EdgePostsJoker"]:
		for xf: Transform3D in q.markers.xforms[node_name]:
			if _on_road(Vector2(xf.origin.x, xf.origin.z), 0.2):
				on_road += 1
	for xf: Transform3D in q.markers.xforms["CornerBoards"]:
		if _on_road(Vector2(xf.origin.x, xf.origin.z), 0.2):
			on_road += 1
	cu.check(on_road == 0, "no post or board stands on a road (%d on a road)" % on_road)
	var line_on_other := 0
	for xf: Transform3D in q.markers.xforms["EdgeLinesMain"]:
		var p := Vector2(xf.origin.x, xf.origin.z)
		for k in q.joker_xz.size():
			if p.distance_to(q.joker_xz[k]) < Quarry.JOKER_HALF:
				line_on_other += 1
				break
	for xf: Transform3D in q.markers.xforms["EdgeLinesJoker"]:
		var p := Vector2(xf.origin.x, xf.origin.z)
		for j in q._xz.size():
			if p.distance_to(q._xz[j]) < q.road_half(q._ss[j]):
				line_on_other += 1
				break
	cu.check(line_on_other == 0, "no edge line lies inside the other route's road (%d)" % line_on_other)
	# Sides: main posts alternate sides by recorded side; left of travel is -1.
	var sides_main: Array = q.markers.edge_sides["EdgePostsMain"]
	cu.check(sides_main.count(-1.0) > 100 and sides_main.count(1.0) > 100, "main posts on both sides (%d left, %d right)" % [sides_main.count(-1.0), sides_main.count(1.0)])
	# Own-side placement of main posts: within 0.3..1.5 m outside the edge, on the recorded side.
	var bad := 0
	var posts_main: Array[Transform3D] = q.markers.xforms["EdgePostsMain"]
	for k in posts_main.size():
		var o := posts_main[k].origin
		var best := 1e9
		var lat := 0.0
		var bs := 0.0
		for i in range(0, q._xz.size(), 2):
			var d := Vector2(o.x, o.z).distance_to(q._xz[i])
			if d < best:
				best = d
				bs = q._ss[i]
				var f := (q._xz[(i + 1) % q._xz.size()] - q._xz[i]).normalized()
				lat = (Vector2(o.x, o.z) - q._xz[i]).dot(Vector2(-f.y, f.x))
		var out := absf(lat) - q.road_half(bs)
		if lat * float(sides_main[k]) <= 0.0 or out < 0.3 or out > 1.5:
			bad += 1
	cu.check(bad == 0, "every main-route post is on its own side 0.3-1.5 m outside the edge (%d off)" % bad)


## Independent corner finder over the TrackSpline: radius from the circle through s-6, s, s+6.
func _radius_at(s: float) -> float:
	var len := q.track.length()
	var a: Vector3 = q.track.sample(fposmod(s - 6.0, len))["position"]
	var b: Vector3 = q.track.sample(fposmod(s, len))["position"]
	var c: Vector3 = q.track.sample(fposmod(s + 6.0, len))["position"]
	var ab := Vector2(b.x - a.x, b.z - a.z)
	var bc := Vector2(c.x - b.x, c.z - b.z)
	var cr := ab.x * bc.y - ab.y * bc.x
	if absf(cr) < 1e-6:
		return 1e9
	return ab.length() * bc.length() * Vector2(c.x - a.x, c.z - a.z).length() / (2.0 * absf(cr))


func _corners() -> void:
	var len := q.track.length()
	var runs: Array[Dictionary] = [] # R < 60 runs: {s_in, turn}
	var in_run := false
	var s := 0.0
	var boards := _mm("CornerBoards")
	while s < len:
		var r := _radius_at(s)
		if r < 60.0 and not in_run:
			var a: Vector3 = q.track.sample(fposmod(s - 6.0, len))["position"]
			var b: Vector3 = q.track.sample(s)["position"]
			var c: Vector3 = q.track.sample(fposmod(s + 6.0, len))["position"]
			var cr := (b.x - a.x) * (c.z - b.z) - (b.z - a.z) * (c.x - b.x)
			runs.append({"s_in": s, "turn": signf(cr)})
			in_run = true
		elif r >= 60.0:
			in_run = false
		s += 2.0
	print("INFO: corners with R < 60 m: ", runs.size(), "; corner boards: ", boards.instance_count)
	cu.check(runs.size() >= 2, "Quarry has R < 60 m corners (%d)" % runs.size())
	var board_s: Array[float] = []
	var unfaced := 0
	var wrong_side := 0
	for k in boards.instance_count:
		var xf := _xf("CornerBoards", k)
		var o := xf.origin
		var best := 1e9
		var bs := 0.0
		var f := Vector3.ZERO
		var lat := 0.0
		for i in int(len / 1.0):
			var smp := q.track.sample(float(i))
			var p: Vector3 = smp["position"]
			var d := Vector2(o.x - p.x, o.z - p.z).length()
			if d < best:
				best = d
				bs = float(i)
				f = smp["forward"]
				lat = Vector2(o.x - p.x, o.z - p.z).dot(Vector2(-f.z, f.x))
		board_s.append(bs)
		if xf.basis.z.dot(f) > -0.9:
			unfaced += 1
		var out := absf(lat) - q.road_half(bs)
		var turn := float(q.markers.corners[k]["turn"])
		if lat * turn >= 0.0 or out < 1.0 or out > 8.0: # right turn (+1): board must be on the left (lat < 0)
			wrong_side += 1
	cu.check(unfaced == 0, "every corner board faces the approach (%d not)" % unfaced)
	cu.check(wrong_side == 0, "every corner board is outside its bend, 1-8 m off the road edge (%d not)" % wrong_side)
	var unmatched := 0
	for r in runs:
		var ok := false
		for bs in board_s:
			var before := float(r["s_in"]) - bs
			if before >= 40.0 and before <= 80.0:
				ok = true
				print("INFO: corner turn-in s %.0f (turn %+d): board at s %.0f, %.0f m before" % [r["s_in"], int(r["turn"]), bs, before])
		if not ok:
			unmatched += 1
			printerr("unmatched corner at s ", r["s_in"])
	cu.check(unmatched == 0, "every R < 60 m corner has a board 40-80 m before turn-in (%d unmatched)" % unmatched)
	# Boards without a corner (R < 100 m within 40-120 m after the board) are not allowed either.
	var orphan := 0
	for bs in board_s:
		var found := false
		var d := 20.0
		while d <= 130.0:
			if _radius_at(fposmod(bs + d, len)) < 100.0:
				found = true
				break
			d += 2.0
		if not found:
			orphan += 1
	cu.check(orphan == 0, "every board warns of a corner within 130 m (%d orphans)" % orphan)
	# Chevron direction follows the turn: counts per side.
	var rights := 0
	for c in q.markers.corners:
		rights += 1 if int(c["turn"]) > 0 else 0
	cu.check(_mm("ChevronsRight").instance_count == rights and _mm("ChevronsLeft").instance_count == q.markers.corners.size() - rights, "chevron counts match turn directions")


func _nearest_s(p: Vector3, around: float, span: float) -> float:
	var len := q.track.length()
	var best := 1e9
	var bs := 0.0
	var s := around - span
	while s <= around + span:
		var d := Vector2(p.x, p.z).distance_to(Vector2((q.track.sample(fposmod(s, len))["position"] as Vector3).x, (q.track.sample(fposmod(s, len))["position"] as Vector3).z))
		if d < best:
			best = d
			bs = s
		s += 0.5
	return bs


func _stations() -> void:
	var sf := q.markers.get_node("StartFinish") as Node3D
	var s0 := _nearest_s(sf.global_position, 0.0, 20.0)
	cu.check_range("start/finish station offset from gate 0 (m)", absf(s0 - q.track.gate_offsets[0]), 0.0, 1.0)
	var entry := q.get_node("JokerEntry") as Node3D
	var rejoin := q.get_node("JokerRejoin") as Node3D
	var se := _nearest_s(entry.global_position, Quarry.JOKER_A, 20.0)
	var sr := _nearest_s(rejoin.global_position, Quarry.JOKER_B, 20.0)
	cu.check_range("joker entry station offset from JOKER_A (m)", absf(se - Quarry.JOKER_A), 0.0, 3.0)
	cu.check_range("joker rejoin station offset from JOKER_B (m)", absf(sr - Quarry.JOKER_B), 0.0, 3.0)
	# Distinct visuals: start/finish is chequered (textured, tall), the joker gantry is magenta and taller
	# than the 1.2 m edge posts, and neither colour is used by the edge markers.
	var textured := false
	var top := 0.0
	for ch in sf.get_children():
		var mi := ch as MeshInstance3D
		var m := (mi.mesh as PrimitiveMesh).material as StandardMaterial3D
		textured = textured or (m != null and m.albedo_texture != null)
		top = maxf(top, mi.position.y)
	cu.check(textured, "start/finish has a chequered banner/line")
	cu.check(top >= 5.0, "start/finish gantry is tall (%.1f m)" % top)
	var jcol := ((entry.get_child(0) as MeshInstance3D).mesh as BoxMesh).material as StandardMaterial3D
	cu.check(jcol.albedo_color.is_equal_approx(QuarryMarkers.JOKER_COLOR), "joker gantry uses the joker colour")
	cu.check(not QuarryMarkers.JOKER_COLOR.is_equal_approx(QuarryMarkers.POST_LEFT) and not QuarryMarkers.JOKER_COLOR.is_equal_approx(QuarryMarkers.POST_RIGHT) \
			and not QuarryMarkers.JOKER_COLOR.is_equal_approx(QuarryMarkers.LINE_COLOR), "joker colour differs from main edge markers")
	var jh := ((entry.get_child(0) as MeshInstance3D).mesh as BoxMesh).size.y
	cu.check(jh >= 5.0, "joker gantry is tall (%.1f m)" % jh)


func _budget() -> void:
	var nodes := 0
	var bodies := 0
	var stack: Array[Node] = [q.markers]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		nodes += 1
		if n is CollisionObject3D or n is CollisionShape3D:
			bodies += 1
		stack.append_array(n.get_children())
	cu.check(bodies == 0, "marker nodes have no collision objects (visual only)")
	var instances := 0
	for ch in q.markers.get_children():
		if ch is MultiMeshInstance3D:
			instances += (ch as MultiMeshInstance3D).multimesh.instance_count
	print("INFO: marker nodes %d, multimesh instances %d" % [nodes, instances])
	cu.check_range("marker node count", nodes, 0, 24)
	cu.check_range("marker multimesh instances", instances, 0, 1500)
