## Quarry greybox (#103): ~2.4 km closed loop on a 700 m x 700 m heightmap (2 m cells) in a quarry
## bowl (terrain 12-25 m). Everything is generated deterministically from CONTROL below: the
## centre line (TrackSpline), terrain (road-following cut/fill blended into a bowl with rim),
## and the SurfaceMap (tarmac start/finish straight, dirt, gravel, a mud patch, grass off-road).
## Road is ROAD_HALF * 2 = 13 m wide. #104 adds the joker route (a wide outside detour round the
## left-hand bend at s 782-1013, rejoining at a marked gantry), vertical features (FEATURES: crests
## and compressions on the road profile) and a first corner after the start that is widened to 18 m
## with a loose inside lane, so there are two viable lines (LINES). Props, AI line: out of scope.
class_name Quarry
extends Node3D

const SIZE := 700.0
const CELL := 2.0
const N := 351 ## samples per edge = SIZE / CELL + 1
const ROAD_HALF := 6.5
const FLAT_MARGIN := 2.5 ## terrain is flat across the road out to half-width + this
const FADE_WIDTH := 14.0 ## ...and has fully blended into the natural bowl this much further out
const RASTER_R := 28.0
const START_FLAT_H := 16.0
const FLAT_BEHIND := 80.0 ## flat start zone: s in [-FLAT_BEHIND, FLAT_AHEAD]
const FLAT_AHEAD := 60.0
const H_MIN := 12.0
const H_MAX := 25.0
## Control polygon (x, z), driving direction; start/finish straight runs -Z at x = 620.
const CONTROL: Array[Vector2] = [
	Vector2(620, 560), Vector2(620, 440), Vector2(615, 340), Vector2(582, 266), Vector2(519, 198),
	Vector2(469, 162), Vector2(419, 140), Vector2(348, 116), Vector2(262, 108), Vector2(196, 121),
	Vector2(154, 151), Vector2(142, 191), Vector2(155, 242), Vector2(188, 290), Vector2(235, 337),
	Vector2(261, 369), Vector2(280, 404), Vector2(305, 469), Vector2(316, 546), Vector2(330, 589),
	Vector2(353, 622), Vector2(388, 645), Vector2(442, 660), Vector2(531, 660), Vector2(578, 648),
	Vector2(604, 627), Vector2(616, 600),
]
## Surface zones by distance s along the line (m, wrapped to [-150, L-150)); "b" < 0 means
## L + b. Outside every zone the road is tarmac.
const ZONES := [
	{"id": &"dirt", "a": 380.0, "b": 700.0},
	{"id": &"gravel", "a": 700.0, "b": 1050.0},
	{"id": &"dirt", "a": 1050.0, "b": 1250.0},
	{"id": &"mud", "a": 1250.0, "b": 1280.0},
	{"id": &"dirt", "a": 1280.0, "b": -330.0},
]
const IDS: Array[StringName] = [&"tarmac", &"dirt", &"grass", &"gravel", &"mud"]
## Timing gates by distance along the line (12 gates, 3 sectors). Gates 5 and 6 bracket the joker
## detour so the detour never skips a gate.
const GATE_OFFSETS: Array[float] = [0.0, 140.0, 280.0, 420.0, 560.0, 650.0, 1030.0, 1130.0, 1260.0, 1380.0, 1500.0, 1600.0]

## Joker route (#104): the main line over s in [JOKER_A, JOKER_B] pushed to the outside (right of
## travel, the bend is a left-hander) by JOKER_OUT m, with smooth ramps JOKER_RAMP of the span.
const JOKER_A := 710.0
const JOKER_B := 985.0
const JOKER_OUT := 15.0
const JOKER_RAMP := 0.35
const JOKER_HALF := 5.0 ## joker road is 10 m wide
## Joker surfaces by distance js along the detour (same zone format as ZONES; +-1e9 = open ended).
const JOKER_ZONES := [
	{"id": &"dirt", "a": -1.0e9, "b": 50.0},
	{"id": &"gravel", "a": 50.0, "b": 1.0e9},
]

