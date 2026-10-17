extends GutTest
## Surface map sampling and weight-averaged blending (#19). Pure logic, no scene.

const IDS: Array[StringName] = [&"tarmac", &"gravel", &"mud", &"dirt"]


## Map with `cols` x `rows` texels covering 0..cols*texel by 0..rows*texel; `fill` is a
## Callable(col, row) -> Color (channel order = IDS).
func _map(cols: int, rows: int, texel: float, fill: Callable) -> SurfaceMap:
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for r in rows:
		for c in cols:
			img.set_pixel(c, r, fill.call(c, r))
	var m := SurfaceMap.new()
	m.origin = Vector2.ZERO
	m.size = Vector2(cols * texel, rows * texel)
	m.ids = IDS.duplicate()
	m.images = [img]
	return m


func test_texel_centre_returns_pure_surface() -> void:
	var m := _map(2, 2, 1.0, func(c, _r): return Color(1, 0, 0, 0) if c == 0 else Color(0, 1, 0, 0))
	var w := m.sample(0.5, 0.5)
	assert_eq(w.size(), 1)
	assert_almost_eq(w[&"tarmac"], 1.0, 1e-5)
	w = m.sample(1.5, 0.5)
	assert_almost_eq(w[&"gravel"], 1.0, 1e-5)


func test_bilinear_midpoint_is_half_half() -> void:
	var m := _map(2, 2, 1.0, func(c, _r): return Color(1, 0, 0, 0) if c == 0 else Color(0, 1, 0, 0))
	var w := m.sample(1.0, 1.0)
	assert_almost_eq(w[&"tarmac"], 0.5, 1e-5)
	assert_almost_eq(w[&"gravel"], 0.5, 1e-5)


func test_weights_renormalised() -> void:
	# Texels that do not sum to 1 (e.g. after image compression) still yield weights summing to 1.
	var m := _map(2, 2, 1.0, func(_c, _r): return Color(0.3, 0.3, 0.0, 0.0))
	var w := m.sample(0.7, 0.9)
	var total := 0.0
	for k in w:
		total += w[k]
	assert_almost_eq(total, 1.0, 1e-6)
	assert_almost_eq(w[&"tarmac"], 0.5, 1e-6)


func test_outside_map_and_empty_texel_return_empty() -> void:
	var m := _map(2, 2, 1.0, func(_c, _r): return Color(0, 0, 0, 0))
	assert_true(m.sample(1.0, 1.0).is_empty(), "all-zero texels have no coverage")
	var m2 := _map(2, 2, 1.0, func(_c, _r): return Color(1, 0, 0, 0))
	assert_true(m2.sample(-0.1, 1.0).is_empty())
	assert_true(m2.sample(1.0, 2.1).is_empty())
	assert_false(m2.sample(1.0, 1.0).is_empty())


func test_second_image_channels() -> void:
	var m := _map(2, 2, 1.0, func(_c, _r): return Color(0, 0, 0, 0))
	var img2 := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img2.fill(Color(0, 1, 0, 0))
	m.images.append(img2)
	m.ids.append_array([&"grass", &"deep_mud", &"tarmac_wet", &"dirt"])
	var w := m.sample(1.0, 1.0)
	assert_almost_eq(w[&"deep_mud"], 1.0, 1e-5)


func test_fallback_chain() -> void:
	var m := _map(2, 2, 1.0, func(_c, _r): return Color(0, 1, 0, 0))
	assert_eq(SurfaceBlend.resolve_weights(m, 1.0, 1.0, &"mud"), {&"gravel": 1.0}, "map overrides collider inside bounds")
	assert_eq(SurfaceBlend.resolve_weights(m, 50.0, 1.0, &"mud"), {&"mud": 1.0}, "outside bounds: collider id")
	assert_eq(SurfaceBlend.resolve_weights(null, 1.0, 1.0, &""), {&"tarmac": 1.0}, "no map, no id: tarmac")


