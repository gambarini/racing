class_name RaceManager
extends Node
## Race manager core (issue #149): registers up to MAX_CARS cars, each with its own LapTimer in
## standing mode, lays out the staggered grid, runs the countdown, flags jump starts, ranks cars
## live and decides the finish. Rulings (estimates) on the wiki page Core Loop and Race Format.
## Pure logic behind `step(positions, speeds)` (called once per physics tick with caller-owned
## buffers), so tests can drive cars by teleporting; as a Node it feeds `step()` from registered
## RigidBody3D cars in `_physics_process`. Joker enforcement and results screen are #150; they use
## `add_penalty()` / the ledger and the `race_finished` results built here.
## Per-tick paths use preallocated arrays only; events (penalties, finish, results) allocate.

signal countdown_tick(remaining: int)  ## 3, 2, 1, emitted on the tick each count starts
signal race_started
signal penalty_added(entry: Dictionary)  ## {car, seconds, reason, tick}
signal car_finished(car: int, race_ticks: int)
signal race_finished(results: Array)  ## [{rank, car, time, race_time, penalties, dnf, finish_tick}]

enum State { IDLE, COUNTDOWN, RACING, FINISHED }

const MAX_CARS := 12
const GRID_ROW_SPACING := 8.0  ## m (estimate); shrinks so the whole grid stays in the flat zone
const GRID_LATERAL := 3.0  ## m, alternating +/-
const GRID_ZONE_BEHIND := 77.0  ## flat start zone is s -80..+60; keep the last rear bumper inside
const JUMP_REASON := &"jump_start"
const NEVER := -1
const RANK_HYSTERESIS := 0.3  ## m a car must lead by before it takes the place

@export var lap_count := 4
@export var countdown_steps := 3
@export var countdown_step_seconds := 1.0  ## estimate
@export var jump_start_distance := 0.5  ## m along the track before GO (estimate)
@export var jump_start_penalty := 5.0  ## s (estimate)
@export var finish_grace_seconds := 30.0  ## after the first finisher (estimate)
@export var min_gap_speed := 5.0  ## m/s floor for the gap-to-car-ahead estimate

var track: TrackSpline
var tick_dt := 1.0 / 120.0
var state := State.IDLE
var tick := 0
var go_tick := NEVER
var timers: Array[LapTimer] = []
var bodies: Array[RigidBody3D] = []  ## node mode; null entries for step()-driven cars
var ledger: Array[Dictionary] = []
var results: Array = []

# Per-car data, indexed by car id (registration order).
var jump_started: Array[bool] = []
var retired: Array[bool] = []
var finish_ticks := PackedInt32Array()  ## race ticks at the finish, NEVER until finished
var penalty_seconds := PackedFloat64Array()
var rank_of := PackedInt32Array()  ## 1-based live position
var order := PackedInt32Array()  ## car ids, leader first
var total_s := PackedFloat64Array()  ## distance raced along the lap line (m), grid cars negative
var speeds_now := PackedFloat32Array()

var _key := PackedFloat64Array()
var _cross_tick := PackedInt32Array()
var _last_laps := PackedInt32Array()
var _last_gate := PackedInt32Array()
var _ref_pos: Array[Vector3] = []
var _ref_fwd: Array[Vector3] = []
var _lap_len := 1.0
var _count_ticks := 120
var _state_tick := 0  ## ticks since the countdown started
var _baseline_pending := false
var _deadline_tick := NEVER
var _pos_buf := PackedVector3Array()
var _spd_buf := PackedFloat32Array()


func setup(p_track: TrackSpline, p_lap_count := 4, p_tick_dt := 1.0 / 120.0) -> void:
	track = p_track
	lap_count = p_lap_count
	tick_dt = p_tick_dt
	_lap_len = track.length()


func car_count() -> int:
	return timers.size()


## Registers a car and returns its id (or -1 past MAX_CARS). `body` is optional: step()-driven
## tests pass none.
func add_car(body: RigidBody3D = null) -> int:
	if timers.size() >= MAX_CARS:
		push_warning("RaceManager supports at most %d cars" % MAX_CARS)
		return -1
	var id := timers.size()
	timers.append(track.make_lap_timer(tick_dt))
	bodies.append(body)
	jump_started.append(false)
	retired.append(false)
	finish_ticks.append(NEVER)
	penalty_seconds.append(0.0)
	rank_of.append(id + 1)
	order.append(id)
	total_s.append(0.0)
	speeds_now.append(0.0)
	_key.append(0.0)
	_cross_tick.append(0)
	_last_laps.append(0)
	_last_gate.append(0)
	_ref_pos.append(Vector3.ZERO)
	_ref_fwd.append(Vector3(0, 0, -1))
	_pos_buf.append(Vector3.ZERO)
	_spd_buf.append(0.0)
	return id


