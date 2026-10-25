extends GutTest
## Per-tick allocation hygiene (#135): the race, powertrain and ghost tick paths use only
## cached/preallocated storage. GDScript has no allocation counter, so this asserts the
## structural properties (no Dictionary-returning call on the tick path, cached arrays are not
## rebuilt, buffers append in place) and that static memory stays flat over 600 ticks.
## MEMORY_STATIC only catches retained growth: transient allocations that are freed within the
## tick (the typical GDScript Dictionary/Array temporary) are invisible to it, so the structural
## asserts above are the real guard and the memory checks are a backstop.

const DT := 1.0 / 120.0
const TICKS := 600
const MEM_SLACK := 64 * 1024


func test_forward_at_matches_sample() -> void:
	var track := TrackSpline.make_circle(100.0, 8)
	add_child_autofree(track)
	for d in [0.0, 13.7, 250.0, 700.0, -5.0]:
		var s := track.sample(d)
		assert_true((s["forward"] as Vector3).is_equal_approx(track.forward_at(d)), "forward at %.1f" % d)
		assert_true((s["position"] as Vector3).is_equal_approx(track.position_at(d)), "position at %.1f" % d)


func test_race_state_step_memory_flat() -> void:
	var track := TrackSpline.make_circle(100.0, 8)
	add_child_autofree(track)
	var det := WrongWayDetector.new()
	var vel := Vector3(0, 0, -20)
	var pos := Vector3(100, 0, 0)
	for i in 60:  # warm up
		det.step(vel, track.forward_at(track.nearest_offset(pos)))
	var before := Performance.get_monitor(Performance.MEMORY_STATIC)
	for i in TICKS:
		det.step(vel, track.forward_at(track.nearest_offset(pos)))
	assert_lt(Performance.get_monitor(Performance.MEMORY_STATIC) - before, MEM_SLACK)


func test_powertrain_driven_cached_and_memory_flat() -> void:
	for layout in [PowertrainDefinition.Layout.RWD, PowertrainDefinition.Layout.FWD, PowertrainDefinition.Layout.AWD]:
		var d := PowertrainDefinition.new()
		d.layout = layout
		var pt := Powertrain.new(d)
		assert_eq(pt.driven, d.driven_wheels(), "driven matches the definition")
		var awd: bool = layout == PowertrainDefinition.Layout.AWD
		for i in 60:
			_tick(pt, awd)
		var before := Performance.get_monitor(Performance.MEMORY_STATIC)
		for i in TICKS:
			_tick(pt, awd)
		assert_lt(Performance.get_monitor(Performance.MEMORY_STATIC) - before, MEM_SLACK)


func _tick(pt: Powertrain, awd: bool) -> void:
	if awd:
		pt.step_awd(DT, 1.0, 20.0, 20.0, 20.0, 20.0, 0.0, 5.0)
	else:
		pt.step(DT, 1.0, 20.0, 20.0, 0.0, 5.0)


func test_ghost_add_sample_appends_in_place() -> void:
	var g := GhostLap.new()
	var xf := Transform3D(Basis.IDENTITY, Vector3(1, 2, 3))
	for i in TICKS:
		g.add_sample(xf, 0.5, 1.0, 0.0, i % 2 == 0)
	assert_eq(g.sample_count(), TICKS)
	assert_eq(g.inputs.size(), TICKS * GhostLap.INPUT_STRIDE)
	assert_almost_eq(g.poses[GhostLap.POSE_STRIDE * 5 + 2], 3.0, 1e-5)
	assert_eq(g.inputs[3], 1.0)
	assert_eq(g.inputs[7], 0.0)


# --- Wheel surface weights on a splat map (#158): sample_into buffers, no Dictionary path ---

func _splat_vehicle() -> Vehicle:
	var ground := StaticBody3D.new()
	ground.set_meta(&"surface_id", &"tarmac")
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 2, 400)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	ground.add_child(cs)
	add_child_autofree(ground)
	# 3 x 3 texels over 40 m: tarmac/gravel/mud mixed everywhere, so every wheel is blended.
	var img := Image.create(3, 3, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.3, 0.2, 0.0))
	var m := SurfaceMap.new()
	m.origin = Vector2(-20, -20)
	m.size = Vector2(40, 40)
	m.ids = [&"tarmac", &"gravel", &"mud"]
	m.images = [img]
	var v := Vehicle.new()
	v.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.05, 0))
	v.surface_map = m
	add_child_autofree(v)
	return v


func test_vehicle_splat_ticks_allocation_free() -> void:
	var v := _splat_vehicle()
	await wait_physics_frames(120)  # settle, warm caches and scratch objects
	for w in v.wheels:
		assert_true(w.is_grounded)
		assert_eq(w.weight_count, 3, "blended on the map")
		assert_eq(w.weight_ids, v.surface_map.ids, "ids are the map's own array")
	await get_tree().physics_frame  # the await itself leaves one object; baseline after it
	var o0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var m0 := Performance.get_monitor(Performance.MEMORY_STATIC)
	for q in TICKS:
		await get_tree().physics_frame
	assert_eq(Performance.get_monitor(Performance.OBJECT_COUNT) - o0, 0.0, "no net object allocations over 600 ticks")
	assert_lt(Performance.get_monitor(Performance.MEMORY_STATIC) - m0, MEM_SLACK)


func test_physics_path_has_no_dictionary_surface_calls() -> void:
	for path in ["res://vehicle/wheel.gd", "res://vehicle/vehicle.gd", "res://vfx/vehicle_vfx.gd",
			"res://audio/vehicle_audio.gd", "res://debug/telemetry_recorder.gd"]:
		var src: String = (load(path) as GDScript).source_code
		for banned in [".sample(", "resolve_weights(", "SurfaceBlend.blend(", "SurfaceBlend.dominant(", ".surface_weights"]:
			assert_false(src.contains(banned), "%s must not call %s" % [path, banned])


func test_wheel_buffers_match_dictionary_path() -> void:
	var m := SurfaceMap.new()
	m.origin = Vector2.ZERO
	m.size = Vector2(10, 10)
	m.ids = [&"tarmac", &"gravel", &"mud", &"dirt"]
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	for r in 8:
		for c in 8:
			img.set_pixel(c, r, Color((c * 37 % 8) / 8.0, (r * 53 % 8) / 8.0, ((c + r) % 3) / 3.0, (c * r % 5) / 5.0))
	m.images = [img]
	var buf := PackedFloat32Array()
	var def := SurfaceDefinition.new()
	var n := 0
	for i in 12:
		for j in 12:
			var x := 0.3 + i * 0.8
			var z := 0.2 + j * 0.8
			var dict := SurfaceBlend.resolve_weights(m, x, z, &"")
			if not m.sample_into(x, z, buf):
				continue
			n += 1
			for k in m.ids.size():
				assert_almost_eq(buf[k], float(dict.get(m.ids[k], 0.0)), 1e-6)
			assert_eq(SurfaceBlend.dominant_of(m.ids, buf, m.ids.size()), SurfaceBlend.dominant(dict), "dominant")
			var a := SurfaceBlend.blend(dict)
			var b := SurfaceBlend.blend_into(m.ids, buf, m.ids.size(), def)
			assert_almost_eq(b.peak_mu_scale, a.peak_mu_scale, 1e-5)
			assert_almost_eq(b.rolling_resistance, a.rolling_resistance, 1e-5)
	assert_gte(n, 100, "sampled >= 100 points")
