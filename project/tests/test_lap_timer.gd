extends GutTest
## Track spline gates and LapTimer: ordering, lap/sector timing, joker (issue #105).

const DT := 1.0 / 120.0
const R := 100.0
const SPEED := 40.0  ## m/s, so ~16 s per lap and ~5 m per tick

var track: TrackSpline


func before_each() -> void:
	track = TrackSpline.make_circle(R, 8)
	track.gate_half_width = 20.0
	add_child_autofree(track)


func _point(angle: float, radius: float = R) -> Vector3:
	return Vector3(radius * cos(angle), 0.0, -radius * sin(angle))


## Drive `laps` laps starting just behind the line. `joker_lap` detours inside the joker gate.
func _drive(timer: LapTimer, laps: int, start_ticks_idle := 3, joker_lap := -1) -> void:
	var step_angle := SPEED * DT / R
	var a := -0.05
	for i in start_ticks_idle:
		timer.step(_point(a))
	var end := TAU * laps + 0.05
	while a < end:
		a += step_angle
		var lap := int(floor(a / TAU))
		var rad := R
		if lap == joker_lap and fposmod(a, TAU) > 1.2 and fposmod(a, TAU) < 2.2:
			rad = R - 12.0
		timer.step(_point(a, rad))


func test_spline_exposes_centre_line_gates_grid() -> void:
	assert_true(track.is_valid())
	assert_gte(track.gate_count(), 8)
	assert_eq(track.sector_count(), 3)
	assert_gt(track.length(), 600.0)
	var g := track.build_gates()
	assert_eq(g.size(), 8)
	# Gate 0 at start (r, 0, 0), facing -Z.
	assert_almost_eq(g[0].position.x, R, 0.5)
	assert_gt(g[0].forward.dot(Vector3(0, 0, -1)), 0.99)
	var t0 := track.grid_transform(0)
	var t1 := track.grid_transform(1)
	assert_gt(t0.origin.z, 0.0, "pole behind line (+Z)")
	assert_gt(t1.origin.z, t0.origin.z, "slot 1 further back")
	assert_gt((-t0.basis.z).dot(Vector3(0, 0, -1)), 0.95)


func test_two_laps_counted_and_sectors_sum() -> void:
	var timer := track.make_lap_timer(DT)
	_drive(timer, 2)
	assert_eq(timer.laps.size(), 2, "two laps")
	for rec in timer.laps:
		assert_eq(rec["sector_ticks"].size(), 3)
		var sum := 0
		for s in rec["sector_ticks"]:
			sum += s
		assert_eq(sum, rec["ticks"], "sector ticks sum to lap ticks")
		var tsum := 0.0
		for s in rec["sector_times"]:
			tsum += s
		assert_almost_eq(tsum, rec["time"], 1e-6)
		assert_false(rec["joker"])
		# 2 pi R / v = 15.7 s
		assert_almost_eq(rec["time"], TAU * R / SPEED, 0.1)
	assert_eq(timer.out_of_order_crossings, 0)


func test_skipping_a_gate_does_not_count_lap() -> void:
	# Remove gate 4 from the course the car checks: car drives full circle but gate 4 is
	# displaced laterally out of reach, so its crossing is missed.
	var gates := track.build_gates()
	gates[4].position += Vector3(0, 0, 0) + gates[4].forward.cross(Vector3.UP) * 80.0
	var timer := LapTimer.new(gates, [3, 6] as Array[int], null, DT)
	_drive(timer, 2)
	assert_eq(timer.laps.size(), 0, "missed gate: no lap")


func test_reverse_direction_counts_nothing() -> void:
	var timer := track.make_lap_timer(DT)
	var a := 0.05
	var step_angle := SPEED * DT / R
	while a > -TAU * 2.0:
		timer.step(_point(a))
		a -= step_angle
	assert_eq(timer.laps.size(), 0)


func test_out_of_order_crossing_ignored() -> void:
	var timer := track.make_lap_timer(DT)
	# Start the lap, then teleport to just before gate 5 and cross it, then back to the line.
	timer.step(_point(-0.05))
	timer.step(_point(0.01))
	assert_true(timer.running)
	assert_eq(timer.next_gate, 1)
	var a5 := TAU * 5.0 / 8.0
	timer.step(_point(a5 - 0.05))  # teleport
	timer.step(_point(a5 + 0.05))  # crosses gate 5 out of order
	assert_gte(timer.out_of_order_crossings, 1)
	assert_eq(timer.next_gate, 1)
	timer.step(_point(-0.05))
	timer.step(_point(0.01))  # crosses gate 0 early: must not finish a lap
	assert_eq(timer.laps.size(), 0)


func test_in_order_gives_exactly_one_lap_per_circuit() -> void:
	var timer := track.make_lap_timer(DT)
	_drive(timer, 1)
	assert_eq(timer.laps.size(), 1)
	assert_eq(timer.laps[0]["lap"], 1)


