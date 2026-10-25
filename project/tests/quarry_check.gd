## Quarry base layout (#103): scene loads headless, terrain elevation 12-25 m, surface map covers
## the track (tarmac start/finish straight, dirt, gravel, mud sampled by a scripted drive along the
## centre line), road width >= 10 m everywhere (centre-line sampling) and a flat start grid
## (slope < 2 degrees over 40 m).
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/quarry_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _main() -> void:
	await physics_frame
	var t0 := Time.get_ticks_msec()
	var quarry: Quarry = (load("res://tracks/quarry/quarry.tscn") as PackedScene).instantiate()
	root.add_child(quarry)
	await physics_frame
	await physics_frame
	print("INFO: quarry build %d ms" % (Time.get_ticks_msec() - t0))
	var terrain := quarry.terrain
	var track := quarry.track
	cu.check(terrain != null and track != null and track.is_valid(), "quarry has terrain and a valid TrackSpline")
	var len := track.length()
	print("INFO: track length %.0f m, %d gates" % [len, track.gate_count()])
	cu.check_range("track length (m)", len, 1600.0, 3500.0) # baseline 1668 m (#104)

	# Elevation range.
	var hmin := 1e9
	var hmax := -1e9
	for h in terrain.heights:
		hmin = minf(hmin, h)
		hmax = maxf(hmax, h)
	print("INFO: elevation %.2f .. %.2f m" % [hmin, hmax])
	cu.check(hmin >= 12.0 - 1e-3 and hmax <= 25.0 + 1e-3, "terrain elevation within 12-25 m")
	cu.check(hmax - hmin >= 8.0, "terrain relief at least 8 m (%.1f)" % (hmax - hmin))

	# Collider agrees with the height query on the road.
	var space := root.get_world_3d().direct_space_state
	var e_ray := 0.0
	for i in 40:
		var p: Vector3 = track.sample(len * i / 40.0)["position"]
		var r := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(p.x, 60, p.z), Vector3(p.x, -5, p.z)))
		cu.check(not r.is_empty(), "ray hits terrain at spline sample %d" % i) if r.is_empty() else null
		if not r.is_empty():
			e_ray = maxf(e_ray, absf((r.position as Vector3).y - terrain.height_at(p.x, p.z)))
	cu.check_range("collider vs height_at on road (m)", e_ray, 0.0, 0.05)

	# Scripted drive along the centre line: surfaces seen, start straight is tarmac, road height.
	var seen := {}
	var straight_ok := true
	var e_road := 0.0
	var steps := int(len / 4.0)
	for i in steps:
		var d := i * 4.0
		var p: Vector3 = track.sample(d)["position"]
		var sid := terrain.dominant_surface_at(p.x, p.z)
		seen[sid] = seen.get(sid, 0) + 1
		var rel := fposmod(d + 100.0, len) - 100.0 # -100 .. len-100
		if rel >= -100.0 and rel <= 300.0 and sid != &"tarmac":
			straight_ok = false
		e_road = maxf(e_road, absf(terrain.height_at(p.x, p.z) - p.y))
	print("INFO: surfaces sampled by scripted drive: ", seen)
	cu.check(seen.size() >= 3, "3+ surface ids sampled along the drive (%d)" % seen.size())
	for id in [&"tarmac", &"dirt", &"gravel"]:
		cu.check(seen.has(id), "drive crosses %s" % id)
	cu.check(not seen.has(&"grass") and not seen.has(&""), "centre line never on grass or outside the map")
	cu.check(straight_ok, "start/finish straight (-100..300 m) is tarmac")
	cu.check_range("road surface vs spline height (m)", e_road, 0.0, 0.1)

	# Road width: scan both sides of the centre line, count contiguous non-grass surface.
	var wmin := 1e9
	var wmax := 0.0
	var wsum := 0.0
	var count := 0
	for i in int(len / 5.0):
		var s := track.sample(i * 5.0)
		var p: Vector3 = s["position"]
		var right := (s["forward"] as Vector3).cross(Vector3.UP)
		var width := 0.0
		for side in [1.0, -1.0]:
			var e := 0.0
			while e < 20.0:
				var q: Vector3 = p + right * side * (e + 0.25)
				var sid := terrain.dominant_surface_at(q.x, q.z)
				if sid == &"grass" or sid == &"":
					break
				e += 0.25
			width += e
		wmin = minf(wmin, width)
		wmax = maxf(wmax, width)
		wsum += width
		count += 1
	print("INFO: road width min %.2f max %.2f mean %.2f m" % [wmin, wmax, wsum / count])
	cu.check_range("road width min (m)", wmin, 10.0, 30.0)

	# Start grid flat: 40 m windows over the grid zone (8 slots * 8 m behind the line + 40 m ahead).
	var worst := 0.0
	var hlo := 1e9
	var hhi := -1e9
	var d0 := track.gate_offsets[0]
	var a := -72.0
	while a <= 20.0:
		for lat in [-6.0, 0.0, 6.0]:
			var p0: Dictionary = track.sample(d0 + a)
			var p1: Dictionary = track.sample(d0 + a + 40.0)
			var f0: Vector3 = p0["forward"]
			var r0 := f0.cross(Vector3.UP)
			var q0: Vector3 = p0["position"] + r0 * lat
			var q1: Vector3 = p1["position"] + r0 * lat
			var dh := terrain.height_at(q1.x, q1.z) - terrain.height_at(q0.x, q0.z)
			var run := Vector2(q1.x - q0.x, q1.z - q0.z).length()
			worst = maxf(worst, rad_to_deg(atan(absf(dh) / run)))
		a += 4.0
	for i in 8:
		var t := track.grid_transform(i)
		var h := terrain.height_at(t.origin.x, t.origin.z)
		hlo = minf(hlo, h)
		hhi = maxf(hhi, h)
	print("INFO: grid slot height spread %.3f m" % (hhi - hlo))
	cu.check_range("start grid worst slope over 40 m (deg)", worst, 0.0, 2.0)
	cu.check_range("grid slot height spread (m)", hhi - hlo, 0.0, 0.5)
	cu.finish(self)