func test_fifty_fifty_tarmac_gravel_mu_peak_scale() -> void:
	var d := SurfaceBlend.blend({&"tarmac": 0.5, &"gravel": 0.5})
	assert_almost_eq(d.peak_mu_scale, 0.825, 1e-6)
	var g := SurfaceRegistry.get_surface(&"gravel")
	var t := SurfaceRegistry.get_surface(&"tarmac")
	assert_almost_eq(d.slide_mu_scale, 0.5 * (g.slide_mu_scale + t.slide_mu_scale), 1e-6)
	assert_almost_eq(d.peak_slip_scale, 0.5 * (g.peak_slip_scale + t.peak_slip_scale), 1e-6)
	assert_almost_eq(d.rolling_resistance, 0.5 * (g.rolling_resistance + t.rolling_resistance), 1e-9)
	assert_almost_eq(d.deformation_drag, 0.5 * (g.deformation_drag + t.deformation_drag), 1e-12)
	var tp := TireParams.for_surface(TireParams.new(), d)
	assert_almost_eq(tp.mu_peak, 1.1 * 0.825, 1e-6)


func test_single_surface_blend_is_registry_definition() -> void:
	assert_eq(SurfaceBlend.blend({&"gravel": 1.0}), SurfaceRegistry.get_surface(&"gravel"))


func test_dominant() -> void:
	assert_eq(SurfaceBlend.dominant({&"tarmac": 0.3, &"gravel": 0.7}), &"gravel")


func test_ramp_is_linear_and_monotone_across_transition() -> void:
	# 0.5 m texels: tarmac | gravel gives a 0.5 m ramp between texel centres (z = 0.25 .. 0.75).
	var m := _map(2, 4, 0.5, func(_c, r): return Color(1, 0, 0, 0) if r < 1 else Color(0, 1, 0, 0))
	var prev := 1.0
	for i in 101:
		var z := 0.25 + 0.5 * i / 100.0
		var w := m.sample(1.0, z)
		var s := SurfaceBlend.blend(w).peak_mu_scale
		assert_true(s <= prev + 1e-9, "monotone at step %d" % i)
		prev = s
		assert_almost_eq(s, 1.0 - 0.35 * i / 100.0, 1e-5, "linear at step %d" % i)


func test_telemetry_weight_columns_match_registry() -> void:
	assert_eq(TelemetrySchema.N_SURF, SurfaceRegistry.ids().size())
	assert_eq(TelemetrySchema.SURFACE_W_COL, TelemetrySchema.POWERTRAIN_COL + TelemetrySchema.N_POWERTRAIN)
	var names := TelemetrySchema.column_names()
	assert_eq(names[TelemetrySchema.weight_col(1, 1)], "fr_w_gravel")


# --- sample_into equivalence (#133) ---

func _check_equivalent(m: SurfaceMap, label: String) -> void:
	var out := PackedFloat32Array()
	var hi := m.origin + m.size
	var lo := m.origin - m.size * 0.1
	var span := m.size * 1.2
	var worst := 0.0
	var verdict_mismatch := 0
	var empties := 0
	for j in 64:
		for i in 64:
			var x := lo.x + span.x * i / 63.0
			var z := lo.y + span.y * j / 63.0
			# Force exact edges/corners of the map into the grid.
			if i == 8:
				x = m.origin.x
			elif i == 55:
				x = hi.x
			if j == 8:
				z = m.origin.y
			elif j == 55:
				z = hi.y
			var d := m.sample(x, z)
			var ok := m.sample_into(x, z, out)
			if ok != (not d.is_empty()):
				verdict_mismatch += 1
			if d.is_empty():
				empties += 1
				for k in m.ids.size():
					worst = maxf(worst, absf(out[k]))
			else:
				for k in m.ids.size():
					worst = maxf(worst, absf(out[k] - d.get(m.ids[k], 0.0)))
	assert_eq(verdict_mismatch, 0, label + ": empty/non-empty verdict")
	assert_lt(worst, 1e-5, label + ": max weight difference")
	assert_gt(empties, 0, label + ": grid includes outside points")


