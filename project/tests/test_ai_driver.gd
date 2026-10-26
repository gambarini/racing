extends GutTest
## AI driver (#28): steering, speed PI, slip logic and the "same physics" guard. Pure logic, no scene.

const DT := 1.0 / 120.0


## Closed rectangle 400 x 200 m, 5 m spacing, driven along +X on the south edge then turning right
## (+Z). Car on the south edge at x = 0 heads +X (right of travel = +Z).
func _line() -> RacingLine:
	var pts := PackedVector3Array()
	var corners := [Vector3(-200, 0, 0), Vector3(200, 0, 0), Vector3(200, 0, 200), Vector3(-200, 0, 200)]
	for c in 4:
		var a: Vector3 = corners[c]
		var b: Vector3 = corners[(c + 1) % 4]
		var n := int(a.distance_to(b) / 5.0)
		for i in n:
			pts.append(a.lerp(b, float(i) / n))
	var ones := PackedFloat32Array()
	ones.resize(pts.size())
	ones.fill(1.0)
	var zeros := PackedFloat32Array()
	zeros.resize(pts.size())
	return RacingLine.build(pts, zeros, ones)


func _driver() -> AiDriver:
	var ai := AiDriver.new()
	ai.setup(_line())
	return ai


func test_look_ahead_is_clamped() -> void:
	var ai := _driver()
	assert_eq(ai.look_distance(0.0), 6.0, "floor 6 m")
	assert_eq(ai.look_distance(5.0), 6.0)
	assert_almost_eq(ai.look_distance(20.0), 12.0, 1e-4, "k * speed in between")
	assert_eq(ai.look_distance(90.0), 30.0, "cap 30 m")


func test_steers_toward_the_line() -> void:
	# 3 m to the left of the line (-Z side), heading along it: steer right (+).
	var ai := _driver()
	var st := DriverInputState.new()
	for i in 60:
		ai.step(Vector3(0, 0, -3), Vector3(1, 0, 0), 15.0, 0.0, DT, st)
	assert_gt(st.steer, 0.02, "line is to the right -> steer right")
	var ai2 := _driver()
	var st2 := DriverInputState.new()
	for i in 60:
		ai2.step(Vector3(0, 0, 3), Vector3(1, 0, 0), 15.0, 0.0, DT, st2)
	assert_lt(st2.steer, -0.02, "line is to the left -> steer left")
	assert_almost_eq(st.steer, -st2.steer, 1e-4, "symmetric")


func test_on_line_straight_steers_zero() -> void:
	var ai := _driver()
	var st := DriverInputState.new()
	for i in 30:
		ai.step(Vector3(0, 0, 0), Vector3(1, 0, 0), 20.0, 0.0, DT, st)
	assert_almost_eq(st.steer, 0.0, 1e-3)


func test_steer_respects_the_steering_filter_rate_and_range() -> void:
	var ai := _driver()
	var st := DriverInputState.new()
	var prev := 0.0
	var speed := 25.0
	# huge cross-track error asks for full lock at once; the output must ramp at the filter rate
	for i in 120:
		ai.step(Vector3(0, 0, -20), Vector3(1, 0, 0), speed, 0.0, DT, st)
		var limit := SteeringFilter.rate_limit(speed * 3.6) * DT
		assert_lte(absf(st.steer - prev), limit + 1e-6, "tick %d: step within the filter's rate limit" % i)
		assert_lte(absf(st.steer), SteeringFilter.range_scale(speed * 3.6) + 1e-6, "within the speed-sensitive range")
		prev = st.steer
	assert_gt(prev, 0.1, "and it does ask for a real steering input")


func test_speed_pi_no_pedal_overlap_and_directions() -> void:
	var ai := _driver()
	assert_gt(ai.speed_control(20.0, 10.0, DT), 0.0, "below target -> throttle")
	assert_lt(ai.speed_control(10.0, 20.0, DT), 0.0, "above target -> brake")
	assert_eq(ai.speed_control(20.0, 20.1, DT), 0.0, "inside the dead band -> coast")
	var st := DriverInputState.new()
	for e in range(-10, 11):
		var u := ai.speed_control(15.0, 15.0 + e, DT)
		st.throttle = maxf(u, 0.0)
		st.brake = maxf(-u, 0.0)
		assert_eq(minf(st.throttle, st.brake), 0.0, "never both pedals (error %d)" % e)


