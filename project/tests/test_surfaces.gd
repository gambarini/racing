extends GutTest
## Surface definitions, registry, collider lookup and the pure tire scaling (#12).

const FZ := 3000.0


func _peak_k(p: TireParams) -> float:
	var best := 0.0
	var best_k := 0.0
	for i in range(1, 20001):
		var k := i / 20000.0 * 0.8
		var f := absf(TireModel.compute(k, 0.0, FZ, p).x)
		if f > best:
			best = f
			best_k = k
	return best_k


func _peak_fx(p: TireParams) -> float:
	return absf(TireModel.compute(_peak_k(p), 0.0, FZ, p).x)


func test_resource_values() -> void:
	var t := SurfaceRegistry.get_surface(&"tarmac")
	var g := SurfaceRegistry.get_surface(&"gravel")
	var m := SurfaceRegistry.get_surface(&"mud")
	assert_eq(t.id, &"tarmac")
	assert_eq([t.peak_mu_scale, t.slide_mu_scale, t.peak_slip_scale, t.rolling_resistance, t.deformation_drag],
			[1.0, 1.0, 1.0, 0.012, 0.0])
	assert_eq(g.id, &"gravel")
	assert_eq([g.peak_mu_scale, g.slide_mu_scale, g.peak_slip_scale, g.rolling_resistance, g.deformation_drag],
			[0.65, 0.75, 2.0, 0.035, 0.00004])
	assert_eq(m.id, &"mud")
	assert_eq([m.peak_mu_scale, m.slide_mu_scale, m.peak_slip_scale, m.rolling_resistance, m.deformation_drag],
			[0.45, 0.5, 2.5, 0.08, 0.0002])


func test_unknown_id_returns_tarmac() -> void:
	var t := SurfaceRegistry.get_surface(&"tarmac")
	assert_eq(SurfaceRegistry.get_surface(&"lava_test"), t)
	assert_eq(SurfaceRegistry.get_surface(&"lava_test"), t)
	assert_true(SurfaceRegistry._warned.has(&"lava_test"), "unknown id recorded (warned once)")


func test_resistance_force() -> void:
	var g := SurfaceRegistry.get_surface(&"gravel")
	assert_almost_eq(g.resistance_force(3000.0, 0.0), 0.035 * 3000.0, 1e-6)
	assert_almost_eq(g.resistance_force(3000.0, 10.0), 3000.0 * (0.035 + 0.00004 * 100.0), 1e-6)
	assert_eq(g.resistance_force(0.0, 10.0), 0.0)


func test_for_surface_scaling() -> void:
	var base := TireParams.new()
	var pt := _peak_fx(base)
	var kt := _peak_k(base)
	for c in [[&"gravel", 0.65, 2.0], [&"mud", 0.45, 2.5]]:
		var p := TireParams.for_surface(base, SurfaceRegistry.get_surface(c[0]))
		assert_almost_eq(_peak_fx(p) / pt, c[1], 0.01, "%s peak Fx ratio" % c[0])
		assert_almost_eq(_peak_k(p) / kt, c[2], 0.05 * c[2], "%s peak slip ratio" % c[0])
	assert_eq(base.mu_peak, 1.1, "base untouched")


func test_tarmac_and_null_bit_identical() -> void:
	var base := TireParams.new()
	var pt := TireParams.for_surface(base, SurfaceRegistry.get_surface(&"tarmac"))
	var pn := TireParams.for_surface(base, null)
	for k in [0.0, 0.03, 0.1, 0.4, -0.2]:
		for a in [0.0, 0.05, -0.14, 0.3]:
			var f0 := TireModel.compute(k, a, FZ, base)
			assert_eq(TireModel.compute(k, a, FZ, pt), f0)
			assert_eq(TireModel.compute(k, a, FZ, pn), f0)


func test_surface_id_of_meta_then_group_then_default() -> void:
	var a := StaticBody3D.new()
	a.set_meta(&"surface_id", "mud")
	add_child(a)
	a.add_to_group(&"surface_gravel")
	assert_eq(Wheel.surface_id_of(a), &"mud", "metadata wins")
	var b := StaticBody3D.new()
	add_child(b)
	b.add_to_group(&"surface_gravel")
	assert_eq(Wheel.surface_id_of(b), &"gravel", "group fallback")
	var c := StaticBody3D.new()
	add_child(c)
	assert_eq(Wheel.surface_id_of(c), &"tarmac", "default")
	assert_eq(Wheel.surface_id_of(null), &"tarmac")
	for n in [a, b, c]:
		n.queue_free()


func test_v1_surface_table() -> void:
	# id: [peak, slide, slip, Crr, k]
	var table := {
		&"tarmac_wet": [0.70, 0.69, 1.0, 0.014, 0.0],
		&"dirt": [0.75, 0.81, 1.6, 0.022, 0.00001],
		&"grass": [0.50, 0.50, 1.6, 0.030, 0.00001],
		&"deep_mud": [0.35, 0.375, 2.5, 0.14, 0.0005],
	}
	for id in table:
		var d := SurfaceRegistry.get_surface(id)
		assert_eq(d.id, id)
		var t: Array = table[id]
		assert_eq([d.peak_mu_scale, d.slide_mu_scale, d.peak_slip_scale, d.rolling_resistance, d.deformation_drag], t, str(id))
		assert_true(SurfaceRegistry.ids().has(id))
