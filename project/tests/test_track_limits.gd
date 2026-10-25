extends GutTest
## Track limits (#174): TrackLimits excursion tracker, RaceManager warning/penalty wiring and the
## wheel-vs-road-edge geometry on a circular test track. Deterministic: step() with computed
## positions, no physics.

const DT := 1.0 / 120.0
const HALF := 6.5

var _track: TrackSpline
var _mgr: RaceManager
var _pos := PackedVector3Array()
var _spd := PackedFloat32Array()
var _s := 0.0


func before_each() -> void:
	_track = TrackSpline.make_circle(100.0, 8)
	_track.road_half_width = HALF
	add_child_autofree(_track)
	_mgr = RaceManager.new()
	add_child_autofree(_mgr)
	_mgr.setup(_track, 1)
	_mgr.joker_required = false
	_pos = PackedVector3Array()
	_spd = PackedFloat32Array()
	for i in 2:
		_mgr.add_car()
		_pos.append(Vector3.ZERO)
		_spd.append(0.0)
	_s = 20.0
	_place(0.0)
	_mgr.start_countdown()
	var guard := 0
	while _mgr.state != RaceManager.State.RACING and guard < 1000:
		_mgr.step(_pos, _spd)
		guard += 1
	assert_eq(_mgr.state, RaceManager.State.RACING)


func _place(lat: float) -> void:
	var fwd := _track.forward_at(_s)
	var p := _track.position_at(_s) + fwd.cross(Vector3.UP) * lat
	_pos[0] = p
	_pos[1] = p


## Run `seconds` of ticks with car 0 wheels_off = n (scripted).
func _run(n: int, seconds: float) -> void:
	_mgr.set_wheels_off(0, n)
	for i in int(round(seconds / DT)):
		_mgr.step(_pos, _spd)


func _penalties(car := 0) -> Array:
	return _mgr.ledger.filter(func(e: Dictionary) -> bool: return e["car"] == car and e["reason"] == &"track_limits")


func _scripted_wheels() -> void:
	_mgr.set_wheel_positions(0, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)


## Car centre at lateral `lat` (+ = right), wheels +/-0.9 m across and +/-1.3 m along.
func _place_wheels(lat: float) -> void:
	_place(lat)
	var fwd := _track.forward_at(_s)
	var right := fwd.cross(Vector3.UP)
	var k := 0
	for sgn in [-0.9, 0.9]:
		for lon in [-1.3, 1.3]:
			_mgr.wheel_pos[k] = _pos[0] + right * sgn + fwd * lon
			k += 1


func test_first_excursion_warns_only() -> void:
	var warns: Array[int] = []
	_mgr.track_limit_warning.connect(func(c: int) -> void: warns.append(c))
	_run(4, 1.0)
	_run(0, 1.0)
	assert_eq(warns, [0] as Array[int], "one warning for car 0")
	assert_eq(_mgr.ledger.size(), 0, "no ledger entry")
	assert_eq(_mgr.limit_violations[0], 1)


func test_second_and_third_excursions_penalised() -> void:
	var warns: Array[int] = []
	_mgr.track_limit_warning.connect(func(c: int) -> void: warns.append(c))
	for k in 3:
		_run(4, 1.0)
		_run(1, 0.6)  # >= 0.5 s with a wheel on the road
	assert_eq(warns.size(), 1, "warning only once")
	var pen := _penalties()
	assert_eq(pen.size(), 2, "second and third excursion each add one entry")
	for e in pen:
		assert_eq(e["seconds"], 2.0)
	assert_eq(_mgr.penalty_seconds[0], 4.0)
	assert_eq(_penalties(1).size(), 0, "other car untouched")


func test_partial_excursions_never_count() -> void:
	for n in [1, 2, 3]:
		_run(n, 3.0)
		_run(0, 1.0)
	assert_eq(_mgr.limit_violations[0], 0)
	assert_eq(_mgr.ledger.size(), 0)


func test_flicker_is_one_excursion() -> void:
	for k in 8:
		_run(4, 0.2)
		_run(2, 0.3)  # shorter than 0.5 s back on track
	assert_eq(_mgr.limit_violations[0], 1, "flicker = one excursion")
	assert_eq(_mgr.ledger.size(), 0)
	_run(2, 0.5)  # exactly the debounce re-arms
	_run(4, 0.1)
	assert_eq(_mgr.limit_violations[0], 2)
	assert_eq(_penalties().size(), 1)


