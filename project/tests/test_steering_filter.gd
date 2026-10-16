extends GutTest
## Pure SteeringFilter math tables (issue #13).

const DT := 1.0 / 120.0


func test_deadzone_edges() -> void:
	assert_almost_eq(SteeringFilter.deadzone(0.1), 0.0, 0.0001)
	assert_almost_eq(SteeringFilter.deadzone(0.15), 0.0, 0.0001)
	assert_almost_eq(SteeringFilter.deadzone(1.0), 1.0, 0.0001)
	assert_almost_eq(SteeringFilter.deadzone(-1.0), -1.0, 0.0001)
	assert_almost_eq(SteeringFilter.deadzone(0.575), 0.5, 0.0001)


func test_shape_stick_matches_formula() -> void:
	assert_almost_eq(SteeringFilter.shape_stick(0.1), 0.0, 0.001)
	assert_almost_eq(SteeringFilter.shape_stick(1.0), 1.0, 0.001)
	assert_almost_eq(SteeringFilter.shape_stick(0.575), pow(0.5, 1.5), 0.001)
	assert_almost_eq(SteeringFilter.shape_stick(-0.575), -pow(0.5, 1.5), 0.001)


func test_config_ranges_are_clamped() -> void:
	assert_almost_eq(SteeringFilter.deadzone(0.5, 0.9), (0.5 - 0.4) / 0.6, 0.0001)
	assert_almost_eq(SteeringFilter.curve(0.5, 9.0), pow(0.5, 3.0), 0.0001)
	assert_almost_eq(SteeringFilter.curve(0.5, 0.2), 0.5, 0.0001)


func test_range_scale_table() -> void:
	assert_almost_eq(SteeringFilter.range_scale(0.0), 1.0, 0.0001)
	assert_almost_eq(SteeringFilter.range_scale(75.0), 0.675, 0.0001)
	assert_almost_eq(SteeringFilter.range_scale(150.0), 0.35, 0.0001)
	assert_almost_eq(SteeringFilter.range_scale(200.0), 0.35, 0.0001)


func test_rate_limit_endpoints() -> void:
	assert_almost_eq(SteeringFilter.rate_limit(0.0), 6.0, 0.0001)
	assert_almost_eq(SteeringFilter.rate_limit(150.0), 2.5, 0.0001)
	assert_almost_eq(SteeringFilter.rate_limit(300.0), 2.5, 0.0001)


func _ticks_to_reach(from: float, target: float, speed: float, goal: float) -> int:
	var v := from
	var n := 0
	while absf(v - goal) > 1e-6 and n < 1000:
		v = SteeringFilter.step_steer(v, target, DT, speed)
		n += 1
	return n


func test_step_from_zero_to_full_takes_one_sixth_second() -> void:
	var n := _ticks_to_reach(0.0, 1.0, 0.0, 1.0)
	assert_almost_eq(float(n) * DT, 1.0 / 6.0, DT * 1.01)


func test_return_to_centre_time() -> void:
	var t := float(_ticks_to_reach(1.0, 0.0, 0.0, 0.0)) * DT
	assert_between(t, 0.15 - DT, 0.3)


func test_pedal_ramp() -> void:
	var v := 0.0
	var n := 0
	while v < 1.0 and n < 1000:
		v = SteeringFilter.ramp(v, 1.0, DT, 7.0, 10.0)
		n += 1
	assert_between(float(n) * DT, 0.1, 0.2)


func test_trigger_deadzone() -> void:
	assert_eq(SteeringFilter.shape_trigger(0.04), 0.0)
	assert_eq(SteeringFilter.shape_trigger(0.05), 0.0)
	assert_almost_eq(SteeringFilter.shape_trigger(1.0), 1.0, 0.0001)
	assert_almost_eq(SteeringFilter.shape_trigger(0.525), 0.5, 0.0001)


func test_assist_off_is_identity() -> void:
	for slip in [-30.0, -9.0, 0.0, 5.0, 12.0, 40.0]:
		for steer in [-1.0, -0.4, 0.0, 0.3, 1.0]:
			var out := SteeringFilter.counter_steer_assist(steer, slip, false)
			assert_eq(out["steer"], steer)
			assert_false(out["active"])


func test_assist_below_threshold_is_identity() -> void:
	var out := SteeringFilter.counter_steer_assist(1.0, 8.0, true)
	assert_eq(out["steer"], 1.0)
	assert_false(out["active"])


func test_assist_clamps_steer_toward_slide() -> void:
	var slip := 12.0
	var limit := deg_to_rad(slip) / SteeringFilter.ASSIST_MAX_STEER_RAD
	var out := SteeringFilter.counter_steer_assist(1.0, slip, true)
	assert_almost_eq(out["steer"], limit, 0.0001)
	assert_true(out["active"])
	# Mirror: negative slide, negative (toward) steer.
	out = SteeringFilter.counter_steer_assist(-1.0, -slip, true)
	assert_almost_eq(out["steer"], -limit, 0.0001)
	assert_true(out["active"])


func test_assist_leaves_steer_away_from_slide_and_small_steer() -> void:
	var out := SteeringFilter.counter_steer_assist(-1.0, 20.0, true)
	assert_eq(out["steer"], -1.0)
	assert_false(out["active"])
	out = SteeringFilter.counter_steer_assist(0.1, 20.0, true)
	assert_eq(out["steer"], 0.1)
	assert_false(out["active"])
