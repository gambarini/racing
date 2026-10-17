extends GutTest
## Per-surface VFX (#20): resource coverage, emission vs slip/speed, blend scaling, tyre-mark
## gate and caps, particle budget. Headless: reads emitter state, renders nothing.

const V1_IDS: Array[StringName] = [&"tarmac", &"tarmac_wet", &"gravel", &"mud", &"dirt", &"grass",
		&"deep_mud"]


func _vfx_vehicle() -> Array:
	var v := Vehicle.new()
	v.tire_forces_enabled = false
	add_child_autofree(v)
	var fx := VehicleVfx.new()
	fx.tyre_marks = TyreMarks.new()
	v.add_child(fx)
	fx.vehicle = v
	add_child_autofree(fx.tyre_marks)
	return [v, fx]


func _set_wheels(v: Vehicle, weights: Dictionary, kappa: float, alpha: float) -> void:
	for w in v.wheels:
		w.is_grounded = true
		w.surface_weights = weights
		w.surface_id = SurfaceBlend.dominant(weights)
		w.kappa = kappa
		w.alpha = alpha
		w.contact_point = v.global_position
		w.contact_normal = Vector3.UP


func test_all_v1_surfaces_have_effect_and_marks() -> void:
	assert_eq(SurfaceRegistry.ids().size(), 7)
	for id in V1_IDS:
		var s := SurfaceRegistry.get_surface(id)
		assert_eq(s.id, id)
		assert_not_null(s.particle_effect, "%s particle_effect" % id)
		assert_not_null(s.tyre_mark, "%s tyre_mark" % id)
		assert_true(s.particle_effect.max_amount <= SurfaceVfxMath.MAX_EFFECT_AMOUNT, "%s amount" % id)


func test_zero_at_rest_and_below_2ms() -> void:
	for id in V1_IDS:
		var e := SurfaceRegistry.get_surface(id).particle_effect
		for sp in [0.0, 1.0, 2.0]:
			assert_eq(SurfaceVfxMath.intensity(true, 0.5, 0.5, sp, e.roll_rate), 0.0)
	assert_eq(SurfaceVfxMath.intensity(false, 0.5, 0.5, 20.0, 0.3), 0.0, "airborne")
	assert_gt(SurfaceVfxMath.intensity(true, 0.1, 0.0, 3.0, 0.0), 0.0)


func test_rate_monotonic_in_slip_and_speed() -> void:
	var prev := -1.0
	for i in 21:
		var k := 0.02 * i
		var r := SurfaceVfxMath.intensity(true, k, 0.0, 20.0, 0.2)
		assert_gte(r, prev)
		prev = r
	prev = -1.0
	for i in 21:
		var a := 0.02 * i
		var r := SurfaceVfxMath.intensity(true, 0.0, a, 20.0, 0.2)
		assert_gte(r, prev)
		prev = r
	assert_gt(SurfaceVfxMath.intensity(true, 0.3, 0.0, 20.0, 0.2),
			SurfaceVfxMath.intensity(true, 0.0, 0.0, 20.0, 0.2))
	assert_lte(SurfaceVfxMath.intensity(true, 5.0, 5.0, 80.0, 0.2), 1.0)


func test_node_emission_zero_at_rest_and_rises_with_slip() -> void:
	var p := _vfx_vehicle()
	var v: Vehicle = p[0]
	var fx: VehicleVfx = p[1]
	_set_wheels(v, {&"dirt": 1.0}, 0.3, 0.3)
	v.linear_velocity = Vector3(0, 0, 1.5)
	fx.step()
	assert_eq(fx.emission_rate(0, &"dirt"), 0.0, "below 2 m/s")
	v.linear_velocity = Vector3(0, 0, 20)
	var prev := -1.0
	for i in 8:
		_set_wheels(v, {&"dirt": 1.0}, 0.04 * i, 0.0)
		fx.step()
		var r := fx.emission_rate(0, &"dirt")
		assert_gte(r, prev, "monotonic at step %d" % i)
		prev = r
	assert_gt(prev, 0.0)