func test_sample_into_matches_sample_synthetic_maps() -> void:
	_check_equivalent(_map(2, 2, 1.0, func(c, _r): return Color(1, 0, 0, 0) if c == 0 else Color(0, 1, 0, 0)), "two-texel")
	_check_equivalent(_map(8, 5, 1.5, func(c, r): return Color(c / 8.0, r / 5.0, 0.2, 0.1)), "gradient")
	_check_equivalent(_map(4, 4, 1.0, func(_c, _r): return Color(0.3, 0.3, 0.0, 0.0)), "unnormalised")
	_check_equivalent(_map(3, 3, 2.0, func(c, r): return Color(0, 0, 0, 0) if (c + r) % 2 == 0 else Color(0.5, 0.5, 0, 0)), "zero-coverage holes")
	var m := _map(6, 6, 1.0, func(c, r): return Color(c / 6.0, 0.1, r / 6.0, 0.0))
	var img2 := Image.create(6, 6, false, Image.FORMAT_RGBA8)
	for r in 6:
		for c in 6:
			img2.set_pixel(c, r, Color(0.0 if c < 3 else 1.0, 0.5, 0.0, 0.25))
	m.images.append(img2)
	m.ids = [&"a", &"b", &"c", &"d", &"e", &"f", &"g", &"h"]
	_check_equivalent(m, "two-image")


func test_sample_into_matches_sample_quarry() -> void:
	var q := Quarry.new()
	q.build()
	_check_equivalent(q.terrain.surface_map, "quarry")
	q.free()


func test_sample_into_resizes_and_zeroes() -> void:
	var m := _map(2, 2, 1.0, func(_c, _r): return Color(1, 0, 0, 0))
	var out := PackedFloat32Array()
	assert_true(m.sample_into(1.0, 1.0, out))
	assert_eq(out.size(), 4)
	assert_almost_eq(out[0], 1.0, 1e-6)
	assert_false(m.sample_into(-5.0, 1.0, out))
	assert_eq(out[0], 0.0)


func test_dominant_surface_at_matches_sample() -> void:
	var t := HeightmapTerrain.new()
	t.surface_map = _map(2, 2, 1.0, func(c, _r): return Color(1, 0, 0, 0) if c == 0 else Color(0, 1, 0, 0))
	assert_eq(t.dominant_surface_at(0.5, 0.5), &"tarmac")
	assert_eq(t.dominant_surface_at(1.5, 0.5), &"gravel")
	assert_eq(t.dominant_surface_at(9.0, 0.5), &"")
	t.free()


func test_load_from_image_validates_size() -> void:
	var t := HeightmapTerrain.new()
	t.mesh_step = 2
	assert_eq(t.load_from_image(Image.create(5, 5, false, Image.FORMAT_RF), Vector2.ZERO), OK)
	assert_eq(t.n, 5)
	# validate_image is the silent twin of load_from_image's check (load_from_image also push_errors,
	# which the CI log scan would flag).
	assert_eq(t.validate_image(Image.create(6, 6, false, Image.FORMAT_RF)), ERR_INVALID_PARAMETER)
	assert_eq(t.validate_image(Image.create(1, 1, false, Image.FORMAT_RF)), ERR_INVALID_PARAMETER)
	assert_eq(t.validate_image(Image.create(5, 4, false, Image.FORMAT_RF)), ERR_INVALID_PARAMETER)
	assert_eq(t.validate_image(Image.create(5, 5, false, Image.FORMAT_RGBA8)), ERR_INVALID_PARAMETER)
	assert_eq(t.validate_image(Image.create(5, 5, false, Image.FORMAT_RF)), OK)
	t.free()
	var q := Quarry.new()
	q.build()
	assert_eq(q.terrain.n, Quarry.N)
	q.free()