func test_joker_flags_only_the_lap_that_takes_it() -> void:
	track.has_joker = true
	var s := track.sample(track.length() * 1.7 / TAU)  # angle 1.7 rad
	track.joker_position = track.to_local(_point(1.7, R - 12.0))
	track.joker_forward = Vector3(-sin(1.7), 0, -cos(1.7))
	var timer := track.make_lap_timer(DT)
	assert_not_null(timer.joker_gate)
	assert_not_null(s)
	_drive(timer, 3, 3, 1)  # lap index 1 (second lap) detours
	assert_eq(timer.laps.size(), 3)
	assert_false(timer.laps[0]["joker"])
	assert_true(timer.laps[1]["joker"])
	assert_false(timer.laps[2]["joker"])


func test_standing_start_lap1_timed_from_signal() -> void:
	var timer := track.make_lap_timer(DT)
	timer.start_standing()  # signal at t=0, car idle behind the line
	var step_angle := SPEED * DT / R
	var a := -0.05
	var crossed_tick := 0
	for i in int(3.0 / DT):
		timer.step(_point(a))
	while a < TAU + 0.05:
		a += step_angle
		timer.step(_point(a))
		if crossed_tick == 0 and a > 0.0:
			crossed_tick = timer.tick
	assert_eq(timer.laps.size(), 1, "one lap closed")
	assert_eq(timer.out_of_order_crossings, 0, "grid-to-line crossing is not out of order")
	var first: int = timer.laps[0]["ticks"]
	assert_gt(first, int(3.0 / DT) + int(14.0 / DT), "lap 1 includes the 3 s before the line")
	assert_lt(first, int((3.0 + 17.0) / DT))
	assert_eq(timer.laps[0]["sector_ticks"].size(), 3)


func test_standing_start_lap2_is_gate_to_gate() -> void:
	var timer := track.make_lap_timer(DT)
	timer.start_standing()
	_drive(timer, 3)
	assert_eq(timer.laps.size(), 3)
	assert_gt(timer.laps[0]["ticks"], timer.laps[1]["ticks"], "lap 1 includes grid time")
	var flying := track.make_lap_timer(DT)
	_drive(flying, 3)
	assert_eq(timer.laps[1]["ticks"], flying.laps[1]["ticks"], "lap 2 = gate-0 to gate-0")
	assert_eq(timer.laps[2]["ticks"], flying.laps[2]["ticks"])


## Drive a standing-start timer (after `start_standing()`) from `start_angle` round the circle to `end_angle`.
func _drive_standing(timer: LapTimer, start_angle: float, end_angle: float, idle := 3) -> void:
	timer.start_standing()
	var step_angle := SPEED * DT / R
	var a := start_angle
	for i in idle:
		timer.step(_point(a))
	while a < end_angle:
		a += step_angle
		timer.step(_point(a))


## Like `_drive_standing` but the caller has already called `start_standing()`.
func _drive_standing_noreset(timer: LapTimer, start_angle: float, end_angle: float) -> void:
	var step_angle := SPEED * DT / R
	var a := start_angle
	timer.step(_point(a))
	while a < end_angle:
		a += step_angle
		timer.step(_point(a))


func test_standing_start_grid_past_line_gate1_first() -> void:
	var timer := track.make_lap_timer(DT)
	timer.start_standing()  # tick 0
	var step_angle := SPEED * DT / R
	var a := 0.1  # past gate 0: gate 1 is crossed first
	var close_tick := -1  # -1 = lap not closed yet
	timer.step(_point(a))
	while a < TAU + 0.05:
		a += step_angle
		timer.step(_point(a))
		if close_tick < 0 and timer.laps.size() == 1:
			close_tick = timer.tick
	assert_eq(timer.laps.size(), 1, "gate 0 closes the lap, not swallowed")
	assert_eq(timer.out_of_order_crossings, 0)
	assert_eq(timer.laps[0]["ticks"], close_tick, "lap ticks = gate-0 tick minus start tick (0)")
	var sum := 0
	for st in timer.laps[0]["sector_ticks"]:
		sum += st
	assert_eq(sum, timer.laps[0]["ticks"])


func test_standing_start_normal_grid_single_lap_and_two_laps() -> void:
	var timer := track.make_lap_timer(DT)
	_drive_standing(timer, -0.05, TAU + 0.05)
	assert_eq(timer.laps.size(), 1)
	assert_eq(timer.out_of_order_crossings, 0)
	var t2 := track.make_lap_timer(DT)
	_drive_standing(t2, -0.05, 2.0 * TAU + 0.05)
	assert_eq(t2.laps.size(), 2)
	for lap in t2.laps:
		var s := 0
		for st in lap["sector_ticks"]:
			s += st
		assert_eq(s, lap["ticks"])


func test_standing_gate0_before_gate1_only_clears_grid() -> void:
	var timer := track.make_lap_timer(DT)
	timer.start_standing()
	_drive_standing_noreset(timer, -0.05, 0.3)
	assert_eq(timer.laps.size(), 0)
	assert_true(timer.running)
	assert_eq(timer.current_lap_ticks(), timer.tick, "lap start tick unchanged (0)")
