extends GutTest
## WrongWayDetector thresholds and LapTimer reset penalty (issue #106).

const DT := 1.0 / 120.0
const T := Vector3(0, 0, -1)


## Returns the 1-based tick at which the flag changed, or 0.
func _run(d: WrongWayDetector, vel: Vector3, seconds: float) -> int:
	var n := int(round(seconds / DT))
	var changed := 0
	var before := d.wrong_way
	for i in n:
		d.step(vel, T)
		if changed == 0 and d.wrong_way != before:
			changed = i + 1
	return changed


func test_set_after_two_seconds_wrong_heading() -> void:
	var d := WrongWayDetector.new(DT)
	_run(d, -T * 20.0, 1.95)
	assert_false(d.wrong_way, "not yet at 1.95 s")
	var at := _run(d, -T * 20.0, 0.1)
	assert_true(d.wrong_way)
	assert_almost_eq(at * DT + 1.95, 2.0, 2.0 * DT)


func test_correct_heading_never_flags() -> void:
	var d := WrongWayDetector.new(DT)
	_run(d, T * 20.0, 10.0)
	assert_false(d.wrong_way)


func test_brief_wrong_heading_resets_counter() -> void:
	var d := WrongWayDetector.new(DT)
	for k in 5:
		_run(d, -T * 20.0, 1.5)
		_run(d, T * 20.0, 0.1)
	assert_false(d.wrong_way, "interrupted wrong-way spells never accumulate")


func test_clears_after_half_second_correct() -> void:
	var d := WrongWayDetector.new(DT)
	_run(d, -T * 20.0, 2.5)
	assert_true(d.wrong_way)
	_run(d, T * 20.0, 0.45)
	assert_true(d.wrong_way, "still flagged before 0.5 s")
	_run(d, T * 20.0, 0.1)
	assert_false(d.wrong_way)


func test_stationary_counts_as_correct() -> void:
	var d := WrongWayDetector.new(DT)
	_run(d, -T * 20.0, 2.5)
	_run(d, Vector3.ZERO, 0.6)
	assert_false(d.wrong_way)


func test_penalty_added_only_while_running_and_in_lap_time() -> void:
	var gates: Array[Gate] = [Gate.new(Vector3.ZERO, T, 10.0)]
	var timer := LapTimer.new(gates, [], null, DT)
	timer.add_penalty(5.0)
	assert_eq(timer.penalty_ticks, 0, "ignored before the lap starts")
	timer.step(Vector3(0, 0, 1))
	timer.step(Vector3(0, 0, -1))  # crosses gate 0: lap starts
	for i in 120:
		timer.step(Vector3(0, 0, -2))
	timer.add_penalty(5.0)
	assert_eq(timer.penalty_ticks, 600)
	timer.step(Vector3(0, 0, 1))
	timer.step(Vector3(0, 0, -1))  # crosses again: lap closes
	var rec: Dictionary = timer.laps[0]
	assert_almost_eq(rec["time"], rec["raw_time"] + 5.0, 1e-6)
	assert_eq(timer.penalty_ticks, 0, "penalty does not carry into the next lap")


func test_slow_opposing_velocity_never_flags() -> void:
	var d := WrongWayDetector.new(DT)
	_run(d, -T * 2.0, 5.0)
	assert_false(d.wrong_way, "2 m/s is below the 3 m/s floor")


func test_fast_opposing_velocity_flags_at_two_seconds() -> void:
	var d := WrongWayDetector.new(DT)
	_run(d, -T * 4.0, 1.95)
	assert_false(d.wrong_way)
	_run(d, -T * 4.0, 0.1)
	assert_true(d.wrong_way)


func test_flagged_car_slowing_below_floor_clears_after_half_second() -> void:
	var d := WrongWayDetector.new(DT)
	_run(d, -T * 20.0, 2.1)
	assert_true(d.wrong_way)
	_run(d, -T * 2.0, 0.45)
	assert_true(d.wrong_way, "not yet at 0.45 s")
	_run(d, -T * 2.0, 0.1)
	assert_false(d.wrong_way, "cleared after 0.5 s below the floor")
