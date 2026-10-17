## Quarry greybox (#103): ~2.4 km closed loop on a 700 m x 700 m heightmap (2 m cells) in a quarry
## bowl (terrain 12-25 m). Everything is generated deterministically from CONTROL below: the
## centre line (TrackSpline), terrain (road-following cut/fill blended into a bowl with rim),
## and the SurfaceMap (tarmac start/finish straight, dirt, gravel, a mud patch, grass off-road).
## Road is ROAD_HALF * 2 = 13 m wide. Joker route, props, AI line: out of scope.
class_name Quarry
extends Node3D

const SIZE := 700.0
const CELL := 2.0
const N := 351 ## samples per edge = SIZE / CELL + 1
const ROAD_HALF := 6.5
const FLAT_HALF := 9.0 ## terrain is flat across the road out to this lateral distance
const FADE_END := 23.0 ## terrain has fully blended into the natural bowl at this distance
const RASTER_R := 24.0
const START_FLAT_H := 16.0
const FLAT_BEHIND := 80.0 ## flat start zone: s in [-FLAT_BEHIND, FLAT_AHEAD]
const FLAT_AHEAD := 60.0
const H_MIN := 12.0
const H_MAX := 25.0
## Control polygon (x, z), driving direction; start/finish straight runs -Z at x = 620.
const CONTROL: Array[Vector2] = [
	Vector2(620, 560), Vector2(620, 440), Vector2(615, 340), Vector2(590, 260), Vector2(540, 200),
	Vector2(470, 175), Vector2(400, 145), Vector2(330, 105), Vector2(250, 95), Vector2(170, 125),
	Vector2(115, 190), Vector2(110, 260), Vector2(150, 320), Vector2(220, 350), Vector2(280, 335),
	Vector2(335, 375), Vector2(340, 445), Vector2(300, 505), Vector2(235, 535), Vector2(185, 600),
	Vector2(230, 660), Vector2(320, 670), Vector2(400, 640), Vector2(470, 595), Vector2(530, 640),
	Vector2(590, 665), Vector2(625, 640),
]
## Surface zones by distance s along the line (m, wrapped to [-150, L-150)); "b" < 0 means
## L + b. Outside every zone the road is tarmac.
const ZONES := [
	{"id": &"dirt", "a": 450.0, "b": 1000.0},
	{"id": &"gravel", "a": 1000.0, "b": 1450.0},
	{"id": &"dirt", "a": 1450.0, "b": 1620.0},
	{"id": &"mud", "a": 1620.0, "b": 1690.0},
	{"id": &"dirt", "a": 1690.0, "b": -250.0},
]
const IDS: Array[StringName] = [&"tarmac", &"dirt", &"grass", &"gravel", &"mud"]

var terrain: HeightmapTerrain
var track: TrackSpline
var heights := PackedFloat32Array()
var road_d := PackedFloat32Array() ## per terrain cell: lateral distance to centre line (RASTER_R if far)
var road_s := PackedFloat32Array() ## per terrain cell: distance along line of the nearest centre point
var track_length := 0.0


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
	_build_terrain(xz, ss, ys)
	_build_track(xz, ys)
	terrain = HeightmapTerrain.new()
	terrain.name = "Terrain"
	terrain.cell = CELL
	terrain.mesh_step = 1
	terrain.chunk_cells = 100
	terrain.load_from_image(Image.create_from_data(N, N, false, Image.FORMAT_RF, heights.to_byte_array()), Vector2.ZERO)
	terrain.surface_map = _build_surface_map()
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
	return lerpf(START_FLAT_H, rolling, smoothstep(0.0, 150.0, u))


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
	var l := c.get_baked_length()
	for i in 12:
		offs.append(l * float(i) / 12.0)
	track.gate_offsets = offs
	track.sector_end_gates = [4, 8]
	track.gate_half_width = 9.0
	add_child(track)


func _build_terrain(xz: PackedVector2Array, ss: PackedFloat32Array, ys: PackedFloat32Array) -> void:
	var cells := N * N
	road_d.resize(cells)
	road_d.fill(RASTER_R)
	road_s.resize(cells)
	var road_y := PackedFloat32Array()
	road_y.resize(cells)
	var r := int(ceil(RASTER_R / CELL))
	for i in xz.size():
		var p := xz[i]
		var cx := int(round(p.x / CELL))
		var cz := int(round(p.y / CELL))
		for iz in range(maxi(cz - r, 0), mini(cz + r, N - 1) + 1):
			for ix in range(maxi(cx - r, 0), mini(cx + r, N - 1) + 1):
				var d := Vector2(ix * CELL, iz * CELL).distance_to(p)
				var k := iz * N + ix
				if d < road_d[k]:
					road_d[k] = d
					road_s[k] = ss[i]
					road_y[k] = ys[i]
	heights.resize(cells)
	for iz in N:
		for ix in N:
			var k := iz * N + ix
			var nat := natural_height(ix * CELL, iz * CELL)
			var h := nat
			if road_d[k] < RASTER_R:
				h = lerpf(road_y[k], nat, smoothstep(FLAT_HALF, FADE_END, road_d[k]))
			heights[k] = clampf(h, H_MIN, H_MAX)


## Weights {id: w} for a pixel at lateral distance d from the line, s along it.
func _weights(d: float, s: float) -> Dictionary:
	var road := 1.0 - smoothstep(ROAD_HALF - 1.0, ROAD_HALF + 1.0, d)
	var out := {&"grass": 1.0 - road}
	if road <= 0.0:
		return out
	var l := track_length
	var sw := fposmod(s + 150.0, l) - 150.0
	var zsum := 0.0
	for z in ZONES:
		var a: float = z["a"]
		var b: float = z["b"] if z["b"] >= 0.0 else l + z["b"]
		var w := smoothstep(a - 6.0, a + 6.0, sw) * (1.0 - smoothstep(b - 6.0, b + 6.0, sw))
		if w > 0.0:
			out[z["id"]] = out.get(z["id"], 0.0) + w * road
			zsum += w
	out[&"tarmac"] = maxf(1.0 - zsum, 0.0) * road
	return out


func _build_surface_map() -> SurfaceMap:
	var img0 := Image.create(N, N, false, Image.FORMAT_RGBA8)
	var img1 := Image.create(N, N, false, Image.FORMAT_RGBA8)
	for iz in N:
		for ix in N:
			var k := iz * N + ix
			var w := _weights(road_d[k], road_s[k])
			img0.set_pixel(ix, iz, Color(w.get(&"tarmac", 0.0), w.get(&"dirt", 0.0), w.get(&"grass", 0.0), w.get(&"gravel", 0.0)))
			img1.set_pixel(ix, iz, Color(w.get(&"mud", 0.0), 0, 0, 0))
	var sm := SurfaceMap.new()
	# Texel centres at (i + 0.5) * size / N + origin = i * CELL, aligned with the height samples.
	sm.origin = Vector2(-CELL * 0.5, -CELL * 0.5)
	sm.size = Vector2(N * CELL, N * CELL)
	sm.ids = IDS
	sm.images = [img0, img1]
	return sm
