## Contact log and contact penalty heuristic (#175): two scripted cars on the Quarry main line.
## A rear-end shunt, victim spun, attacker passes -> 1 penalty on the attacker, 0 on the victim.
## B same impact, attacker gains nothing; C impulse below threshold; D front hit and a lunge into
## the side by the car that is already ahead -> no penalty. E multi-frame contact and the per-pair
## cooldown. F a modified ContactParams resource (impulse 10000) turns A into 0 penalties.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/contact_penalty_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const DT := 1.0 / 120.0

var cu := CheckUtil.new()
var _q: Quarry
var _mgr: RaceManager
var _pos := PackedVector3Array()
var _spd := PackedFloat32Array()
var _s := PackedFloat64Array()
var _lat := PackedFloat64Array()
var _v := PackedFloat64Array()


func _initialize() -> void:
	_main()


func _fresh(params: ContactParams = null) -> void:
	if _mgr != null:
		_mgr.queue_free()
	_mgr = RaceManager.new()
	if params != null:
		_mgr.contact_params = params
	_mgr.setup(_q.track, 1)
	_mgr.joker_required = false
	_mgr.track_limits_enabled = false
	root.add_child(_mgr)
	_mgr.set_physics_process(false)  # the check steps it
	_pos = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
	_spd = PackedFloat32Array([0.0, 0.0])
	_s = PackedFloat64Array([0.0, 0.0])
	_lat = PackedFloat64Array([0.0, 0.0])
	_v = PackedFloat64Array([0.0, 0.0])
	for i in 2:
		_mgr.add_car()
		_pos[i] = _mgr.grid_transform(i, 2).origin
	_mgr.start_countdown()
	var guard := 0
	while _mgr.state != RaceManager.State.RACING and guard < 2000:
		_mgr.step(_pos, _spd)
		guard += 1


## One tick: advance both cars along the line at their speeds, then the manager.
func _tick() -> void:
	var t := _q.track
	for i in 2:
		_s[i] += _v[i] * DT
		var fwd := t.forward_at(_s[i])
		_pos[i] = t.position_at(_s[i]) + fwd.cross(Vector3.UP) * _lat[i]
		_spd[i] = _v[i]
	_mgr.step(_pos, _spd)


func _run(seconds: float) -> void:
	for n in int(round(seconds / DT)):
		_tick()


## Car 0 = victim ahead at 30 m/s, car 1 = attacker 9 m behind at 33 m/s, closing to 4.35 m at the hit after 1.55 s.
func _setup_pair(params: ContactParams = null) -> void:
	_fresh(params)
	_s[0] = 205.0
	_s[1] = 196.0
	_v[0] = 30.0
	_v[1] = 33.0
	_run(0.05)  # let rank/gate state settle on the new positions
	_run(1.5)


func _fwd(i: int) -> Vector3:
	return _q.track.forward_at(_s[i])


## Rear-end hit of car 1 on car 0 (normal along the victim heading).
func _rear_hit(impulse: float) -> void:
	_mgr.report_contact(1, 0, impulse, 3.0, _fwd(0), _fwd(0))


func _pen(car: int) -> int:
	var n := 0
	for e in _mgr.ledger:
		if e["car"] == car and e["reason"] == &"contact":
			n += 1
	return n