## World transform of grid slot `slot` (0 = pole) for a field of `count`: staggered rows behind
## the start line, alternating +/-GRID_LATERAL, facing the track tangent. The row spacing is
## GRID_ROW_SPACING, reduced when the field would not fit the flat start zone. Pole is on the
## right (+) side like TrackSpline.grid_transform; y is the centre-line height (callers drop it).
func grid_transform(slot: int, count: int) -> Transform3D:
	var spacing := minf(GRID_ROW_SPACING, GRID_ZONE_BEHIND / maxf(count, 1))
	var d := track.gate_offsets[0] - spacing * (slot + 1)
	var fwd := track.forward_at(d)
	var right := fwd.cross(Vector3.UP)
	var side := GRID_LATERAL if slot % 2 == 0 else -GRID_LATERAL
	return Transform3D(Basis.looking_at(fwd, Vector3.UP), track.position_at(d) + right * side)


## Starts the countdown. The first stepped tick is the baseline for jump-start detection.
func start_countdown() -> void:
	if state != State.IDLE:
		return
	state = State.COUNTDOWN
	_state_tick = 0
	_count_ticks = maxi(int(round(countdown_step_seconds / tick_dt)), 1)
	_baseline_pending = true


## True while a car's inputs must be ignored (before GO).
func inputs_locked() -> bool:
	return state == State.IDLE or state == State.COUNTDOWN


## Overwrites `input` with the pre-GO lock: throttle and brake zero, handbrake held. Call it
## on the driver state before `Vehicle.apply_input()` every tick.
func gate_input(input: DriverInputState) -> void:
	if inputs_locked():
		input.throttle = 0.0
		input.brake = 0.0
		input.handbrake = true


func add_penalty(car: int, seconds: float, reason: StringName) -> void:
	penalty_seconds[car] += seconds
	var entry := {"car": car, "seconds": seconds, "reason": reason, "tick": tick}
	ledger.append(entry)
	penalty_added.emit(entry)


func retire(car: int) -> void:
	retired[car] = true


func timer_of(car: int) -> LapTimer:
	return timers[car]


func position_of(car: int) -> int:
	return rank_of[car]


func is_finished(car: int) -> bool:
	return finish_ticks[car] != NEVER


## Seconds to the car ahead: distance / own speed (floored at min_gap_speed). -1 for the leader.
func gap_ahead(car: int) -> float:
	var r := rank_of[car]
	if r <= 1:
		return -1.0
	var ahead := order[r - 2]
	return maxf(total_s[ahead] - total_s[car], 0.0) / maxf(speeds_now[car], min_gap_speed)


func _physics_process(_delta: float) -> void:
	for i in timers.size():
		var b := bodies[i]
		if b == null:
			continue
		_pos_buf[i] = b.global_position
		_spd_buf[i] = b.linear_velocity.length()
	step(_pos_buf, _spd_buf)


## One physics tick. `positions`/`speeds` are indexed by car id and owned by the caller.
func step(positions: PackedVector3Array, speeds: PackedFloat32Array) -> void:
	tick += 1
	for i in timers.size():
		timers[i].step(positions[i])
		speeds_now[i] = speeds[i]
	if state == State.COUNTDOWN:
		_step_countdown(positions)
	elif state == State.RACING:
		_step_finish()
	_update_progress(positions)
	_rank()
	if state == State.RACING:
		_check_race_end()


func _step_countdown(positions: PackedVector3Array) -> void:
	var n := timers.size()
	var on_count := _state_tick % _count_ticks == 0
	if on_count and _state_tick / _count_ticks >= countdown_steps:
		_go()
		return
	if _baseline_pending:
		_baseline_pending = false
		for i in n:
			_ref_pos[i] = positions[i]
			_ref_fwd[i] = track.forward_at(track.nearest_offset(positions[i]))
	else:
		for i in n:
			if not jump_started[i] and (positions[i] - _ref_pos[i]).dot(_ref_fwd[i]) > jump_start_distance:
				jump_started[i] = true
				add_penalty(i, jump_start_penalty, JUMP_REASON)
	if on_count:
		countdown_tick.emit(countdown_steps - _state_tick / _count_ticks)
	_state_tick += 1


