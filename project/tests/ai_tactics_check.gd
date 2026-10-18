## AI tactics check (#29): scene-level criteria on the Quarry (straight at line s 1600..1662+190).
##  1. Lane offset: AiDriver.lane_target = 2 m on the straight; steady-state error to the offset
##     line, the 1.5 m/s rate limit and the road clamp.
##  2. Avoid: a stationary car on the line 40 m ahead of an AI at line speed; clearance, contacts.
##  3. Overtake: a car at 80 % of the AI's speed on the line, AI starts 15 m behind; pass within
##     2 laps, contacts.
##  4. Defend: a faster follower within 1 s; lane moves per straight, speed vs the solo target.
##  5. Determinism: the overtake scenario twice gives identical ticks, positions and contacts.
##  6. Joker: 4-lap race, 3 AI cars: each takes the joker exactly once; the choice is repeatable.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/ai_tactics_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const LINE := "res://tracks/quarry/quarry_racing_line.tres"
const DT := 1.0 / 120.0
const HALF_W := 0.85 ## chassis_size.x / 2
const HALF_L := 1.7 ## chassis_size.z / 2
const S0 := 5.0 ## line s of the scenario start: the flat start/finish straight (line s 1658..1662.46+196)
const S_LANE := 1600.0 ## lane test start (wraps at the lap length 1662.46)

var cu := CheckUtil.new()


## One scenario: a Quarry scene with cars driven in a fixed order each physics tick, a RaceManager
## stepped from their positions, and per-tick metrics against car 0 (the AI under test).
class Rig extends Node:
	var drive: QuarryDrive
	var mgr: RaceManager
	var line: RacingLine
	var vehicles: Array[Vehicle] = []
	var drivers: Array[AiDriver] = []  ## null = parked (handbrake)
	var states: Array[DriverInputState] = []
	var pos := PackedVector3Array()
	var spd := PackedFloat32Array()
	var travelled := PackedFloat64Array()  ## unwrapped centre-line distance per car (m)
	var _last_s := PackedFloat64Array()
	var ticks := 0
	var lock_inputs := false
	# metrics for car 0 against every other car
	var min_clear := 1.0e9
	var contacts := 0
	var _in_contact := false
	var max_lane_step := 0.0
	var _prev_lane := 0.0
	# defend metrics: lane_target moves inside straights, speed ratio vs the solo target
	var moves := 0
	var moves_per_straight: Array[int] = []
	var _prev_target := 0.0
	var _was_straight := false
	var min_speed_ratio := 1.0e9
	var ratio_from_tick := 120
	var trace_s := PackedFloat32Array()  ## car 0 line s per tick (record_trace)
	var trace_v := PackedFloat32Array()
	var record_trace := false

	func _physics_process(_delta: float) -> void:
		for i in vehicles.size():
			pos[i] = vehicles[i].global_position
			spd[i] = vehicles[i].linear_velocity.length()
		mgr.step(pos, spd)
		for i in vehicles.size():
			var ls := mgr.line_s[i]
			if ticks == 0:
				_last_s[i] = ls
			else:
				var ll := mgr.track.length()
				var dd := fposmod(ls - _last_s[i] + ll * 0.5, ll) - ll * 0.5
				travelled[i] += dd
				_last_s[i] = ls
		for i in vehicles.size():
			var st := states[i]
			if drivers[i] != null:
				drivers[i].drive(vehicles[i], st, DT)
			else:
				st.throttle = 0.0
				st.brake = 0.0
				st.handbrake = true
			if lock_inputs:
				mgr.gate_input(st)
			vehicles[i].apply_input(st)
		_metrics()
		ticks += 1

	static func clearance(a: Vehicle, b: Vehicle) -> float:
		var rel := a.global_transform.affine_inverse() * b.global_position
		var rb := a.global_transform.basis.inverse() * b.global_transform.basis
		var ex := HALF_W * absf(rb.x.x) + HALF_L * absf(rb.z.x)
		var ez := HALF_W * absf(rb.x.z) + HALF_L * absf(rb.z.z)
		return maxf(absf(rel.x) - (HALF_W + ex), absf(rel.z) - (HALF_L + ez))

	func _metrics() -> void:
		var worst := 1.0e9
		for j in range(1, vehicles.size()):
			var c := clearance(vehicles[0], vehicles[j])
			if c < worst:
				worst = c
		if vehicles.size() > 1:
			min_clear = minf(min_clear, worst)
			var hit := worst <= 0.0
			if hit and not _in_contact:
				contacts += 1
			_in_contact = hit
		var d0 := drivers[0]
		if d0 == null:
			return
		if ticks > 0:
			max_lane_step = maxf(max_lane_step, absf(d0.lane_now - _prev_lane) / DT)
		_prev_lane = d0.lane_now
		var t := d0.tactics
		if t != null:
			if t.in_straight:
				if not _was_straight:
					moves_per_straight.append(0)
				elif absf(t.lane_target - _prev_target) > 0.3:
					moves_per_straight[moves_per_straight.size() - 1] += 1
					moves += 1
			_was_straight = t.in_straight
			_prev_target = t.lane_target
			if ticks >= ratio_from_tick and d0.target_speed > 1.0:
				var solo := d0.line.target_speed_at(d0.s) * d0.speed_scale
				min_speed_ratio = minf(min_speed_ratio, d0.speed_now / solo)
		if record_trace:
			trace_s.append(d0.s)
			trace_v.append(d0.speed_now)


