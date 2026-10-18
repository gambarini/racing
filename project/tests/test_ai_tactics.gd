extends GutTest
## AI tactics (#29), pure logic: lane offset (rate limit, clamp, look-point shift), the race
## manager's proximity query (ahead / behind / wrap / lateral), the seeded joker lap and the
## allocation-free tick.

const DT := 1.0 / 120.0
const MEM_SLACK := 64 * 1024

var _track: TrackSpline


func before_each() -> void:
	_track = TrackSpline.make_circle(100.0, 8)
	add_child_autofree(_track)


## Same rectangle as test_ai_driver: +X along the south edge, right of travel = +Z.
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


func _run(ai: AiDriver, ticks: int, st: DriverInputState, pos := Vector3.ZERO) -> void:
	for i in ticks:
		ai.step(pos, Vector3(1, 0, 0), 15.0, 0.0, DT, st)


func test_lane_offset_is_rate_limited() -> void:
	var ai := _driver()
	var st := DriverInputState.new()
	ai.lane_target = 3.0
	var prev := 0.0
	var worst := 0.0
	for i in 400:
		ai.step(Vector3.ZERO, Vector3(1, 0, 0), 15.0, 0.0, DT, st)
		worst = maxf(worst, absf(ai.lane_now - prev) / DT)
		prev = ai.lane_now
	assert_almost_eq(worst, ai.lane_rate, 1e-3, "lane moves at the rate limit, never faster")
	assert_almost_eq(ai.lane_now, 3.0, 1e-4, "and reaches the target")
	# 3 m at 1.5 m/s takes 2 s
	var ai2 := _driver()
	ai2.lane_target = 3.0
	_run(ai2, 239, st)
	assert_lt(ai2.lane_now, 3.0, "not there before 2 s")
	_run(ai2, 3, st)
	assert_almost_eq(ai2.lane_now, 3.0, 1e-3, "there after 2 s")


func test_lane_offset_is_clamped_to_the_road() -> void:
	var ai := _driver()
	var st := DriverInputState.new()
	ai.lane_target = 20.0
	_run(ai, 600, st)
	assert_almost_eq(ai.lane_now, ai.road_half - ai.car_margin, 1e-4, "road half-width minus the car margin")
	ai.lane_target = -20.0
	_run(ai, 1200, st)
	assert_almost_eq(ai.lane_now, -(ai.road_half - ai.car_margin), 1e-4, "same on the left")


func test_lane_offset_moves_the_look_point_to_the_right() -> void:
	var ai := _driver()
	var st := DriverInputState.new()
	_run(ai, 10, st)
	var z0 := ai.look_point.z
	ai.lane_target = 3.0
	_run(ai, 300, st)
	assert_almost_eq(ai.look_point.z - z0, 3.0, 0.05, "right of travel (+Z here) by the offset")


func test_lane_error_is_zero_when_on_the_offset_line() -> void:
	var ai := _driver()
	var st := DriverInputState.new()
	ai.lane_target = 2.0
	_run(ai, 300, st, Vector3(0, 0, 2.0)) # car sits exactly 2 m right of the line
	assert_almost_eq(ai.lane_error, 0.0, 0.05)


func _mgr(cars: int) -> RaceManager:
	var mgr := RaceManager.new()
	mgr.setup(_track, 4)
	add_child_autofree(mgr)
	mgr.set_physics_process(false)
	for i in cars:
		mgr.add_car(null)
	return mgr


func _at(s: float, lat: float) -> Vector3:
	var f := _track.forward_at(s)
	return _track.position_at(s) + Vector3(-f.z, 0.0, f.x) * lat