## Road widening for the first corner after the start (wider for pack racing): +WIDEN_EXTRA m each
## side over s in [WIDEN_A, WIDEN_B] with WIDEN_RAMP m ramps.
const WIDEN_A := 205.0
const WIDEN_B := 315.0
const WIDEN_RAMP := 40.0
const WIDEN_EXTRA := 2.5
## Lane patches on the main line: the strip of lateral distance [d0, d1] on `side` (-1 left,
## +1 right of travel) over s in [a, b] is `id` instead of the zone surface.
const LANES := [
	{"a": 225.0, "b": 305.0, "side": -1.0, "d0": 2.5, "d1": 12.0, "id": &"gravel"},
]
## Scripted lines for the drive test: lateral offsets (m, + = right) as Vector4(s0, s1, lateral,
## ramp) entries; lateral(s) = sum of lateral * rise(s0 - ramp .. s0) * fall(s1 .. s1 + ramp).
## "tarmac" keeps right on the tarmac outside of the left-hand corner; "inside" cuts the apex over
## the loose gravel lane.
const LINES := {
	&"tarmac": [Vector4(205.0, 315.0, 4.0, 40.0)],
	&"inside": [Vector4(205.0, 315.0, -4.5, 40.0)],
}
const DEFAULT_LINE := &"tarmac"
## Vertical road features added to the rolling profile: gaussian bumps at distance s with height h
## (m, negative = dip) and standard deviation w (m). Crest = positive h, compression = dip.
const FEATURES := [
	{"s": 105.0, "h": 0.9, "w": 16.0, "kind": "crest"},
	{"s": 160.0, "h": -1.3, "w": 14.0, "kind": "compression"},
]

var terrain: HeightmapTerrain
var track: TrackSpline
var heights := PackedFloat32Array()
var road_d := PackedFloat32Array() ## per terrain cell: lateral distance to centre line (RASTER_R if far)
var road_s := PackedFloat32Array() ## per terrain cell: distance along its line of the nearest centre point
var road_lat := PackedFloat32Array() ## per terrain cell: signed lateral offset (+ = right of travel)
var road_hw := PackedFloat32Array() ## per terrain cell: road half-width at the nearest centre point
var road_line := PackedByteArray() ## per terrain cell: 0 = main line, 1 = joker detour
var track_length := 0.0
var joker_length := 0.0
var joker_line: Curve3D ## centre line of the detour only (entry to rejoin)
var racing_line: Curve3D ## closed lap curve along LINES[DEFAULT_LINE] (main route)
var joker_xz := PackedVector2Array()
var joker_s := PackedFloat32Array() ## cumulative distance along the detour
var joker_ys := PackedFloat32Array()
var _xz := PackedVector2Array() ## main centre line, ~1.5 m apart
var _ss := PackedFloat32Array() ## main line distance per point
var _ys := PackedFloat32Array() ## main road height per point
var _joker_first := 0 ## index in _xz of the first point replaced by the detour (entry)
var _joker_last := 0 ## index of the last point replaced (rejoin)


func _ready() -> void:
	build()


func build() -> void:
	var xz := _centre_xz(1.5)
	var m := xz.size()
	var ss := PackedFloat32Array()
	ss.resize(m)
	var acc := 0.0
	for i in m:
		ss[i] = acc
		acc += xz[i].distance_to(xz[(i + 1) % m])
	track_length = acc
	var ys := PackedFloat32Array()
	ys.resize(m)
	for i in m:
		ys[i] = road_height(ss[i])
	_xz = xz
	_ss = ss
	_ys = ys
	_build_joker()
	_build_terrain()
	_build_track(xz, ys)
	racing_line = route_curve(&"main", DEFAULT_LINE)
	terrain = HeightmapTerrain.new()
	terrain.name = "Terrain"
	terrain.cell = CELL
	terrain.mesh_step = 1
	terrain.chunk_cells = 100
	terrain.load_from_image(Image.create_from_data(N, N, false, Image.FORMAT_RF, heights.to_byte_array()), Vector2.ZERO)
	terrain.surface_map = _build_surface_map()
	terrain.surface_map.rebuild_cache() # pre-warm: no hitch in the first physics tick (#159)
	add_child(terrain)
	terrain.build_collider()
	terrain.build_visual()


## Road surface height at distance s along the line (flat start zone, rolling elsewhere).
func road_height(s: float) -> float:
	var l := track_length
	var u := 0.0
	if fposmod(s + FLAT_BEHIND, l) > FLAT_BEHIND + FLAT_AHEAD:
		u = minf(fposmod(s - FLAT_AHEAD, l), fposmod(-FLAT_BEHIND - s, l))
	var rolling := 17.0 + 2.8 * sin(TAU * 2.0 * s / l + 0.6) + 1.8 * sin(TAU * 5.0 * s / l)
	var h := lerpf(START_FLAT_H, rolling, smoothstep(0.0, 150.0, u))
	for f in FEATURES:
		var ds: float = absf(fposmod(s - float(f["s"]) + l * 0.5, l) - l * 0.5)
		var w: float = f["w"]
		h += float(f["h"]) * exp(-ds * ds / (2.0 * w * w))
	return h


