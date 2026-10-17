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