func _initialize() -> void:
	_main()


func _make_rig(laps := 1) -> Rig:
	var drive: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	drive.get_node("Vehicle/VehicleAudio").free()
	drive.get_node("TimeTrial").ghost_path = "user://ai_tactics_check.dat"
	root.add_child(drive)
	await physics_frame
	drive.set_physics_process(false)
	drive.time_trial.set_physics_process(false)
	var rig := Rig.new()
	rig.drive = drive
	rig.line = load(LINE)
	rig.mgr = RaceManager.new()
	rig.mgr.setup(drive.quarry.track, laps)
	root.add_child(rig.mgr)
	rig.mgr.set_physics_process(false) # the rig steps it from its own buffers
	root.add_child(rig)
	return rig


## Adds a car (the first reuses the scene's vehicle). `ai` null = parked. Returns its index.
func _add_car(rig: Rig, xf: Transform3D, ai: AiDriver) -> int:
	var i := rig.vehicles.size()
	var v: Vehicle = rig.drive.vehicle
	if i > 0:
		v = Vehicle.new()
		v.surface_map = rig.drive.quarry.terrain.surface_map
		rig.drive.add_child(v)
	v.global_transform = xf
	rig.vehicles.append(v)
	rig.drivers.append(ai)
	rig.states.append(DriverInputState.new())
	rig.pos.append(xf.origin)
	rig.spd.append(0.0)
	rig.travelled.append(0.0)
	rig.mgr.add_car(null)
	rig._last_s.append(0.0)
	return i


## Transform on the racing line at line s, `lat` m right of it, dropped to the ground.
func _on_line(rig: Rig, s: float, lat := 0.0) -> Transform3D:
	var tg := rig.line.tangent_at(s)
	var right := Vector3(-tg.z, 0.0, tg.x)
	var p := rig.line.point_at(s) + right * lat
	p.y = rig.drive.quarry.terrain.height_at(p.x, p.z) + 0.0
	return Transform3D(Basis.looking_at(tg, Vector3.UP), p)


## Gives a car a rolling start: velocity along its heading, wheels and drivetrain in sync.
func _launch(v: Vehicle, speed: float) -> void:
	v.linear_velocity = -v.global_transform.basis.z * speed
	for w in v.wheels:
		w.omega = speed / w.radius
	if v.powertrain != null:
		v.powertrain.sync_to_wheel_speed(speed / v.wheels[0].radius)


func _make_ai(rig: Rig, tactics_car := -1, scale := 0.9, seed_value := 0) -> AiDriver:
	var ai := AiDriver.new()
	ai.setup(rig.line)
	ai.speed_scale = scale
	if tactics_car >= 0:
		ai.attach_tactics(rig.mgr, tactics_car, seed_value)
	return ai


func _finish_rig(rig: Rig) -> void:
	for v in rig.vehicles:
		if v != rig.drive.vehicle:
			v.queue_free()
	rig.mgr.queue_free()
	rig.queue_free()
	rig.drive.queue_free()
	for i in 3:
		await physics_frame


func _line_speed(rig: Rig, s: float, scale := 0.9) -> float:
	return rig.line.target_speed_at(s) * scale


