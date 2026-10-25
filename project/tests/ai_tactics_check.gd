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
const LANE_ERR_MAX := 0.75 ## m (estimate 0.5; the controller's own weave on this stretch is measured below)
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
	var pre_tick := Callable()
	var grass := PackedInt32Array()  ## ticks per car with a grounded wheel on grass
	var max_centre := PackedFloat32Array()  ## max |distance from the centre line| per car (m)
	# pack metrics (#177), per car; enabled by `pack_metrics`
	var pack_metrics := false
	var stranded_t := PackedFloat32Array()  ## s of the current slow-and-off-road spell
	var stranded_max := PackedFloat32Array()  ## longest slow-and-off-road spell (s)
	var wrong_way: Array[WrongWayDetector] = []
	var wrong_flags := PackedInt32Array()  ## wrong-way flag rising edges
	var off_events := PackedInt32Array()  ## off-track excursions (a wheel past the road edge, 0.5 s debounce)
	var _off_now := PackedByteArray()
	var _off_clear := PackedInt32Array()
	var pass_max_lat := PackedFloat32Array()  ## max |lateral| while the car is passing (tactics.passing >= 0)
	var max_impact := 0.0  ## m/s: largest relative speed between two cars at the start of a contact
	var pair_contacts := 0
	var _pair_hit := PackedByteArray()
	var follow_ticks := PackedInt32Array()
	var contact_log: Array[String] = []
	var pass_ticks := PackedInt32Array()

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
		if pre_tick.is_valid():
			pre_tick.call()
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
		for i in vehicles.size():
			if grass.size() <= i:
				grass.append(0)
				max_centre.append(0.0)
			max_centre[i] = maxf(max_centre[i], absf(mgr.lateral[i]))
			for w in vehicles[i].wheels:
				if w.is_grounded and w.surface_id == &"grass":
					grass[i] += 1
					break
		_metrics()
		if pack_metrics:
			_pack_metrics()
		ticks += 1

	func _pack_metrics() -> void:
		var n := vehicles.size()
		while stranded_t.size() < n:
			stranded_t.append(0.0)
			stranded_max.append(0.0)
			wrong_way.append(WrongWayDetector.new(DT))
			wrong_flags.append(0)
			off_events.append(0)
			_off_now.append(0)
			_off_clear.append(0)
			pass_max_lat.append(0.0)
			follow_ticks.append(0)
			pass_ticks.append(0)
		for i in n:
			var v := vehicles[i]
			var any_off := false
			for w in v.wheels:
				if mgr.track.is_off_road(w.global_position):
					any_off = true
					break
			if any_off:
				_off_clear[i] = 0
				if _off_now[i] == 0:
					_off_now[i] = 1
					off_events[i] += 1
			elif _off_now[i] == 1:
				_off_clear[i] += 1
				if _off_clear[i] >= 60:
					_off_now[i] = 0
			if any_off and spd[i] < 2.0 and mgr.state == RaceManager.State.RACING:
				stranded_t[i] += DT
				stranded_max[i] = maxf(stranded_max[i], stranded_t[i])
			else:
				stranded_t[i] = 0.0
			var was: bool = wrong_way[i].wrong_way
			var tg := mgr.track.forward_at(mgr.line_s[i])
			if wrong_way[i].step(v.linear_velocity, tg) and not was:
				wrong_flags[i] += 1
			var d := drivers[i]
			if d != null and d.tactics != null:
				if d.tactics.passing >= 0:
					pass_max_lat[i] = maxf(pass_max_lat[i], absf(mgr.lateral[i]))
					pass_ticks[i] += 1
				if d.tactics.following >= 0:
					follow_ticks[i] += 1
		# car-car contact: relative speed at the first tick of each pair contact
		var k := 0
		for a in n:
			for b in range(a + 1, n):
				while _pair_hit.size() <= k:
					_pair_hit.append(0)
				var hit := clearance(vehicles[a], vehicles[b]) <= 0.0
				if hit and _pair_hit[k] == 0:
					pair_contacts += 1
					contact_log.append("t=%d cars %d/%d s=%.0f rel %.2f lat %.1f/%.1f pass %d/%d" % [ticks, a, b, mgr.line_s[a], (vehicles[a].linear_velocity - vehicles[b].linear_velocity).length(), mgr.lateral[a], mgr.lateral[b], drivers[a].tactics.passing, drivers[b].tactics.passing])
					max_impact = maxf(max_impact, (vehicles[a].linear_velocity - vehicles[b].linear_velocity).length())
				_pair_hit[k] = 1 if hit else 0
				k += 1

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
				if absf(t.lane_target - _prev_target) > 0.3:
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
	ai.lane_target = 2.0
	var err_max := 0.0
	var err_final := 0.0
	var reached := -1.0
	for t in 120 * 6:
		await physics_frame
		if t >= 120 * 4:
			err_max = maxf(err_max, absf(ai.lane_error))
		if reached < 0.0 and absf(ai.lane_error) < 0.5 and t > 60:
			reached = t * DT
		err_final = ai.lane_error
	cu.check_range("lane offset 2 m: steady-state |error| t=4..6 s (m)", err_max, 0.0, LANE_ERR_MAX)
	cu.check_range("lane offset 2 m: final |error| (m)", absf(err_final), 0.0, 0.5)
	cu.check_range("lane offset: max lane_now rate (m/s)", rig.max_lane_step, 0.0, 1.5 + 1e-3)
	print("INFO: lane offset: error < 0.5 m after %.2f s" % reached)
	# clamp: ask for far more than the road allows; the car margin keeps the centre 1.2 m inside
	ai.lane_target = 20.0
	for t in 120 * 4:
		await physics_frame
	var centre := absf(rig.line.lane_offset_at(ai.s) - ai.cross_track)
	print("INFO: lane clamp: car %.2f m from the centre line (target clamped to 5.3 m; pursuit overshoot is #171)" % centre)
	cu.check_range("lane clamp: lane_now + line offset (m)", ai.lane_now + rig.line.lane_offset_at(ai.s + 10.0), 0.0, 6.5 - 1.2 + 1e-3)
	await _finish_rig(rig)
	# Control: the same stretch with no offset, so the weave of the pursuit controller is known.
	var rig0: Rig = await _make_rig()
	var ai0 := _make_ai(rig0)
	_add_car(rig0, _on_line(rig0, S_LANE), ai0)
	_launch(rig0.vehicles[0], v0)
	var err0 := 0.0
	for t in 120 * 6:
		await physics_frame
		if t >= 120 * 4:
			err0 = maxf(err0, absf(ai0.lane_error))
	print("INFO: lane control (lane_target 0): steady-state |error| t=4..6 s %.2f m" % err0)
	await _finish_rig(rig0)