func _go() -> void:
	state = State.RACING
	go_tick = tick
	for t in timers:
		t.start_standing()  # same tick for every car
	race_started.emit()


func _step_finish() -> void:
	for i in timers.size():
		if finish_ticks[i] == NEVER and not retired[i] and timers[i].laps.size() >= lap_count:
			finish_ticks[i] = tick - go_tick
			if _deadline_tick == NEVER:
				_deadline_tick = tick + int(round(finish_grace_seconds / tick_dt))
			car_finished.emit(i, finish_ticks[i])


func _update_progress(positions: PackedVector3Array) -> void:
	var half := _lap_len * 0.5
	for i in timers.size():
		var t := timers[i]
		var g := maxi(t.last_gate_crossed, 0)
		var laps := t.laps.size()
		var s := track.nearest_offset(positions[i])
		var d := snappedf(fposmod(s - track.gate_offsets[g] + half, _lap_len) - half, 0.01)  # cm: float noise must not decide ties
		total_s[i] = laps * _lap_len + track.gate_offsets[g] + d
		_key[i] = laps * 1.0e5 + g * 1.0e3 + d
		if laps != _last_laps[i] or g != _last_gate[i]:
			_last_laps[i] = laps
			_last_gate[i] = g
			_cross_tick[i] = tick


## Higher key first. Insertion sort starting from the previous order, with a hysteresis band of
## RANK_HYSTERESIS metres: two cars side by side (nearest-offset noise, lateral offsets) keep
## their order until one is clearly ahead, so the list never flickers. Exactly equal keys: earlier
## crossing tick, then lower id. Finished cars rank by finish order above everyone, retired
## cars below everyone.
func _rank() -> void:
	var n := order.size()
	for a in range(1, n):
		var c := order[a]
		var b := a - 1
		while b >= 0 and _ahead(c, order[b]):
			order[b + 1] = order[b]
			b -= 1
		order[b + 1] = c
	for r in n:
		rank_of[order[r]] = r + 1


func _eff_key(i: int) -> float:
	if finish_ticks[i] != NEVER:
		return 1.0e12 - finish_ticks[i]  # earlier finish ranks higher
	if retired[i]:
		return -1.0e12 + _key[i]
	return _key[i]


## True when car `a` must move in front of car `b` (currently ahead of it).
func _ahead(a: int, b: int) -> bool:
	var diff := _eff_key(a) - _eff_key(b)
	if diff != 0.0:
		return diff > RANK_HYSTERESIS
	if _cross_tick[a] != _cross_tick[b]:
		return _cross_tick[a] < _cross_tick[b]
	return a < b


func _check_race_end() -> void:
	var pending := false
	for i in timers.size():
		if finish_ticks[i] == NEVER and not retired[i]:
			pending = true
			break
	if pending and not (_deadline_tick != NEVER and tick >= _deadline_tick):
		return
	state = State.FINISHED
	_build_results()
	race_finished.emit(results)


## Finishers by total time (race time + ledger penalties, ties by earlier finish), then DNFs by
## distance raced. Rank entries start at 1.
func _build_results() -> void:
	var fin: Array[int] = []
	var dnf: Array[int] = []
	for i in timers.size():
		(fin if finish_ticks[i] != NEVER else dnf).append(i)
	fin.sort_custom(func(a: int, b: int) -> bool:
		var ta := finish_ticks[a] * tick_dt + penalty_seconds[a]
		var tb := finish_ticks[b] * tick_dt + penalty_seconds[b]
		if ta != tb:
			return ta < tb
		if finish_ticks[a] != finish_ticks[b]:
			return finish_ticks[a] < finish_ticks[b]
		return a < b)
	dnf.sort_custom(func(a: int, b: int) -> bool:
		if total_s[a] != total_s[b]:
			return total_s[a] > total_s[b]
		return a < b)
	results = []
	for i in fin:
		var rt := finish_ticks[i] * tick_dt
		results.append({"rank": results.size() + 1, "car": i, "time": rt + penalty_seconds[i],
				"race_time": rt, "penalties": penalty_seconds[i], "dnf": false, "finish_tick": finish_ticks[i]})
	for i in dnf:
		results.append({"rank": results.size() + 1, "car": i, "time": -1.0, "race_time": -1.0,
				"penalties": penalty_seconds[i], "dnf": true, "finish_tick": NEVER})