# --- 1. lane offset ---------------------------------------------------------------------------
func _lane_offset() -> void:
	var rig: Rig = await _make_rig()
	var v0 := _line_speed(rig, S_LANE)
	var ai := _make_ai(rig)
	_add_car(rig, _on_line(rig, S_LANE), ai)
	_launch(rig.vehicles[0], v0)
	ai.lane_target = float(OS.get_environment("LT")) if OS.get_environment("LT") != "" else 2.0
	var err_max := 0.0
	var err_final := 0.0
	var reached := -1.0
	for t in 120 * 6:
		await physics_frame
		if t >= 120 * 3:
			err_max = maxf(err_max, absf(ai.lane_error))
		if reached < 0.0 and absf(ai.lane_error) < 0.5 and t > 60:
			reached = t * DT
		err_final = ai.lane_error
		if t % 60 == 0:
			print("DBG t=%.1f s=%.1f v=%.1f lane_now=%.2f ct=%.2f err=%.2f steer=%.2f tgt=%.1f slip=%.1f y=%.2f" % [t * DT, ai.s, ai.speed_now, ai.lane_now, ai.cross_track, ai.lane_error, rig.states[0].steer, ai.target_speed, ai.rear_slip_deg, rig.vehicles[0].global_position.y])
	cu.check_range("lane offset 2 m: steady-state |error| t=3..6 s (m)", err_max, 0.0, 0.5)
	cu.check_range("lane offset 2 m: final error (m)", absf(err_final), 0.0, 0.5)
	cu.check_range("lane offset: max lane_now rate (m/s)", rig.max_lane_step, 0.0, 1.5 + 1e-3)
	print("INFO: lane offset: error < 0.5 m after %.2f s" % reached)
	# clamp: ask for far more than the road allows; the car margin keeps the centre 1.2 m inside
	ai.lane_target = 20.0
	for t in 120 * 4:
		await physics_frame
	var centre := absf(rig.line.lane_offset_at(ai.s) - ai.cross_track)
	cu.check_range("lane clamp: |centre offset| with target 20 m (m)", centre, 0.0, 6.5 - 1.2 + 0.6)
	cu.check_range("lane clamp: lane_now + line offset (m)", ai.lane_now + rig.line.lane_offset_at(ai.s + 10.0), 0.0, 6.5 - 1.2 + 1e-3)
	await _finish_rig(rig)


# --- 2. avoid ---------------------------------------------------------------------------------
func _avoid(gap := 40.0) -> Dictionary:
	var rig: Rig = await _make_rig()
	var v0 := _line_speed(rig, S0)
	var ai := _make_ai(rig, 0)
	_add_car(rig, _on_line(rig, S0), ai)
	_add_car(rig, _on_line(rig, S0 + gap), null)
	_launch(rig.vehicles[0], v0)
	var passed := -1
	var min_v := 1.0e9
	for t in 120 * 8:
		await physics_frame
		min_v = minf(min_v, ai.speed_now)
		if passed < 0 and rig.mgr.rel_s(0, 1) < -10.0:
			passed = t
		if passed >= 0 and t > passed + 120:
			break
	var out := {"clear": rig.min_clear, "contacts": rig.contacts, "passed": passed, "min_v": min_v, "v0": v0,
			"max_lat": absf(rig.mgr.lateral[0])}
	await _finish_rig(rig)
	return out


# --- 3. overtake ------------------------------------------------------------------------------
func _overtake(max_laps := 2) -> Dictionary:
	var rig: Rig = await _make_rig(max_laps + 1)
	var ai := _make_ai(rig, 0)
	var slow := _make_ai(rig, -1, 0.9 * 0.8)
	_add_car(rig, _on_line(rig, S0), ai)
	_add_car(rig, _on_line(rig, S0 + 15.0), slow)
	_launch(rig.vehicles[0], _line_speed(rig, S0))
	_launch(rig.vehicles[1], _line_speed(rig, S0 + 15.0, 0.9 * 0.8))
	var done := -1
	var max_ticks := int(120 * 70 * max_laps)
	var start_gap := rig.travelled[1] - rig.travelled[0]
	for t in max_ticks:
		await physics_frame
		var lead := rig.travelled[1] - rig.travelled[0] + 15.0 # lead's distance ahead of the AI (m)
		if done < 0 and lead < -5.0:
			done = t
		if done >= 0 and t > done + 120 * 4:
			break
	var out := {"done": done, "contacts": rig.contacts, "clear": rig.min_clear, "p0": rig.vehicles[0].global_position,
			"p1": rig.vehicles[1].global_position, "ticks": rig.ticks, "lead": rig.travelled[1] - rig.travelled[0] + 15.0,
			"start_gap": start_gap}
	await _finish_rig(rig)
	return out


# --- 4. defend --------------------------------------------------------------------------------
func _defend(with_follower: bool) -> Dictionary:
	var rig: Rig = await _make_rig()
	var s_def := S0 + 40.0
	var ai := _make_ai(rig, 0)
	_add_car(rig, _on_line(rig, s_def), ai)
	if with_follower:
		var f := _make_ai(rig, -1, 1.0)
		_add_car(rig, _on_line(rig, s_def - 25.0), f)
		_launch(rig.vehicles[1], _line_speed(rig, s_def, 1.0) + 1.0)
	_launch(rig.vehicles[0], _line_speed(rig, s_def))
	var defend_ticks := 0
	var max_lane := 0.0
	for t in 120 * 10:
		await physics_frame
		if ai.tactics.defending:
			defend_ticks += 1
		max_lane = maxf(max_lane, absf(ai.lane_now))
		if ai.s > 150.0 and ai.s < 1000.0:
			break
	var out := {"moves": rig.moves, "per_straight": rig.moves_per_straight.duplicate(), "ratio": rig.min_speed_ratio,
			"defend_ticks": defend_ticks, "max_lane": max_lane, "contacts": rig.contacts, "ticks": rig.ticks}
	await _finish_rig(rig)
	return out