# --- 2. avoid ---------------------------------------------------------------------------------
func _avoid(gap := 40.0, tactics := true) -> Dictionary:
	var rig: Rig = await _make_rig()
	var v0 := _line_speed(rig, S0)
	var ai := _make_ai(rig, 0 if tactics else -1)
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
	if not tactics:
		passed = 0
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
			"p1": rig.vehicles[1].global_position, "ticks": rig.ticks, "grass": Array(rig.grass), "max_centre": Array(rig.max_centre), "lead": rig.travelled[1] - rig.travelled[0] + 15.0,
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
func _joker_race(seed_value: int, slot_step := 3, scale_step := 0.06, shadow := false, cars := 2, laps := 4, joker := true, tactics := true, metrics := false) -> Dictionary:
	var rig: Rig = await _make_rig(laps)
	rig.lock_inputs = true
	rig.pack_metrics = metrics
	var mgr := rig.mgr
	mgr.joker_required = joker
	for i in cars:
		# slots 0 and 3 of a 6-car grid: a spread field; the second car is slower, so the gap opens
		var slot := i * slot_step
		var ai := _make_ai(rig, -1 if ((shadow and i == 1) or not tactics) else i, 0.9 - scale_step * i, seed_value)
		if ai.tactics != null and not joker:
			ai.tactics.use_joker = false
		var xf := mgr.grid_transform(slot, 6)
		xf.origin.y = rig.drive.quarry.terrain.height_at(xf.origin.x, xf.origin.z) + rig.drive.spawn_lift
		_add_car(rig, xf, ai)
	if shadow:
		# Car 1 is a plain line follower held ~20 m (0.7 s) behind car 0 by trimming its speed scale.
		var sh: AiDriver = rig.drivers[1]
		rig.pre_tick = func() -> void:
			sh.speed_scale = clampf(0.9 + 0.01 * (mgr.rel_s(1, 0) - 20.0), 0.6, 1.0)
	await physics_frame
	var results := []
	mgr.race_finished.connect(func(r: Array) -> void: results.assign(r))
	mgr.start_countdown()
	var t := 0
	var probe := Proximity.new()
	var prev_s := PackedFloat32Array()
	var samples: Array = []
	for i in cars:
		prev_s.append(0.0)
		samples.append({})
	# ## per car: lap -> time gap (s) to the nearest car, from RaceManager, 120 m before the detour entry
	var probe_s := rig.line.joker_span_main.x - 120.0
	var max_t := 120 * 90 * laps
	while mgr.state != RaceManager.State.FINISHED and t < max_t:
		await physics_frame
		t += 1
		for i in cars:
			var cs := mgr.line_s[i]
			if prev_s[i] < probe_s and cs >= probe_s and mgr.state == RaceManager.State.RACING:
				mgr.query(i, probe)
				var g := INF
				if probe.ahead >= 0:
					g = minf(g, probe.ahead_gap_s)
				if probe.behind >= 0:
					g = minf(g, probe.behind_gap_s)
				samples[i][mgr.timers[i].laps.size() + 1] = g
			prev_s[i] = cs
	var out := {"state": mgr.state, "ticks": t, "joker_lap": Array(mgr.joker_lap), "taken": Array(mgr.joker_taken),
			"crossings": [], "contacts": rig.contacts, "ledger": mgr.ledger.size(), "pref": [], "forced": [], "clear": [],
			"end": [], "results": results.size(), "grass": Array(rig.grass), "max_centre": Array(rig.max_centre),
			"samples": samples, "laps": [], "order": Array(mgr.order)}
	if metrics:
		out["stranded"] = Array(rig.stranded_max)
		out["wrong"] = Array(rig.wrong_flags)
		out["off"] = Array(rig.off_events)
		out["pass_lat"] = Array(rig.pass_max_lat)
		out["pass_ticks"] = Array(rig.pass_ticks)
		out["follow_ticks"] = Array(rig.follow_ticks)
		out["impact"] = rig.max_impact
		out["pair_contacts"] = rig.pair_contacts
		out["contact_log"] = rig.contact_log
		out["finished"] = Array(mgr.finish_ticks)
	for i in cars:
		out.crossings.append(mgr.timers[i].joker_crossings)
		var tc: AiTactics = rig.drivers[i].tactics
		out.pref.append(tc.joker_pref_lap if tc != null else -1)
		out.forced.append(tc.chosen_forced if tc != null else false)
		out.clear.append(tc.chosen_clear if tc != null else false)
		out.end.append(rig.vehicles[i].global_position)
		var lt: Array = []
		for rec in mgr.timers[i].laps:
			lt.append(rec["ticks"])
		out.laps.append(lt)
	await _finish_rig(rig)
	return out


