extends GutTest
## Time trial recording, ghost replay, validity and file round-trip (issue #25).

const DT := 1.0 / 120.0
const R := 100.0
const PATH := "user://test_ghost_best.dat"

var track: TrackSpline
var timer: LapTimer
var tt: TimeTrial


func before_each() -> void:
	_a = -0.05
	_calls = 0
	DirAccess.remove_absolute(PATH)
	track = TrackSpline.make_circle(R, 8)
	track.gate_half_width = 20.0
	add_child_autofree(track)
	timer = track.make_lap_timer(DT)
	tt = TimeTrial.new()
	tt.ghost_path = PATH
	tt.timer = timer
	tt.track_id = "circle"
	add_child_autofree(tt)


func after_all() -> void:
	DirAccess.remove_absolute(PATH)


func _point(angle: float, radius: float = R) -> Vector3:
	return Vector3(radius * cos(angle), 0.0, -radius * sin(angle))


func _xf(angle: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, angle), _point(angle))


var _a := -0.05  ## continuous angle around the circle across laps
var _calls := 0


## Drive one more lap's worth of angle at `speed` m/s (the first call also starts the clock at
## the line). `penalty` adds a reset penalty mid-lap.
func _lap(speed: float, penalty := 0.0) -> void:
	var step_angle := speed * DT / R
	_calls += 1
	var end := _calls * TAU + 0.05
	var added := false
	while _a < end:
		_a += step_angle
		timer.step(_point(_a))
		if penalty > 0.0 and not added and _a > end - 4.0:
			timer.add_penalty(penalty)
			added = true
		tt.observe(_xf(_a), 0.1, 1.0, 0.0, false)


func test_records_at_60hz_with_inputs_and_saves_best() -> void:
	_lap(40.0)  # crosses the line (starts the lap) and completes it at the next crossing
	assert_not_null(tt.best)
	var secs: float = tt.best.ticks * DT
	assert_between(secs, 14.0, 20.0)
	# 60 Hz: one sample per two ticks, plus the exact final sample.
	assert_almost_eq(float(tt.best.sample_count()), tt.best.ticks / 2.0, 2.0)
	var inp := tt.best.input_at_tick(100)
	assert_almost_eq(float(inp[0]), 0.1, 0.001)
	assert_almost_eq(float(inp[1]), 1.0, 0.001)


func test_ghost_ends_within_half_metre_of_recorded_final_position() -> void:
	_lap(40.0)
	assert_not_null(tt.best)
	var last_i := tt.best.sample_count() - 1
	var final := tt.best.pose_at_index(last_i).origin
	var replayed := tt.best.pose_at_tick(tt.best.ticks).origin
	assert_lt(replayed.distance_to(final), 0.5)
	# And the recorded final pose sits at the finish line (gate 0 at (R, 0, 0)).
	assert_lt(final.distance_to(Vector3(R, 0, 0)), 6.0)
	# Mid-lap the interpolated ghost stays on the circle.
	var mid := tt.best.pose_at_tick(tt.best.ticks / 2).origin
	assert_almost_eq(mid.length(), R, 1.0)


func test_ghost_starts_with_lap_and_follows_best() -> void:
	tt.ghost = tt._make_ghost_node()
	tt.add_child(tt.ghost)
	_lap(40.0)
	assert_not_null(tt.best)
	# The lap just restarted at the line: the ghost starts there, with the car.
	assert_true(tt.ghost.visible)
	assert_lt(tt.ghost.global_position.distance_to(_point(_a)), 6.0, "ghost starts at the line with the lap")
	var step_angle := 40.0 * DT / R
	while _a < TAU + 1.0:
		_a += step_angle
		timer.step(_point(_a))
		tt.observe(_xf(_a), 0, 1, 0, false)
	assert_lt(tt.ghost.global_position.distance_to(_point(_a)), 6.0, "equal pace: ghost stays beside the car")


func test_slower_lap_does_not_overwrite_best() -> void:
	_lap(40.0)
	var best: GhostLap = tt.best
	var ticks := best.ticks
	_lap(30.0)
	assert_same(tt.best, best)
	assert_eq(tt.best.ticks, ticks)
	_lap(50.0)
	assert_lt(tt.best.ticks, ticks, "faster lap replaces best")


func test_lap_with_reset_penalty_is_never_saved() -> void:
	_lap(40.0, 5.0)  # a reset was used
	assert_eq(timer.laps.size(), 1)
	assert_null(tt.best)
	assert_false(FileAccess.file_exists(PATH))
	_lap(40.0)
	assert_not_null(tt.best, "a clean lap after it is saved")


func test_lap_with_wrong_gate_is_never_saved() -> void:
	_calls = 1
	var step_angle := 40.0 * DT / R
	var hit := false
	while _a < TAU + 0.05:
		_a += step_angle
		timer.step(_point(_a))
		tt.observe(_xf(_a), 0, 1, 0, false)
		if not hit and _a > 2.0:
			hit = true
			# Re-cross gate 1 (already passed) in the forward direction: out-of-order crossing.
			var g := track.build_gates()[1]
			timer.teleported()
			timer.step(g.position - g.forward * 1.0)
			timer.step(g.position + g.forward * 1.0)
			timer.teleported()
	assert_gt(timer.out_of_order_crossings, 0)
	assert_eq(timer.laps.size(), 1)
	assert_null(tt.best)


func test_file_round_trip() -> void:
	_lap(40.0)
	assert_not_null(tt.best)
	assert_true(FileAccess.file_exists(PATH))
	var loaded := GhostLap.load_file(PATH)
	assert_not_null(loaded)
	assert_eq(loaded.ticks, tt.best.ticks)
	assert_eq(loaded.track_id, "circle")
	assert_eq(loaded.poses, tt.best.poses)
	assert_eq(loaded.inputs, tt.best.inputs)
	# "Restart": a fresh TimeTrial picks the file up via setup().
	var v := Vehicle.new()
	add_child_autofree(v)
	var tt2 := TimeTrial.new()
	tt2.ghost_path = PATH
	add_child_autofree(tt2)
	tt2.setup(v, track.make_lap_timer(DT), "circle")
	assert_not_null(tt2.best)
	assert_eq(tt2.best.ticks, tt.best.ticks)
	# Other track: not loaded.
	var tt3 := TimeTrial.new()
	tt3.ghost_path = PATH
	add_child_autofree(tt3)
	tt3.setup(v, track.make_lap_timer(DT), "other")
	assert_null(tt3.best)


func test_corrupt_file_loads_null() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string("garbage")
	f.close()
	assert_null(GhostLap.load_file(PATH))
	assert_null(GhostLap.load_file("user://does_not_exist.dat"))