func test_step_never_outputs_both_pedals() -> void:
	var ai := _driver()
	var st := DriverInputState.new()
	var worst := 0.0
	for i in 600:
		var speed := 5.0 + 30.0 * absf(sin(float(i) * 0.02))
		ai.step(Vector3(float(i) * 0.1 - 30.0, 0, 0), Vector3(1, 0, 0), speed, 0.0, DT, st)
		worst = maxf(worst, minf(st.throttle, st.brake))
	assert_lte(worst, 0.1)


func test_slip_over_target_cuts_throttle_and_counter_steers() -> void:
	# Straight, slow versus target -> full throttle when the tail is in line.
	var base := _driver()
	var s0 := DriverInputState.new()
	for i in 120:
		base.step(Vector3(0, 0, 0), Vector3(1, 0, 0), 12.0, 0.0, DT, s0)
	assert_gt(s0.throttle, 0.9, "control: full throttle without slip")
	assert_lt(absf(s0.steer), 1e-3, "control: no steering without slip")
	for slip in [14.0, -14.0]:
		var ai := _driver()
		var st := DriverInputState.new()
		for i in 120:
			ai.step(Vector3(0, 0, 0), Vector3(1, 0, 0), 12.0, slip, DT, st)
		assert_true(ai.slip_active, "slip %.0f deg is over the slip target" % slip)
		assert_lt(st.throttle, s0.throttle * 0.5, "throttle reduced at slip %.0f" % slip)
		assert_eq(signf(st.steer), signf(slip), "counter-steer toward the slide (SteeringFilter convention) at %.0f" % slip)
	# Below the target nothing changes.
	var calm := _driver()
	var sc := DriverInputState.new()
	for i in 120:
		calm.step(Vector3(0, 0, 0), Vector3(1, 0, 0), 12.0, calm.slip_target_deg - 2.0, DT, sc)
	assert_false(calm.slip_active)
	assert_almost_eq(sc.throttle, s0.throttle, 1e-4)


func test_telemetry_rows_per_tick_when_enabled() -> void:
	var ai := AiDriver.new()
	ai.setup(_line(), 50)
	ai.telemetry_enabled = true
	var st := DriverInputState.new()
	for i in 10:
		ai.step(Vector3(0, 0, 0), Vector3(1, 0, 0), 12.0, 0.0, DT, st)
	assert_eq(ai.telemetry_rows, 10)
	var lines := ai.telemetry_csv().split("\n", false)
	assert_eq(lines.size(), 11, "header + 10 rows")
	assert_eq(lines[0].split(",").size(), AiDriver.COLS.size())
	var off := AiDriver.new()
	off.setup(_line(), 50)
	off.step(Vector3(0, 0, 0), Vector3(1, 0, 0), 12.0, 0.0, DT, st)
	assert_eq(off.telemetry_rows, 0, "disabled by default")


func test_ai_source_only_reads_the_vehicle() -> void:
	# Same-physics pillar: the AI path has no writes to body/wheel/tyre state and no grip or power
	# multipliers. Textual guard on the driver and its debug draw.
	var banned := RegEx.new()
	banned.compile("(?:\\bv|vehicle|wheels\\[\\d\\]|\\bw)\\.(?:linear_velocity|angular_velocity|global_transform|global_position|position|mass|inertia|steer_angle|brake_torque|drive_torque|omega|alpha|kappa|fz|tire_params|surface_map|powertrain|steer|throttle|brake|handbrake|definition|gravity_scale)\\s*[-+*/]?=[^=]")
	var calls := RegEx.new()
	calls.compile("\\.(?:apply_force|apply_impulse|apply_central_force|apply_central_impulse|apply_torque|apply_input|set_car|reset_dynamics)\\(|grip_mult|power_mult|tire_mu\\s*[*]|friction_scale")
	assert_not_null(banned.search("v.linear_velocity = Vector3.ZERO"), "control: the guard flags a velocity write")
	assert_not_null(banned.search("vehicle.steer += 0.1"), "control: the guard flags a steer write")
	assert_not_null(calls.search("v.apply_central_force(f)"), "control: the guard flags a force call")
	for path in ["res://ai/ai_driver.gd", "res://ai/ai_driver_debug.gd"]:
		var src := FileAccess.get_file_as_string(path)
		assert_true(src.length() > 100, "%s readable" % path)
		for line in src.split("\n"):
			var code := line.split("##")[0]
			assert_null(banned.search(code), "%s writes vehicle state: %s" % [path, line])
			assert_null(calls.search(code), "%s calls a physics mutator: %s" % [path, line])