## Road half-width (m) of the main line at distance s.
func road_half(s: float) -> float:
	var l := track_length
	var sw := fposmod(s + 150.0, l) - 150.0
	var b := smoothstep(WIDEN_A - WIDEN_RAMP, WIDEN_A, sw) * (1.0 - smoothstep(WIDEN_B, WIDEN_B + WIDEN_RAMP, sw))
	return ROAD_HALF + WIDEN_EXTRA * b


## Scripted-line lateral offset (m, + = right of travel) at main distance s.
func line_offset(line: StringName, s: float) -> float:
	var l := track_length
	var sw := fposmod(s + 150.0, l) - 150.0
	var out := 0.0
	for e: Vector4 in LINES.get(line, []):
		out += e.z * smoothstep(e.x - e.w, e.x, sw) * (1.0 - smoothstep(e.y, e.y + e.w, sw))
	return out


## Lap polyline (x, road y, z) at ~1.5 m spacing in driving direction starting at s = 0. route
## &"joker" replaces the detour span by the joker line; `line` picks the lateral offsets (main
## route only, the detour keeps its own centre line).
func route_points(route: StringName, line: StringName) -> PackedVector3Array:
	var out := PackedVector3Array()
	var m := _xz.size()
	var i := 0
	while i < m:
		if route == &"joker" and i == _joker_first:
			for k in joker_xz.size():
				out.append(Vector3(joker_xz[k].x, joker_ys[k] + 0.05, joker_xz[k].y))
			i = _joker_last + 1
			continue
		var t := _xz[(i + 1) % m] - _xz[(i + m - 1) % m]
		var right := Vector2(-t.y, t.x).normalized()
		var p := _xz[i] + right * line_offset(line, _ss[i])
		out.append(Vector3(p.x, _ys[i] + 0.05, p.y))
		i += 1
	return out


func route_curve(route: StringName, line: StringName) -> Curve3D:
	var pts := route_points(route, line)
	var c := Curve3D.new()
	c.bake_interval = 1.0
	for p in pts:
		c.add_point(p)
	c.add_point(pts[0])
	return c


