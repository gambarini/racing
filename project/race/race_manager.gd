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
signal race_finished(results: Array)  ## [{rank, car, name, time, race_time, best_lap, penalties, penalty_list, joker_taken, dnf, finish_tick}]
signal joker_taken_by(car: int, lap: int)

enum State { IDLE, COUNTDOWN, RACING, FINISHED }

const MAX_CARS := 12
const GRID_ROW_SPACING := 8.0  ## m (estimate); shrinks so the whole grid stays in the flat zone
const GRID_LATERAL := 3.0  ## m, alternating +/-
const GRID_ZONE_BEHIND := 77.0  ## flat start zone is s -80..+60; keep the last rear bumper inside
const JUMP_REASON := &"jump_start"
const JOKER_REASON := &"joker_missed"
const RESET_REASON := &"reset"
const NEVER := -1
const RANK_HYSTERESIS := 0.3  ## m a car must lead by before it takes the place

@export var lap_count := 4
@export var countdown_steps := 3
@export var countdown_step_seconds := 1.0  ## estimate
@export var jump_start_distance := 0.5  ## m along the track before GO (estimate)
@export var jump_start_penalty := 5.0  ## s (estimate)
@export var joker_required := true  ## mandatory once per race when the track has a joker gate (ruling)
@export var joker_missed_penalty := 10.0  ## s (estimate; above the measured +2.54 s joker cost)
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
var joker_taken: Array[bool] = []  ## HUD/AI state (#150): the car has used the joker
var joker_lap := PackedInt32Array()  ## lap of the first joker use, 0 = not yet
var names: Array[String] = []
var rank_of := PackedInt32Array()  ## 1-based live position
var order := PackedInt32Array()  ## car ids, leader first
var total_s := PackedFloat64Array()  ## distance raced along the lap line (m), grid cars negative
var speeds_now := PackedFloat32Array()
var line_s := PackedFloat32Array()  ## #29: centre-line offset of each car (m)
var lateral := PackedFloat32Array()  ## #29: signed distance from the centre line (m), + = right of travel

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
func add_car(body: RigidBody3D = null, car_name := "") -> int:
	if timers.size() >= MAX_CARS:
		push_warning("RaceManager supports at most %d cars" % MAX_CARS)
		return -1
	var id := timers.size()
	var lt := track.make_lap_timer(tick_dt)
	lt.penalty_applied.connect(_on_timer_penalty.bind(id))  # reset penalties reach the ledger
	timers.append(lt)
	names.append(car_name if car_name != "" else "Car %d" % (id + 1))
	joker_taken.append(false)
	joker_lap.append(0)
	bodies.append(body)
	jump_started.append(false)
	retired.append(false)
	finish_ticks.append(NEVER)
	penalty_seconds.append(0.0)
	rank_of.append(id + 1)
	order.append(id)
	total_s.append(0.0)
	speeds_now.append(0.0)
	line_s.append(0.0)
	lateral.append(0.0)
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


func _on_timer_penalty(seconds: float, car: int) -> void:
	add_penalty(car, seconds, RESET_REASON)


## HUD/AI: the joker is still to be taken (track has one, race running, not used yet).
func joker_available(car: int) -> bool:
	return track.has_joker and state == State.RACING and not joker_taken[car] and not retired[car] \
			and finish_ticks[car] == NEVER


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


## Nearby-car query for the AI (#29). Fills `out` with the nearest car ahead (within `range_ahead`
## m) and behind (within `range_behind` m) by wrapped centre-line distance, with their lateral
## offsets and speeds. Retired cars are ignored. O(cars), allocation-free, no scene access.
func query(car: int, out: Proximity, range_ahead := 120.0, range_behind := 80.0) -> void:
	out.ahead = -1
	out.behind = -1
	out.own_lat = lateral[car]
	out.own_speed = speeds_now[car]
	var best_a := range_ahead
	var best_b := range_behind
	var half := _lap_len * 0.5
	for j in timers.size():
		if j == car or retired[j]:
			continue
		var d := fposmod(line_s[j] - line_s[car] + half, _lap_len) - half
		if d >= 0.0:
			if d < best_a:
				best_a = d
				out.ahead = j
		elif -d < best_b:
			best_b = -d
			out.behind = j
	if out.ahead >= 0:
		var j := out.ahead
		out.ahead_gap = best_a
		out.ahead_gap_s = best_a / maxf(out.own_speed, min_gap_speed)
		out.ahead_lat = lateral[j]
		out.ahead_speed = speeds_now[j]
	if out.behind >= 0:
		var j := out.behind
		out.behind_gap = best_b
		out.behind_gap_s = best_b / maxf(speeds_now[j], min_gap_speed)
		out.behind_lat = lateral[j]
		out.behind_speed = speeds_now[j]


## Signed centre-line distance (m) from `car` to `other`, + = `other` is ahead (wrapped to +/- half a lap).
func rel_s(car: int, other: int) -> float:
	var half := _lap_len * 0.5
	return fposmod(line_s[other] - line_s[car] + half, _lap_len) - half


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
		if timers[i].joker_lap != 0 and not joker_taken[i]:
			joker_taken[i] = true
			joker_lap[i] = timers[i].joker_lap
			joker_taken_by.emit(i, joker_lap[i])
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
	var count_step := floori(float(_state_tick) / float(_count_ticks)) # float division: no int-division warning
	if on_count and count_step >= countdown_steps:
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
		countdown_tick.emit(countdown_steps - count_step)
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
			if joker_required and track.has_joker and not joker_taken[i]:
				add_penalty(i, joker_missed_penalty, JOKER_REASON)
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
		line_s[i] = s
		var tf := track.forward_at(s)
		var tp := track.position_at(s)
		lateral[i] = (positions[i].x - tp.x) * -tf.z + (positions[i].z - tp.z) * tf.x
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
	# Hysteresis applies to any non-zero key difference; exactly equal keys fall through to the
	# deterministic tie-breaks below, which are not damped (equal keys are rare, ties are stable).
	var diff := _eff_key(a) - _eff_key(b)
	if diff != 0.0:
		return diff > RANK_HYSTERESIS
	if _cross_tick[a] != _cross_tick[b]:
		return _cross_tick[a] < _cross_tick[b]
	return a < b


## The race ends when every car has finished or retired, or `finish_grace_seconds` after the first
## finisher. There is deliberately no overall timeout: if nobody ever finishes, the race runs until a
## car retires or the player quits. A field of zero cars has nothing pending and ends at once.
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
		results.append(_result_row(i, rt + penalty_seconds[i], rt, false, finish_ticks[i]))
	for i in dnf:
		results.append(_result_row(i, -1.0, -1.0, true, NEVER))


func _result_row(i: int, time: float, race_time: float, is_dnf: bool, ftick: int) -> Dictionary:
	var best := -1.0
	for rec in timers[i].laps:
		if best < 0.0 or rec["raw_time"] < best:
			best = rec["raw_time"]  # laps stay raw: penalties apply to the race result only
	var list: Array[Dictionary] = []
	for e in ledger:
		if e["car"] == i:
			list.append(e)
	return {"rank": results.size() + 1, "car": i, "name": names[i], "time": time, "race_time": race_time,
			"best_lap": best, "penalties": penalty_seconds[i], "penalty_list": list,
			"joker_taken": joker_taken[i], "dnf": is_dnf, "finish_tick": ftick}