func test_blend_scales_both_effects() -> void:
	var p := _vfx_vehicle()
	var v: Vehicle = p[0]
	var fx: VehicleVfx = p[1]
	v.linear_velocity = Vector3(0, 0, 20)
	_set_wheels(v, {&"dirt": 1.0}, 0.3, 0.0)
	fx.step()
	var full_dirt := fx.emission_rate(0, &"dirt")
	_set_wheels(v, {&"gravel": 1.0}, 0.3, 0.0)
	fx.step()
	var full_gravel := fx.emission_rate(0, &"gravel")
	_set_wheels(v, {&"gravel": 0.5, &"dirt": 0.5}, 0.3, 0.0)
	fx.step()
	assert_gt(fx.emission_rate(0, &"dirt"), 0.0)
	assert_gt(fx.emission_rate(0, &"gravel"), 0.0)
	assert_almost_eq(fx.emission_rate(0, &"dirt"), full_dirt * 0.5, 1e-3)
	assert_almost_eq(fx.emission_rate(0, &"gravel"), full_gravel * 0.5, 1e-3)
	# 25/75 follows the weights
	_set_wheels(v, {&"gravel": 0.25, &"dirt": 0.75}, 0.3, 0.0)
	fx.step()
	assert_almost_eq(fx.emission_rate(0, &"dirt"), full_dirt * 0.75, 1e-3)
	assert_almost_eq(fx.emission_rate(0, &"gravel"), full_gravel * 0.25, 1e-3)


func test_mark_gate_per_surface() -> void:
	for id in V1_IDS:
		var st := SurfaceRegistry.get_surface(id).tyre_mark
		assert_false(SurfaceVfxMath.should_mark(true, st.slip_ratio_threshold * 0.9, 0.0, 20.0, st))
		assert_false(SurfaceVfxMath.should_mark(true, 0.0, st.slip_angle_threshold * 0.9, 20.0, st))
		assert_true(SurfaceVfxMath.should_mark(true, st.slip_ratio_threshold * 1.1, 0.0, 20.0, st))
		assert_true(SurfaceVfxMath.should_mark(true, 0.0, -st.slip_angle_threshold * 1.1, 20.0, st))
		assert_false(SurfaceVfxMath.should_mark(false, 1.0, 1.0, 20.0, st), "airborne")


func test_node_lays_marks_only_when_slipping() -> void:
	var p := _vfx_vehicle()
	var v: Vehicle = p[0]
	var fx: VehicleVfx = p[1]
	v.linear_velocity = Vector3(0, 0, 20)
	for i in 20:
		_set_wheels(v, {&"tarmac": 1.0}, 0.02, 0.01)
		for w in v.wheels:
			w.contact_point = Vector3(0, 0, i * 0.5)
		fx.step()
	assert_eq(fx.tyre_marks.live_count(), 0, "grip: no marks")
	for i in 20:
		_set_wheels(v, {&"tarmac": 1.0}, 0.6, 0.0)
		for w in v.wheels:
			w.contact_point = Vector3(0, 0, i * 0.5)
		fx.step()
	assert_gt(fx.tyre_marks.live_count(), 0, "slip: marks")


func test_mark_segments_capped_at_400() -> void:
	var m := TyreMarks.new()
	add_child_autofree(m)
	var st := SurfaceRegistry.get_surface(&"tarmac").tyre_mark
	for i in 1500:
		m.add_segment(Vector3(0, 0, i), Vector3(0, 0, i + 0.3), Vector3.UP, st)
		assert_lte(m.live_count(), 400)
	assert_eq(m.live_count(), 400)
	assert_eq(m.get_child_count(), 400, "no node leak")


func test_particle_budget() -> void:
	var p := _vfx_vehicle()
	var v: Vehicle = p[0]
	var fx: VehicleVfx = p[1]
	v.linear_velocity = Vector3(0, 0, 40)
	for id in V1_IDS:
		_set_wheels(v, {id: 1.0}, 1.0, 1.0)
		fx.step()
		assert_lte(fx.live_particle_estimate(), SurfaceVfxMath.MAX_LIVE_PARTICLES_PER_CAR, str(id))
	_set_wheels(v, {&"gravel": 0.5, &"mud": 0.5}, 1.0, 1.0)
	fx.step()
	assert_lte(fx.live_particle_estimate(), SurfaceVfxMath.MAX_LIVE_PARTICLES_PER_CAR)
	for em: GPUParticles3D in fx.emitters.values():
		assert_lte(em.amount, SurfaceVfxMath.MAX_EFFECT_AMOUNT)
	assert_eq(SurfaceVfxMath.MAX_LIVE_PARTICLES_PER_CAR, 4 * SurfaceVfxMath.MAX_EFFECT_AMOUNT)