func _main() -> void:
	await physics_frame
	_q = (load("res://tracks/quarry/quarry.tscn") as PackedScene).instantiate()
	root.add_child(_q)
	await physics_frame

	# A: shunt from behind, victim spun (< 5 m/s), attacker passes.
	_setup_pair()
	cu.check(_mgr.rank_of[0] == 1 and _mgr.rank_of[1] == 2, "A: victim leads before the hit (ranks %d, %d)" % [_mgr.rank_of[0], _mgr.rank_of[1]])
	_rear_hit(1500.0)
	_v[0] = 2.0
	_run(3.2)
	cu.check(_mgr.rank_of[1] == 1, "A: attacker passed the victim")
	cu.check(_pen(1) == 1 and _pen(0) == 0, "A: exactly 1 penalty on the attacker, 0 on the victim (%d, %d)" % [_pen(1), _pen(0)])
	cu.check(_mgr.ledger.size() == 1 and _mgr.ledger[0]["seconds"] == 3.0, "A: ledger entry of 3.0 s, reason contact")
	cu.check(_mgr.penalty_seconds[1] == 3.0 and _mgr.timers[1].laps.size() == 0, "A: goes through the ledger; laps stay raw")
	var csv := _mgr.contact_log_csv()
	var lines := csv.strip_edges().split("\n")
	cu.check(lines.size() == 2 and lines[0] == "time_s,attacker,victim,impulse_ns,rel_speed_ms,zone", "A: CSV header + 1 row")
	cu.check(lines.size() > 1 and lines[1].ends_with(",1,0,1500.0,3.00,rear"), "A: CSV row is attacker 1, victim 0, rear (%s)" % lines[1])
	cu.check(_mgr.save_contact_log("user://contact_log_a.csv") == OK, "A: log dumps to CSV")

	# B: same impact, attacker brakes and gains nothing.
	_setup_pair()
	_rear_hit(1500.0)
	_v[0] = 2.0
	_v[1] = 0.0
	_run(3.2)
	cu.check(_mgr.rank_of[0] == 1 and _mgr.contact_count() == 1, "B: attacker gained no position, contact logged")
	cu.check(_mgr.ledger.is_empty(), "B: 0 penalties")

	# C: low-impulse touch.
	_setup_pair()
	_rear_hit(200.0)
	_v[0] = 2.0
	_run(3.2)
	cu.check(_mgr.rank_of[1] == 1 and _mgr.ledger.is_empty(), "C: below the impulse threshold, 0 penalties")

	# D1: front hit on the victim (normal against its heading), same outcome as A.
	_setup_pair()
	_mgr.report_contact(1, 0, 1500.0, 3.0, -_fwd(0), _fwd(0))
	_v[0] = 2.0
	_run(3.2)
	cu.check(_mgr.rank_of[1] == 1 and _mgr.ledger.is_empty(), "D1: front hit, 0 penalties for both")
	cu.check(_mgr.contacts.zone[0] == ContactTracker.Zone.FRONT, "D1: zone logged as front")

	# D2: the car already ahead lunges into the other's side; the hit car is slowed but nobody gains.
	_fresh()
	_s[0] = 200.0
	_s[1] = 204.0  # car 1 ahead
	_v[0] = 30.0
	_v[1] = 30.0
	_run(1.55)
	var side := _fwd(1).cross(Vector3.UP)
	_mgr.report_contact(1, 0, 1500.0, 3.0, -side, _fwd(0))
	_v[0] = 2.0
	_run(3.2)
	cu.check(_mgr.rank_of[1] == 1 and _mgr.ledger.is_empty(), "D2: lunge from the car ahead, both ledgers empty")
	cu.check(_mgr.contacts.zone[0] == ContactTracker.Zone.SIDE, "D2: zone logged as side")

	# E: multi-frame contact is one entry; a second hit within the cooldown adds no penalty.
	_setup_pair()
	for k in 5:
		_rear_hit(300.0)
		_tick()
	cu.check(_mgr.contact_count() == 1 and absf(_mgr.contacts.impulse[0] - 1500.0) < 0.1, "E: 5 frames merge into one 1500 N*s contact")
	_v[0] = 2.0
	_run(0.6)
	_rear_hit(1500.0)  # second, separate hit 0.6 s later
	_run(3.2)
	cu.check(_mgr.contact_count() == 2, "E: second hit logged separately")
	cu.check(_pen(1) == 1 and _pen(0) == 0, "E: still 1 penalty (cooldown / one pair)")
	cu.check(_mgr.contacts.penalty_count() == 1, "E: one logged contact carries the penalty")

	# F: a modified resource (impulse 10000) makes scenario A pass without a penalty.
	var p := (load("res://race/contact_params.tres") as ContactParams).duplicate() as ContactParams
	p.min_impulse = 10000.0
	_setup_pair(p)
	_rear_hit(1500.0)
	_v[0] = 2.0
	_run(3.2)
	cu.check(_mgr.rank_of[1] == 1 and _mgr.ledger.is_empty(), "F: modified resource (10000 N*s) gives 0 penalties")
	var dflt := load("res://race/contact_params.tres") as ContactParams
	cu.check(dflt.min_impulse == 400.0 and dflt.penalty_seconds == 3.0 and dflt.cooldown == 5.0, "default resource holds the estimates")
	cu.finish(self)