func test_racing_line_index_accessors_match_queries() -> void:
	var line := _line()
	for at in [0.0, 13.7, 399.9, 400.0, 812.3, 1500.0, -20.0]:
		var i := line.sample_index(at)
		var f := line.sample_frac(i, at)
		assert_almost_eq(line.target_speed_at_index(i, f), line.target_speed_at(at), 1e-5)
		assert_true(line.point_at_index(i, f).is_equal_approx(line.point_at(at)))


func test_step_memory_flat_with_telemetry() -> void:
	var ai := AiDriver.new()
	ai.setup(_line(), 800)
	ai.telemetry_enabled = true
	var st := DriverInputState.new()
	for i in 60:
		ai.step(Vector3(float(i) * 0.2, 0, -1), Vector3(1, 0, 0), 20.0, 3.0, DT, st)
	var before := Performance.get_monitor(Performance.MEMORY_STATIC)
	for i in 600:
		ai.step(Vector3(12.0 + float(i) * 0.2, 0, -1), Vector3(1, 0, 0), 20.0, 3.0, DT, st)
	assert_lt(Performance.get_monitor(Performance.MEMORY_STATIC) - before, 64 * 1024, "no per-tick allocation growth")


func test_range_compensation_gives_the_pursuit_wheel_angle_at_speed() -> void:
	# 1 m off the line at 100 km/h: the settled steer is the pursuit command divided by the
	# filter's speed range (#171), i.e. ~1/range_scale times the uncompensated one.
	var speed := 100.0 / 3.6
	var on := _driver()
	var off := _driver()
	off.range_compensation = false
	var st_on := DriverInputState.new()
	var st_off := DriverInputState.new()
	for i in 240:
		on.step(Vector3(0, 0, -1), Vector3(1, 0, 0), speed, 0.0, DT, st_on)
		off.step(Vector3(0, 0, -1), Vector3(1, 0, 0), speed, 0.0, DT, st_off)
	assert_gt(st_off.steer, 0.0)
	assert_almost_eq(st_on.steer / st_off.steer, 1.0 / SteeringFilter.range_scale(speed * 3.6), 0.02)


func test_grip_throttle_cap_is_a_friction_ellipse() -> void:
	var ai := _driver()
	assert_almost_eq(ai.grip_throttle_cap(0.0), minf(ai.grip_a_max / ai.grip_accel_ref, 1.0), 1e-6, "no lateral demand: the whole budget drives")
	assert_eq(ai.grip_throttle_cap(ai.grip_a_max), 0.0, "grip used up by cornering: no throttle")
	assert_eq(ai.grip_throttle_cap(ai.grip_a_max * 2.0), 0.0)
	var prev := 2.0
	for i in 17:
		var c := ai.grip_throttle_cap(float(i) * 0.5)
		assert_true(c <= prev + 1e-9, "monotone non-increasing in lateral demand")
		prev = c


func test_grip_cap_limits_throttle_but_never_the_brake() -> void:
	var ai := _driver()
	ai.lateral_accel = ai.grip_a_max # the tyres are fully used laterally
	var st := DriverInputState.new()
	for i in 120:
		ai.step(Vector3(12.0 + float(i) * 0.2, 0, -1), Vector3(1, 0, 0), 5.0, 0.0, DT, st)
	assert_eq(st.throttle, 0.0, "throttle cut when no grip is left")
	for i in 120:
		ai.step(Vector3(12.0 + float(i) * 0.2, 0, -1), Vector3(1, 0, 0), 60.0, 0.0, DT, st)
	assert_gt(st.brake, 0.0, "braking is not capped by the lateral demand")
