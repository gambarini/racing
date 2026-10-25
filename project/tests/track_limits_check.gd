## Track limits on the Quarry (#174): RaceManager with scripted cars (wheel positions derived
## against the real road edge). Car 0 drives three separate 4-wheels-off excursions (warning,
## then +2 s each); car 1 stays on the joker route (negative control, legal ground) and in the
## widened first corner; car 2 has 3 wheels off for seconds. Penalties land in the result time.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/track_limits_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const DT := 1.0 / 120.0

var cu := CheckUtil.new()
var _q: Quarry
var _mgr: RaceManager
var _pos := PackedVector3Array()
var _spd := PackedFloat32Array()


func _initialize() -> void:
	_main()


## Car `i` centre at distance `s` along the main line and lateral `lat` (+ right), wheels spread
## +/-0.9 m across and +/-1.3 m along (4 wheels), `off_wheels` = how many are pushed `shift` m outward.
func _put(i: int, s: float, lat: float) -> void:
	var t := _q.track
	var fwd := t.forward_at(s)
	var right := fwd.cross(Vector3.UP)
	var c := t.position_at(s) + right * lat
	_pos[i] = c
	var k := 0
	for sgn in [-0.9, 0.9]:
		for lon in [-1.3, 1.3]:
			_mgr.wheel_pos[i * 4 + k] = c + right * sgn + fwd * lon
			k += 1


func _put_world(i: int, c: Vector3, fwd: Vector3) -> void:
	var right := fwd.cross(Vector3.UP)
	_pos[i] = c
	var k := 0
	for sgn in [-0.9, 0.9]:
		for lon in [-1.3, 1.3]:
			_mgr.wheel_pos[i * 4 + k] = c + right * sgn + fwd * lon
			k += 1


func _run(seconds: float) -> void:
	for n in int(round(seconds / DT)):
		_mgr.step(_pos, _spd)


func _main() -> void:
	await physics_frame
	_q = (load("res://tracks/quarry/quarry.tscn") as PackedScene).instantiate()
	root.add_child(_q)
	await physics_frame
	var t := _q.track
	cu.check(t.road_half_width == Quarry.ROAD_HALF and t.joker_curve != null, "quarry exports its road edge and joker road")
	_mgr = RaceManager.new()
	_mgr.setup(t, 1)
	_mgr.joker_required = false
	root.add_child(_mgr)
	for i in 3:
		_mgr.add_car()
		_pos.append(Vector3.ZERO)
		_spd.append(0.0)
		_mgr.wheel_src[i] = true
	var warns: Array[int] = []
	_mgr.track_limit_warning.connect(func(c: int) -> void: warns.append(c))
	for i in 3:
		var xf := _mgr.grid_transform(i, 3)
		_pos[i] = xf.origin
		_put(i, 0.0, 0.0)
	_mgr.start_countdown()
	var guard := 0
	while _mgr.state != RaceManager.State.RACING and guard < 2000:
		_mgr.step(_pos, _spd)
		guard += 1
	cu.check(_mgr.state == RaceManager.State.RACING, "race running")

	var s0 := 450.0  # plain road, between gates 3 and 4
	# Car 1 negative controls: widened corner (road 9 m half) at lateral 8.0 and the joker road.
	_put(1, 260.0, 8.0)
	_put(2, s0, 6.0)  # 3 wheels? lateral 6 +/-0.9: right wheels at 6.9 > 6.5 -> 2 off
	for k in 3:
		_put(0, s0, 8.5)  # all four beyond 6.5
		_run(1.0)
		_put(0, s0, 0.0)
		_run(0.6)
		if k == 0:
			cu.check(warns.size() == 1 and warns[0] == 0, "first excursion: one warning for car 0")
			cu.check(_mgr.ledger.size() == 0, "first excursion: ledger empty")
	cu.check(_mgr.limit_violations[0] == 3, "car 0 counted 3 excursions (%d)" % _mgr.limit_violations[0])
	var pen := _mgr.ledger.filter(func(e: Dictionary) -> bool: return e["car"] == 0 and e["reason"] == &"track_limits")
	cu.check(pen.size() == 2 and pen[0]["seconds"] == 2.0, "second and third excursion: 2 entries of 2.0 s")
	cu.check(_mgr.limit_violations[1] == 0 and _mgr.limit_violations[2] == 0, "widened corner + 2-wheel excursions never count")

	# Joker route: every wheel is beyond 6.5 m of the main centre line but on the detour road.
	var jx := _q.joker_xz
	var mid := jx.size() / 2
	var jp := Vector3(jx[mid].x, _q.joker_ys[mid] + 0.05, jx[mid].y)
	var jt := jx[mid + 1] - jx[mid - 1]
	_put_world(1, jp, Vector3(jt.x, 0.0, jt.y).normalized())
	_run(3.0)
	cu.check(_mgr.limit_violations[1] == 0, "joker route is legal ground (negative control)")
	var lateral_main := absf(_mgr.lateral[1])
	cu.check(lateral_main > 10.0, "control really is far from the main line (%.1f m)" % lateral_main)
	# Beside the joker road (5 m half) the same car is off.
	var fwd_j := Vector3(jt.x, 0.0, jt.y).normalized()
	_put_world(1, jp + fwd_j.cross(Vector3.UP) * 8.0, fwd_j)
	_run(0.2)
	cu.check(_mgr.limit_violations[1] == 1, "outside the joker road counts")

	# Result time = race time + ledger is covered by test_track_limits.gd (full race on a test track).
	cu.check(_mgr.penalty_seconds[0] == 4.0, "ledger sum for car 0 is 4.0 s")
	cu.finish(self)
