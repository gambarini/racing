extends GutTest
## Racing line solver and RacingLine queries (#27). Pure logic, no scene.

const G := 9.81


func _params(tire_mu := 1.0, skill := 1.0) -> RacingLineParams:
	var p := RacingLineParams.new()
	p.tire_mu = tire_mu
	p.skill_scale = skill
	p.v_max = 80.0
	return p


func _circle(r: float, n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in n:
		var a := TAU * i / n
		# clockwise seen from above with +X right, -Z forward: a right-hand circle
		out.append(Vector3(r * sin(a), 0.0, -r * cos(a) + r))
	return out


func _ones(n: int, v := 1.0) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(n)
	o.fill(v)
	return o


func test_curvature_of_circle_is_signed_one_over_r() -> void:
	var k := RacingLineSolver.curvature(_circle(50.0, 200), 2)
	for i in k.size():
		assert_almost_eq(k[i], 1.0 / 50.0, 0.0005, "right-hand circle has + curvature")
	var rev := _circle(50.0, 200)
	rev.reverse()
	assert_lt(RacingLineSolver.curvature(rev, 2)[7], 0.0, "left-hand circle is negative")


func test_circle_speed_matches_sqrt_mu_g_r() -> void:
	for r in [25.0, 60.0, 120.0]:
		var line := RacingLine.build(_circle(r, 300), _ones(300, 0.0), _ones(300), _params())
		var want := sqrt(1.0 * G * r)
		for i in line.count():
			assert_almost_eq(line.target_speed[i], want, want * 0.03, "R=%.0f sample %d" % [r, i])


func test_surface_mu_lowers_corner_speed() -> void:
	var p := _params()
	assert_lt(RacingLineSolver.corner_speed(0.02, 0.65, p), RacingLineSolver.corner_speed(0.02, 1.0, p))


func test_straight_to_corner_respects_brake_and_accel_limits() -> void:
	var n := 300
	var ds := _ones(n, 2.0)
	var kappa := _ones(n, 0.0)
	for i in range(140, 170):
		kappa[i] = 1.0 / 15.0 # tight corner
	var mu := _ones(n)
	var p := _params()
	p.v_max = 60.0
	var v := RacingLineSolver.solve(kappa, ds, mu, p)
	var corner := RacingLineSolver.corner_speed(1.0 / 15.0, 1.0, p)
	assert_almost_eq(v[155], corner, 0.01, "corner speed reached in the corner")
	assert_gt(v[0], 2.0 * corner, "far from the corner the car is much faster")
	var worst_brake := 0.0
	var worst_accel := 0.0
	for i in n:
		var j := (i + 1) % n
		var a := (v[j] * v[j] - v[i] * v[i]) / (2.0 * ds[i])
		worst_brake = maxf(worst_brake, -a)
		worst_accel = maxf(worst_accel, a - p.accel_limit(v[i], 1.0))
	assert_lte(worst_brake, p.brake_limit(1.0) + 1e-3, "deceleration <= brake limit everywhere")
	assert_lte(worst_accel, 1e-3, "acceleration <= accel limit everywhere")
	assert_gt(worst_brake, 0.5 * p.brake_limit(1.0), "braking is actually planned before the corner")


func test_speed_bounds() -> void:
	var p := _params()
	p.v_max = 40.0
	var n := 100
	var kappa := _ones(n, 0.0)
	kappa[10] = 1.0 # 1 m radius would be below v_min
	var v := RacingLineSolver.solve(kappa, _ones(n, 3.0), _ones(n, 0.45), p)
	for x in v:
		assert_gte(x, p.v_min - 1e-4)
		assert_lte(x, p.v_max + 1e-4)


func _ring_line() -> RacingLine:
	var line := RacingLine.build(_circle(80.0, 200), _ones(200, 0.0), _ones(200), _params())
	return line


func test_queries_wrap_and_interpolate() -> void:
	var line := _ring_line()
	assert_almost_eq(line.length, TAU * 80.0, 1.0, "closed loop length")
	var p0 := line.point_at(0.0)
	var p1 := line.point_at(line.length)
	assert_lt(p0.distance_to(p1), 1e-3, "s wraps at the loop length")
	assert_lt(line.point_at(-5.0).distance_to(line.point_at(line.length - 5.0)), 1e-3, "negative s wraps")
	assert_almost_eq(line.target_speed_at(10.0), sqrt(G * 80.0), 1.0)
	assert_gt(line.curvature_at(10.0), 0.0)
	assert_almost_eq(line.tangent_at(0.0).length(), 1.0, 1e-4)


func test_nearest_s_roundtrip_global_and_hinted() -> void:
	var line := _ring_line()
	for s in [0.0, 13.7, 250.0, 499.0]:
		var pos := line.point_at(s) + Vector3(0.0, 1.0, 0.0)
		assert_almost_eq(line.nearest_s(pos), s, 0.2, "global search s=%.1f" % s)
		assert_almost_eq(line.nearest_s(pos, s - 3.0, 20.0), s, 0.2, "hinted search s=%.1f" % s)
	# hint across the wrap
	var near_end := line.length - 1.0
	assert_almost_eq(line.nearest_s(line.point_at(near_end), 2.0, 20.0), near_end, 0.2, "hint wraps over s=0")


func test_variant_switches_to_the_joker_lap() -> void:
	var line := _ring_line()
	assert_false(line.has_joker())
	line.variant = RacingLine.Variant.JOKER
	assert_almost_eq(line.lap_length(), line.length, 1e-3, "no joker lap: falls back to main")
	line.joker = RacingLine.build(_circle(90.0, 220), _ones(220, 0.0), _ones(220), _params())
	assert_true(line.has_joker())
	assert_almost_eq(line.lap_length(), TAU * 90.0, 1.0)
	assert_almost_eq(line.joker_length_delta(), TAU * 10.0, 1.0)
	line.variant = RacingLine.Variant.MAIN
	assert_almost_eq(line.lap_length(), TAU * 80.0, 1.0)


func test_resource_roundtrip_keeps_data() -> void:
	var line := _ring_line()
	var path := "user://test_racing_line.tres"
	assert_eq(ResourceSaver.save(line, path), OK)
	var back := load(path) as RacingLine
	assert_eq(back.count(), line.count())
	assert_almost_eq(back.target_speed_at(33.0), line.target_speed_at(33.0), 1e-4)
	DirAccess.remove_absolute(path)


func test_friction_ellipse_bounds_combined_load() -> void:
	var n := 300
	var ds := _ones(n, 2.0)
	var kappa := _ones(n, 0.0)
	for i in range(140, 170):
		kappa[i] = 1.0 / 40.0
	for skill in [1.0, 0.66]:
		var p := _params(1.0, skill)
		var v := RacingLineSolver.solve(kappa, ds, _ones(n), p)
		for i in n:
			var j := (i + 1) % n
			var a_lat: float = v[i] * v[i] * kappa[i]
			var a_long: float = (v[j] * v[j] - v[i] * v[i]) / (2.0 * ds[i])
			assert_lte(sqrt(a_lat * a_lat + a_long * a_long) / (p.tire_mu * G), 1.02, "skill %.2f sample %d" % [skill, i])


func test_long_budget_shrinks_to_zero_at_the_grip_limit() -> void:
	var p := _params()
	var kappa := 0.02
	var v_lim := sqrt(p.tire_mu * G / kappa)
	assert_almost_eq(RacingLineSolver.long_budget(5.0, v_lim, kappa, 1.0, p), 0.0, 1e-3)
	assert_almost_eq(RacingLineSolver.long_budget(5.0, 0.0, kappa, 1.0, p), 5.0, 1e-6)