## Peak-mu scale of the surface under each point (blended weights), for speed planning.
func route_mu(pts: PackedVector3Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(pts.size())
	for i in pts.size():
		var w := terrain.surface_at(pts[i].x, pts[i].z)
		out[i] = SurfaceBlend.blend(w).peak_mu_scale if not w.is_empty() else 0.5
	return out


## Main-line index nearest to distance s.
func _index_at(s: float) -> int:
	var lo := 0
	var hi := _ss.size() - 1
	while lo < hi:
		var mid := (lo + hi) >> 1
		if _ss[mid] < s:
			lo = mid + 1
		else:
			hi = mid
	return lo


## Detour polyline: the main points over [JOKER_A, JOKER_B] pushed outward by a smooth bump.
func _build_joker() -> void:
	_joker_first = _index_at(JOKER_A)
	_joker_last = _index_at(JOKER_B)
	joker_xz.clear()
	joker_ys.clear()
	joker_s.clear()
	var m := _xz.size()
	var span := _ss[_joker_last] - _ss[_joker_first]
	for i in range(_joker_first, _joker_last + 1):
		var u := (_ss[i] - _ss[_joker_first]) / span
		var b := smoothstep(0.0, JOKER_RAMP, u) * (1.0 - smoothstep(1.0 - JOKER_RAMP, 1.0, u))
		var t := _xz[mini(i + 1, m - 1)] - _xz[maxi(i - 1, 0)]
		var right := Vector2(-t.y, t.x).normalized()
		joker_xz.append(_xz[i] + right * JOKER_OUT * b)
		joker_ys.append(_ys[i])
	var acc := 0.0
	for k in joker_xz.size():
		joker_s.append(acc)
		if k + 1 < joker_xz.size():
			acc += joker_xz[k].distance_to(joker_xz[k + 1])
	joker_length = acc
	joker_line = Curve3D.new()
	joker_line.bake_interval = 1.0
	for k in joker_xz.size():
		joker_line.add_point(Vector3(joker_xz[k].x, joker_ys[k] + 0.05, joker_xz[k].y))


func natural_height(x: float, z: float) -> float:
	var d := Vector2(x, z).distance_to(Vector2(350, 380))
	return 12.8 + 11.4 * smoothstep(150.0, 330.0, d) + 0.6 * sin(x * 0.031 + z * 0.021) * cos(z * 0.017)


static func _cr(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	return 0.5 * (2.0 * p1 + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t \
		+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * t * t * t)


## Closed Catmull-Rom through CONTROL, points ~step m apart (first point not repeated).
static func _centre_xz(step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var m := CONTROL.size()
	for i in m:
		var p0 := CONTROL[(i + m - 1) % m]
		var p1 := CONTROL[i]
		var p2 := CONTROL[(i + 1) % m]
		var p3 := CONTROL[(i + 2) % m]
		var k := maxi(1, ceili(p1.distance_to(p2) / step))
		for j in k:
			out.append(_cr(p0, p1, p2, p3, float(j) / k))
	return out


func _build_track(xz: PackedVector2Array, ys: PackedFloat32Array) -> void:
	var c := Curve3D.new()
	c.bake_interval = 1.0
	for i in xz.size():
		c.add_point(Vector3(xz[i].x, ys[i] + 0.05, xz[i].y))
	c.add_point(Vector3(xz[0].x, ys[0] + 0.05, xz[0].y))
	track = TrackSpline.new()
	track.name = "TrackSpline"
	track.centre_line = c
	var offs := PackedFloat32Array()
	for g in GATE_OFFSETS:
		offs.append(g)
	track.gate_offsets = offs
	track.sector_end_gates = [4, 8]
	track.gate_half_width = 9.5
	# Joker gate halfway along the detour; the main line is 25 m away from it at that point.
	var mid := joker_xz.size() / 2
	var t := joker_xz[mid + 1] - joker_xz[mid - 1]
	track.has_joker = true
	track.joker_position = Vector3(joker_xz[mid].x, joker_ys[mid] + 0.05, joker_xz[mid].y)
	track.joker_forward = Vector3(t.x, 0.0, t.y).normalized()
	track.joker_half_width = JOKER_HALF + 0.5
	add_child(track)
	_add_marker(&"JokerEntry", joker_xz[0], joker_ys[0], joker_xz[1] - joker_xz[0], JOKER_HALF + 3.0)
	var last := joker_xz.size() - 1
	_add_marker(&"JokerRejoin", joker_xz[last], joker_ys[last], joker_xz[last] - joker_xz[last - 1], JOKER_HALF + 3.0)


## Marker3D at the point plus a greybox gantry (two posts and a bar) across the road.
func _add_marker(marker_name: StringName, xz: Vector2, y: float, dir: Vector2, half: float) -> void:
	var f := dir.normalized()
	var m := Marker3D.new()
	m.name = marker_name
	m.position = Vector3(xz.x, y + 0.05, xz.y)
	m.basis = Basis.looking_at(Vector3(f.x, 0.0, f.y), Vector3.UP)
	add_child(m)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.45, 0.05)
	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.5, 5.0, 0.5)
		box.material = mat
		post.mesh = box
		post.position = Vector3(side * half, 2.5, 0.0)
		m.add_child(post)
	var bar := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(half * 2.0, 0.6, 0.4)
	bm.material = mat
	bar.mesh = bm
	bar.position = Vector3(0.0, 5.0, 0.0)
	m.add_child(bar)


func _raster(xz: PackedVector2Array, ss: PackedFloat32Array, ys: PackedFloat32Array, line: int,
		road_y: PackedFloat32Array) -> void:
	var m := xz.size()
	var closed := line == 0
	var r := int(ceil(RASTER_R / CELL))
	for i in m:
		var p := xz[i]
		var t := xz[(i + 1) % m if closed else mini(i + 1, m - 1)] - xz[(i + m - 1) % m if closed else maxi(i - 1, 0)]
		var right := Vector2(-t.y, t.x).normalized()
		var hw := road_half(ss[i]) if closed else JOKER_HALF
		var cx := int(round(p.x / CELL))
		var cz := int(round(p.y / CELL))
		for iz in range(maxi(cz - r, 0), mini(cz + r, N - 1) + 1):
			for ix in range(maxi(cx - r, 0), mini(cx + r, N - 1) + 1):
				var rel := Vector2(ix * CELL, iz * CELL) - p
				var d := rel.length()
				var k := iz * N + ix
				if d < road_d[k]:
					road_d[k] = d
					road_s[k] = ss[i]
					road_y[k] = ys[i]
					road_lat[k] = rel.dot(right)
					road_hw[k] = hw
					road_line[k] = line


func _build_terrain() -> void:
	var cells := N * N
	road_d.resize(cells)
	road_d.fill(RASTER_R)
	road_s.resize(cells)
	road_lat.resize(cells)
	road_hw.resize(cells)
	road_line.resize(cells)
	var road_y := PackedFloat32Array()
	road_y.resize(cells)
	_raster(_xz, _ss, _ys, 0, road_y)
	_raster(joker_xz, joker_s, joker_ys, 1, road_y)
	heights.resize(cells)
	for iz in N:
		for ix in N:
			var k := iz * N + ix
			var nat := natural_height(ix * CELL, iz * CELL)
			var h := nat
			if road_d[k] < RASTER_R:
				var flat := road_hw[k] + FLAT_MARGIN
				h = lerpf(road_y[k], nat, smoothstep(flat, flat + FADE_WIDTH, road_d[k]))
			heights[k] = clampf(h, H_MIN, H_MAX)


func _zone_weights(zones: Array, sw: float, l: float, road: float, out: Dictionary) -> float:
	var zsum := 0.0
	for z in zones:
		var a: float = z["a"] if z["a"] >= 0.0 else l + z["a"]
		var b: float = z["b"] if z["b"] >= 0.0 else l + z["b"]
		var w := smoothstep(a - 6.0, a + 6.0, sw) * (1.0 - smoothstep(b - 6.0, b + 6.0, sw))
		if w > 0.0:
			out[z["id"]] = out.get(z["id"], 0.0) + w * road
			zsum += w
	return zsum


## Weights {id: w} for a pixel at lateral distance d (signed lat) from the line, s along it.
func _weights(d: float, lat: float, s: float, hw: float, line: int) -> Dictionary:
	var road := 1.0 - smoothstep(hw - 1.0, hw + 1.0, d)
	var out := {&"grass": 1.0 - road}
	if road <= 0.0:
		return out
	if line == 1:
		var zs := _zone_weights(JOKER_ZONES, s, joker_length, road, out)
		out[&"tarmac"] = maxf(1.0 - zs, 0.0) * road
		return out
	var l := track_length
	var sw := fposmod(s + 150.0, l) - 150.0
	var zsum := _zone_weights(ZONES, sw, l, road, out)
	out[&"tarmac"] = maxf(1.0 - zsum, 0.0) * road
	for lane in LANES:
		var inside: float = smoothstep(float(lane["a"]) - 6.0, float(lane["a"]) + 6.0, sw) \
				* (1.0 - smoothstep(float(lane["b"]) - 6.0, float(lane["b"]) + 6.0, sw))
		var dd: float = lat * float(lane["side"])
		var across := smoothstep(float(lane["d0"]) - 0.5, float(lane["d0"]) + 0.5, dd) \
				* (1.0 - smoothstep(float(lane["d1"]) - 0.5, float(lane["d1"]) + 0.5, dd))
		var lw := inside * across
		if lw > 0.0:
			for id in out.keys():
				if id != &"grass":
					out[id] *= 1.0 - lw
			out[lane["id"]] = out.get(lane["id"], 0.0) + lw * road
	return out


func _build_surface_map() -> SurfaceMap:
	var img0 := Image.create(N, N, false, Image.FORMAT_RGBA8)
	var img1 := Image.create(N, N, false, Image.FORMAT_RGBA8)
	for iz in N:
		for ix in N:
			var k := iz * N + ix
			var w := _weights(road_d[k], road_lat[k], road_s[k], road_hw[k], road_line[k])
			img0.set_pixel(ix, iz, Color(w.get(&"tarmac", 0.0), w.get(&"dirt", 0.0), w.get(&"grass", 0.0), w.get(&"gravel", 0.0)))
			img1.set_pixel(ix, iz, Color(w.get(&"mud", 0.0), 0, 0, 0))
	var sm := SurfaceMap.new()
	# Texel centres at (i + 0.5) * size / N + origin = i * CELL, aligned with the height samples.
	sm.origin = Vector2(-CELL * 0.5, -CELL * 0.5)
	sm.size = Vector2(N * CELL, N * CELL)
	sm.ids = IDS
	sm.images = [img0, img1]
	return sm