# --- 6. joker race ----------------------------------------------------------------------------
func _joker_race(seed_value: int, cars := 3, laps := 4) -> Dictionary:
	var rig: Rig = await _make_rig(laps)
	rig.lock_inputs = true
	var mgr := rig.mgr
	mgr.joker_required = true
	for i in cars:
		var ai := _make_ai(rig, i, 0.9 - 0.02 * i, seed_value)
		var xf := mgr.grid_transform(i, cars)
		xf.origin.y = rig.drive.quarry.terrain.height_at(xf.origin.x, xf.origin.z) + rig.drive.spawn_lift
		_add_car(rig, xf, ai)
	await physics_frame
	var results := []
	mgr.race_finished.connect(func(r: Array) -> void: results.assign(r))
	mgr.start_countdown()
	var t := 0
	var max_t := 120 * 90 * laps
	while mgr.state != RaceManager.State.FINISHED and t < max_t:
		await physics_frame
		t += 1
	var out := {"state": mgr.state, "ticks": t, "joker_lap": Array(mgr.joker_lap), "taken": Array(mgr.joker_taken),
			"crossings": [], "contacts": rig.contacts, "ledger": mgr.ledger.size(), "pref": [], "forced": [], "clear": [],
			"end": [], "results": results.size()}
	for i in cars:
		out.crossings.append(mgr.timers[i].joker_crossings)
		var tc: AiTactics = rig.drivers[i].tactics
		out.pref.append(tc.joker_pref_lap)
		out.forced.append(tc.chosen_forced)
		out.clear.append(tc.chosen_clear)
		out.end.append(rig.vehicles[i].global_position)
	await _finish_rig(rig)
	return out


func _main() -> void:
	await physics_frame
	await _lane_offset()

	var av := await _avoid()
	print("INFO: avoid: ", av)
	cu.check(av.passed >= 0, "avoid: AI passes the parked car (tick %d)" % av.passed)
	cu.check_range("avoid: min clearance (m)", av.clear, 0.5, 100.0)
	cu.check(av.contacts == 0, "avoid: zero contacts (%d)" % av.contacts)

	var ov := await _overtake()
	print("INFO: overtake: ", ov)
	cu.check(ov.done >= 0, "overtake: AI ahead of the slow car by >= 5 m within 2 laps (tick %d, %.1f s)" % [ov.done, ov.done * DT])
	cu.check_range("overtake: contact incidents", float(ov.contacts), 0.0, 1.0)

	var solo := await _defend(false)
	var df := await _defend(true)
	print("INFO: defend solo: ", solo)
	print("INFO: defend: ", df)
	cu.check(df.defend_ticks > 0, "defend: the defender reacted to the follower (%d ticks)" % df.defend_ticks)
	var most := 0
	for m in df.per_straight:
		most = maxi(most, m)
	cu.check(most <= 1, "defend: at most one lateral move per straight (%s)" % str(df.per_straight))
	cu.check_range("defend: min speed / solo target speed", df.ratio, 0.9, 10.0)

	var ov2 := await _overtake()
	cu.check(ov.ticks == ov2.ticks and ov.p0 == ov2.p0 and ov.p1 == ov2.p1 and ov.done == ov2.done and ov.contacts == ov2.contacts,
			"determinism: overtake repeated gives identical ticks %d/%d and positions" % [ov.ticks, ov2.ticks])

	var t0 := Time.get_ticks_msec()
	var j1 := await _joker_race(7)
	print("INFO: joker race seed 7: ", j1, "  wall %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	cu.check(j1.state == RaceManager.State.FINISHED, "joker race finished (%d ticks)" % j1.ticks)
	for i in j1.crossings.size():
		cu.check(j1.crossings[i] == 1 and j1.joker_lap[i] > 0, "joker: car %d takes the joker exactly once (crossings %d, lap %d)" % [i, j1.crossings[i], j1.joker_lap[i]])
	cu.check(j1.ledger == 0, "joker: no penalties in the ledger (%d)" % j1.ledger)
	var j2 := await _joker_race(7)
	cu.check(j1.joker_lap == j2.joker_lap and j1.ticks == j2.ticks and j1.end == j2.end,
			"joker: same seed repeats the joker laps %s / %s and end state" % [str(j1.joker_lap), str(j2.joker_lap)])
	for i in 5:
		await process_frame
	cu.finish(self)