func test_short_return_does_not_rearm() -> void:
	_run(4, 0.5)
	_run(3, 0.49)
	_run(4, 0.5)
	assert_eq(_mgr.limit_violations[0], 1)


func test_geometry_wheels_vs_road_edge() -> void:
	_scripted_wheels()
	for lat in [0.0, 5.0, 6.0, 7.0, 8.2, -7.0]:
		_place_wheels(lat)
		_mgr.step(_pos, _spd)
		var want := 0
		for sgn in [-0.9, 0.9]:
			if absf(lat + sgn) > HALF:
				want += 2
		assert_eq(_mgr.wheels_off[0], want, "centre lateral %.1f" % lat)


func test_geometry_four_wheels_off_triggers() -> void:
	_scripted_wheels()
	_place_wheels(8.0)
	for i in 120:
		_mgr.step(_pos, _spd)
	assert_eq(_mgr.wheels_off[0], 4)
	assert_eq(_mgr.limit_violations[0], 1)
	_place_wheels(0.0)
	for i in 120:
		_mgr.step(_pos, _spd)
	_place_wheels(-8.0)
	for i in 30:
		_mgr.step(_pos, _spd)
	assert_eq(_mgr.limit_violations[0], 2, "left side counts too")
	assert_eq(_penalties().size(), 1)


func test_joker_curve_is_legal_ground() -> void:
	var jc := Curve3D.new()
	jc.bake_interval = 1.0
	for a in range(0, 40):  # arc 15 m outside the main circle (r = 115 m)
		var ang := deg_to_rad(10.0 + a)
		jc.add_point(Vector3(115.0 * cos(ang), 0.0, -115.0 * sin(ang)))
	_track.joker_curve = jc
	_track.joker_road_half = 5.0
	_scripted_wheels()
	_s = _track.nearest_offset(Vector3(115.0 * cos(deg_to_rad(30.0)), 0.0, -115.0 * sin(deg_to_rad(30.0))))
	_place_wheels(15.0)
	for i in 120:
		_mgr.step(_pos, _spd)
	assert_eq(_mgr.wheels_off[0], 0, "on the joker road")
	assert_eq(_mgr.limit_violations[0], 0)
	_place_wheels(25.0)  # beyond the joker edge
	for i in 60:
		_mgr.step(_pos, _spd)
	assert_eq(_mgr.wheels_off[0], 4)


func test_disabled_without_road_width() -> void:
	_track.road_half_width = 0.0
	_scripted_wheels()
	_place_wheels(30.0)
	for i in 120:
		_mgr.step(_pos, _spd)
	assert_eq(_mgr.limit_violations[0], 0)


func test_penalty_goes_to_result_time_laps_stay_raw() -> void:
	var res: Array = []
	_mgr.race_finished.connect(func(r: Array) -> void: res.assign(r))
	var warns := [0]
	_mgr.track_limit_warning.connect(func(_c: int) -> void: warns[0] += 1)
	_mgr.finish_grace_seconds = 0.5
	var step_s := 40.0 * DT
	var ticks := 0
	var plan := {200: 4, 260: 0, 400: 4, 460: 0, 600: 4, 660: 0}  # three excursions of 0.5 s
	_s = -2.0
	var n := 0
	while _mgr.state == RaceManager.State.RACING and n < 120 * 40:
		_s += step_s
		_place(0.0)
		_pos[1] = _track.position_at(_s - 30.0)
		if plan.has(ticks):
			_mgr.set_wheels_off(0, plan[ticks])
		_spd[0] = 40.0
		_spd[1] = 30.0
		_mgr.step(_pos, _spd)
		ticks += 1
		n += 1
	assert_eq(warns[0], 1)
	assert_eq(_penalties().size(), 2)
	assert_eq(res.size(), 2)
	var row: Dictionary = res.filter(func(r: Dictionary) -> bool: return r["car"] == 0)[0]
	assert_almost_eq(row["time"], row["race_time"] + 4.0, 1e-6, "result = race time + ledger")
	assert_almost_eq(row["penalties"], 4.0, 1e-9)
	assert_almost_eq(row["best_lap"], row["race_time"], 0.2, "lap record stays raw")