func test_query_finds_nearest_ahead_and_behind_with_lateral() -> void:
	var mgr := _mgr(4)
	var pos := PackedVector3Array([_at(100.0, 0.5), _at(130.0, 1.0), _at(60.0, -2.0), _at(160.0, 0.0)])
	var spd := PackedFloat32Array([30.0, 28.0, 31.0, 20.0])
	mgr.step(pos, spd)
	var p := Proximity.new()
	mgr.query(0, p)
	assert_eq(p.ahead, 1, "nearest ahead is car 1, not car 3")
	assert_almost_eq(p.ahead_gap, 30.0, 0.5)
	assert_almost_eq(p.ahead_lat, 1.0, 0.1)
	assert_almost_eq(p.ahead_speed, 28.0, 1e-3)
	assert_almost_eq(p.ahead_gap_s, p.ahead_gap / 30.0, 1e-3, "gap in seconds at own speed")
	assert_eq(p.behind, 2)
	assert_almost_eq(p.behind_gap, 40.0, 0.5)
	assert_almost_eq(p.behind_lat, -2.0, 0.1)
	assert_almost_eq(p.behind_gap_s, p.behind_gap / 31.0, 1e-3, "behind gap in seconds at the follower's speed")
	assert_almost_eq(p.own_lat, 0.5, 0.1)


func test_query_wraps_at_the_lap_line_and_respects_range() -> void:
	var mgr := _mgr(2)
	var l := _track.length()
	var pos := PackedVector3Array([_at(l - 10.0, 0.0), _at(8.0, 0.0)])
	mgr.step(pos, PackedFloat32Array([20.0, 20.0]))
	var p := Proximity.new()
	mgr.query(0, p)
	assert_eq(p.ahead, 1, "a car just past the start line is ahead across the wrap")
	assert_almost_eq(p.ahead_gap, 18.0, 0.5)
	assert_eq(p.behind, -1, "nobody within range behind")
	mgr.query(0, p, 10.0, 10.0)
	assert_eq(p.ahead, -1, "outside the requested range")
	mgr.retire(1)
	mgr.query(0, p)
	assert_eq(p.ahead, -1, "retired cars are ignored")


func test_joker_lap_is_seeded() -> void:
	var mgr := _mgr(2)
	var a := AiTactics.new()
	var b := AiTactics.new()
	var seen := {}
	for sd in 40:
		a.setup(mgr, 0, sd)
		b.setup(mgr, 0, sd)
		a.pick_joker_lap(2, 5)
		b.pick_joker_lap(2, 5)
		assert_eq(a.joker_pref_lap, b.joker_pref_lap, "same seed, same lap (seed %d)" % sd)
		assert_between(a.joker_pref_lap, 2, 5)
		seen[a.joker_pref_lap] = true
	assert_gt(seen.size(), 1, "different seeds do not all pick the same lap")
	a.setup(mgr, 0, 3)
	b.setup(mgr, 1, 3)
	a.pick_joker_lap(2, 5)
	b.pick_joker_lap(2, 5)
	var same_car := true
	for sd in 40:
		a.setup(mgr, 0, sd)
		b.setup(mgr, 1, sd)
		a.pick_joker_lap(2, 5)
		b.pick_joker_lap(2, 5)
		same_car = same_car and a.joker_pref_lap == b.joker_pref_lap
	assert_false(same_car, "the car id is part of the seed")


func test_tactics_tick_is_allocation_free() -> void:
	var mgr := _mgr(4)
	var ai := _driver()
	ai.attach_tactics(mgr, 0, 1)
	var st := DriverInputState.new()
	var pos := PackedVector3Array([_at(100.0, 0.0), _at(125.0, 0.0), _at(75.0, 1.0), _at(300.0, 0.0)])
	var spd := PackedFloat32Array([30.0, 5.0, 31.0, 30.0])
	for i in 60: # warm up
		mgr.step(pos, spd)
		ai.step(Vector3.ZERO, Vector3(1, 0, 0), 30.0, 0.0, DT, st)
	var before := Performance.get_monitor(Performance.MEMORY_STATIC)
	for i in 600:
		mgr.step(pos, spd)
		ai.step(Vector3.ZERO, Vector3(1, 0, 0), 30.0, 0.0, DT, st)
	assert_lt(Performance.get_monitor(Performance.MEMORY_STATIC) - before, MEM_SLACK)
