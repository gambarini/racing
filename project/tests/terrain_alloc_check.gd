## Allocation-free surface lookup (#133): 4 wheels x 600 ticks of SurfaceMap.sample_into /
## HeightmapTerrain.surface_weights_into on the Quarry map leave object count and static memory
## unchanged; the old sample() loop is the control and must grow. Also prints the cost ratio.
## Run: godot --headless --path project -s res://tests/terrain_alloc_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const CALLS := 2400

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _loop_into(sm: SurfaceMap, pts: PackedVector2Array, out: PackedFloat32Array) -> void:
	for i in CALLS:
		sm.sample_into(pts[i].x, pts[i].y, out)


func _loop_old(sm: SurfaceMap, pts: PackedVector2Array) -> void:
	for i in CALLS:
		sm.sample(pts[i].x, pts[i].y)


func _loop_terrain(t: HeightmapTerrain, pts: PackedVector2Array, out: PackedFloat32Array) -> void:
	for i in CALLS:
		t.surface_weights_into(pts[i].x, pts[i].y, out)
		t.dominant_surface_at(pts[i].x, pts[i].y)


func _main() -> void:
	await physics_frame
	var q := Quarry.new()
	q.build()
	var terrain: HeightmapTerrain = q.terrain
	var sm := terrain.surface_map
	var rt := q.route_points(&"main", Quarry.DEFAULT_LINE)
	var pts := PackedVector2Array()
	for i in 4:
		for t in 600:
			var p := rt[(t * 7 + i * 13) % rt.size()]
			pts.append(Vector2(p.x + i * 0.9, p.z + i * 0.4))
	var out := PackedFloat32Array()
	# Warm-up (builds the byte cache, sizes buffers).
	_loop_into(sm, pts, out)
	_loop_terrain(terrain, pts, out)
	_loop_old(sm, pts)

	var o0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var m0 := Performance.get_monitor(Performance.MEMORY_STATIC)
	_loop_into(sm, pts, out)
	_loop_terrain(terrain, pts, out)
	var o1 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var m1 := Performance.get_monitor(Performance.MEMORY_STATIC)
	cu.check_range("sample_into/surface_weights_into object count delta", o1 - o0, 0.0, 0.0)
	cu.check_range("sample_into/surface_weights_into static memory growth (bytes, estimate gate 64 KiB)", m1 - m0, -65536.0, 65536.0)

	# Control: the old Dictionary-returning path, results kept so growth is observable.
	var m2 := Performance.get_monitor(Performance.MEMORY_STATIC)
	var keep := []
	for i in CALLS:
		keep.append(sm.sample(pts[i].x, pts[i].y))
	var growth := Performance.get_monitor(Performance.MEMORY_STATIC) - m2
	print("INFO: control sample() x%d (results kept): static memory growth %.0f B" % [CALLS, growth])
	cu.check(growth > 65536.0, "control: old sample() loop shows growth above the tolerance (check can detect allocation)")
	keep.clear()

	# Cost ratio, interleaved A B A B, medians of 7.
	var ra := []
	var rb := []
	for r in 7:
		var t0 := Time.get_ticks_usec()
		_loop_old(sm, pts)
		var t1 := Time.get_ticks_usec()
		_loop_into(sm, pts, out)
		var t2 := Time.get_ticks_usec()
		ra.append(t1 - t0)
		rb.append(t2 - t1)
	ra.sort()
	rb.sort()
	var ratio := float(rb[3]) / float(ra[3])
	print("INFO: %d calls: sample() median %d us, sample_into() median %d us, ratio %.3f" % [CALLS, ra[3], rb[3], ratio])
	cu.check_range("sample_into / sample time ratio (measured floor ~0.7; issue estimate 0.6 unreachable in GDScript, gate 0.85)", ratio, 0.0, 0.85)

	q.free()
	cu.finish(self)