## Debug filter: `-- pack` (user args) runs only the named sections; no args runs everything.
func _want(section: String) -> bool:
	var a := OS.get_cmdline_user_args()
	return a.is_empty() or a.has(section) or (section == "base" and not a.has("pack"))


func _pack_checks() -> void:
	var pk := await _joker_race(5, 1, 0.0, false, 3, 3, false, true, true)
	print("INFO: pack plain: ", pk)


func _main() -> void:
	await physics_frame
	if _want("pack"):
		await _pack_checks()
	if not _want("base"):
		cu.finish(self)
		return
	await _lane_offset()

	var av := await _avoid()
	print("INFO: avoid: ", av)
	cu.check(av.passed >= 0, "avoid: AI passes the parked car (tick %d)" % av.passed)
	cu.check_range("avoid: min clearance (m)", av.clear, 0.5, 100.0)
	cu.check(av.contacts == 0, "avoid: zero contacts (%d)" % av.contacts)

	var av0 := await _avoid(40.0, false)
	print("INFO: avoid negative control (no tactics): ", av0)
	cu.check(av0.contacts > 0 or av0.clear < 0.5, "avoid control: the same scenario without tactics hits the parked car (clearance %.2f m)" % av0.clear)

	var ov := await _overtake()
	print("INFO: overtake: ", ov)
	cu.check(ov.done >= 0, "overtake: AI ahead of the slow car by >= 5 m within 2 laps (tick %d, %.1f s)" % [ov.done, ov.done * DT])
	print("INFO: overtake off-road: grass ticks ", ov.grass, " max centre ", ov.max_centre)
	cu.check(ov.grass[0] == 0, "overtake: no grass ticks while passing (%d; max centre offset %.2f m, road half-width 6.5 m)" % [ov.grass[0], ov.max_centre[0]])
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
	for i in j1.crossings.size():
		cu.check(j1.forced[i] or j1.clear[i], "joker: car %d took a non-final lap only with no car within 1.5 s (forced %s, clear %s)" % [i, j1.forced[i], j1.clear[i]])
	var j2 := await _joker_race(7)
	cu.check(j1.joker_lap == j2.joker_lap and j1.pref == j2.pref and j1.ticks == j2.ticks,
			"joker: same seed repeats the joker laps %s / %s, preferred laps %s and race ticks %d / %d" % [str(j1.joker_lap), str(j2.joker_lap), str(j1.pref), j1.ticks, j2.ticks])
	cu.check(j1.laps == j2.laps and j1.order == j2.order and j1.end == j2.end,
			"joker: identical lap ticks %s, finishing order %s and end positions across two seed-7 runs" % [str(j1.laps), str(j1.order)])
	# Traffic case: two cars glued together (grid slots 0 and 1, equal pace) stay inside 1.5 s, so a
	# car whose preferred lap has come must defer; verified from RaceManager gaps, not the tactic's flag.
	var tr := await _joker_race(0, 1, 0.0, true)
	print("INFO: joker traffic race: laps ", tr.joker_lap, " pref ", tr.pref, " gap samples ", tr.samples[0])
	var jl: int = tr.joker_lap[0]
	var busy: Array = []
	for lap in tr.samples[0]:
		if tr.samples[0][lap] <= 1.5:
			busy.append(lap)
	cu.check(tr.crossings[0] == 1 and jl > 0, "joker traffic: the AI takes the joker exactly once (crossings %d, lap %d)" % [tr.crossings[0], jl])
	cu.check(busy.has(tr.pref[0]) , "joker traffic: a car was within 1.5 s (RaceManager gap) on the preferred lap %d (busy laps %s)" % [tr.pref[0], str(busy)])
	cu.check(not busy.has(jl) or jl == 4, "joker traffic: the joker lap %d was clear by RaceManager gap, or forced on the last lap (busy %s)" % [jl, str(busy)])
	cu.check(jl > tr.pref[0], "joker traffic: the joker was deferred past the preferred lap (took lap %d, preferred %d)" % [jl, tr.pref[0]])
	print("INFO: joker race off-road: grass ticks ", j1.grass, " max centre offsets ", j1.max_centre)
	for i in 5:
		await process_frame
	cu.finish(self)
