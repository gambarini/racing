## Track limits with a real Vehicle on the Quarry (#190): the node-mode wheel path of
## RaceManager._classify_wheels (reads Vehicle.wheels[k].global_position), which track_limits_check
## only covers with scripted wheel positions. A QuarryDrive car (real Jolt body, no
## set_wheels_off / set_wheel_positions) is driven by a small pure-pursuit controller on the start
## straight, in this order:
##  1. negative case: along the edge with 1-3 wheels off for > 1 s -> no warning, no penalty,
##  2. excursion 1: all 4 wheels off the road for 1 s, back on the road -> exactly 1 warning, 0 ledger entries,
##  3. excursion 2 (same again) -> exactly 1 ledger entry (LIMITS_REASON, track_limit_penalty s),
##     penalty_seconds = that, raw lap times untouched.
## The whole scenario runs twice in one process; warning/penalty ticks and the final state must match.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/track_limits_drive_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const GHOST := "user://test_ghost_track_limits_drive.dat" ## never the player's user://ghost_best.dat (#153)
const DT := 1.0 / 120.0
const MAX_TICKS := 120 * 60
const SPEED := 13.0 ## m/s target on the straight
const LAT_EDGE := 6.9 ## m: right wheels (+0.9 m) beyond the 6.5 m road edge, left wheels (-0.9 m) still on it
const LAT_OUT := 8.6 ## m: all four wheels beyond the edge, still on the flat shoulder (edge + 2.5 m)
const HOLD_NEG := 150 ## ticks with 1-3 wheels off (1.25 s)
const HOLD_OUT := 120 ## ticks with 4 wheels off (1 s)
const HOLD_BACK := 180 ## ticks with 0 wheels off (1.5 s, > the 0.5 s debounce)
const LAT_RATE := 3.0 ## m/s lateral target slew

enum Phase { ACCEL, EDGE, BACK1, OUT1, BACK2, OUT2, BACK3, DONE }

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


## One full scenario; returns the measured record.
func _run() -> Dictionary:
	var drive: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	drive.get_node("TimeTrial").ghost_path = GHOST
	drive.get_node("Vehicle/VehicleAudio").free() # audio is not under test and holds streams at exit
	root.add_child(drive)
	await physics_frame
	drive.driver_input.set_physics_process(false) # this script writes the driver state
	var track: TrackSpline = drive.quarry.track
	var mgr := RaceManager.new()
	mgr.setup(track, 1)
	mgr.joker_required = false
	mgr.contact_penalties_enabled = false
	root.add_child(mgr)
	var car := mgr.add_car(drive.vehicle, "Test")
	var rec := {"warn_ticks": [] as Array[int], "pen_ticks": [] as Array[int], "max_off_neg": 0,
			"src": mgr.wheel_src[car], "phase_warn": [0, 0, 0, 0, 0, 0, 0, 0],
			"phase_ledger": [0, 0, 0, 0, 0, 0, 0, 0]}
	mgr.track_limit_warning.connect(func(c: int) -> void:
		if c == car:
			rec.warn_ticks.append(mgr.tick))
	mgr.penalty_added.connect(func(e: Dictionary) -> void:
		if e.car == car and e.reason == RaceManager.LIMITS_REASON:
			rec.pen_ticks.append(int(e.tick)))
	mgr.start_countdown()
	var st := drive.driver_input.state
	var v := drive.vehicle
	var phase := Phase.ACCEL
	var count := 0
	var lat_target := 0.0
	var lat_goal := 0.0
	var ticks := 0
	var go_seen := 0
	var max_steer := deg_to_rad(34.0)
	while phase != Phase.DONE and ticks < MAX_TICKS:
		await physics_frame
		ticks += 1
		var off: int = mgr.wheels_off[car]
		# Phase transitions (counts are in ticks inside the phase).
		match phase:
			Phase.ACCEL:
				if mgr.state == RaceManager.State.RACING:
					go_seen += 1
				if go_seen >= 360 and v.linear_velocity.length() > SPEED - 2.0:
					phase = Phase.EDGE
					lat_goal = LAT_EDGE
					count = 0
			Phase.EDGE:
				rec.max_off_neg = maxi(rec.max_off_neg, off)
				if off >= 1:
					count += 1
				if count >= HOLD_NEG:
					phase = Phase.BACK1
					lat_goal = 0.0
					count = 0
			Phase.BACK1, Phase.BACK2, Phase.BACK3:
				count = count + 1 if off == 0 else 0
				if count >= HOLD_BACK:
					count = 0
					if phase == Phase.BACK1:
						phase = Phase.OUT1
						lat_goal = LAT_OUT
					elif phase == Phase.BACK2:
						phase = Phase.OUT2
						lat_goal = LAT_OUT
					else:
						phase = Phase.DONE
			Phase.OUT1, Phase.OUT2:
				if off >= 4:
					count += 1
				if count >= HOLD_OUT:
					count = 0
					lat_goal = 0.0
					phase = Phase.BACK2 if phase == Phase.OUT1 else Phase.BACK3
		rec.phase_warn[phase] = rec.warn_ticks.size()
		rec.phase_ledger[phase] = rec.pen_ticks.size()
		# Controller: pure pursuit to a point ahead on the centre line shifted by the slewed lateral target.
		lat_target = move_toward(lat_target, lat_goal, LAT_RATE * DT)
		var pos := v.global_position
		var s := track.nearest_offset(pos)
		var speed := v.linear_velocity.length()
		var ld := maxf(8.0, speed * 0.6)
		var ahead := track.position_at(s + ld) + track.forward_at(s + ld).cross(Vector3.UP) * lat_target
		var fwd := -v.global_transform.basis.z
		var right := v.global_transform.basis.x
		var to := ahead - pos
		var err := atan2(to.dot(right), to.dot(fwd))
		st.steer = clampf(err / max_steer * 1.5, -1.0, 1.0)
		st.throttle = clampf((SPEED - speed) / 3.0, 0.0, 1.0)
		st.brake = 0.0
		st.handbrake = false
		mgr.gate_input(st)
	rec["phase"] = phase
	rec["ticks"] = ticks
	rec["warnings"] = rec.warn_ticks.size()
	rec["ledger"] = mgr.ledger.size()
	rec["limit_entries"] = 0
	for e in mgr.ledger:
		if e.reason == RaceManager.LIMITS_REASON:
			rec.limit_entries += 1
			rec["entry"] = e
	rec["penalty_seconds"] = mgr.penalty_seconds[car]
	rec["violations"] = mgr.limit_violations[car]
	rec["laps"] = mgr.timer_of(car).laps.size()
	rec["final_pos"] = drive.vehicle.global_position
	rec["penalty"] = mgr.track_limit_penalty
	print("INFO: ticks %d, warning ticks %s, penalty ticks %s, edge-phase max wheels off %d, penalty_seconds %.2f" % [
			ticks, rec.warn_ticks, rec.pen_ticks, rec.max_off_neg, rec.penalty_seconds])
	mgr.queue_free()
	drive.queue_free()
	await physics_frame
	return rec


func _main() -> void:
	await physics_frame
	DirAccess.remove_absolute(GHOST)
	var a := await _run()
	var b := await _run()
	cu.check(a.phase == Phase.DONE, "the scenario completes (%d ticks)" % a.ticks)
	cu.check(a.src, "the car is classified through its Vehicle wheel nodes (wheel_src)")
	cu.check(a.max_off_neg >= 1 and a.max_off_neg <= 3,
			"edge run: 1-3 wheels off for > 1 s, never 4 (max %d)" % a.max_off_neg)
	cu.check(a.phase_warn[Phase.BACK1] == 0 and a.phase_ledger[Phase.BACK1] == 0,
			"edge run (1-3 wheels off, %.2f s): no warning, no penalty" % (HOLD_NEG * DT))
	cu.check(a.phase_warn[Phase.BACK2] == 1 and a.phase_ledger[Phase.BACK2] == 0,
			"after excursion 1: exactly 1 warning and 0 track-limit ledger entries (%d / %d)" % [
			a.phase_warn[Phase.BACK2], a.phase_ledger[Phase.BACK2]])
	cu.check(a.warnings == 1 and a.violations == 2, "2 excursions counted, still exactly 1 warning (%d warnings, %d violations)" % [a.warnings, a.violations])
	cu.check(a.limit_entries == 1 and a.ledger == 1, "after excursion 2: exactly 1 ledger entry, reason LIMITS_REASON (%d)" % a.limit_entries)
	cu.check(a.has("entry") and is_equal_approx(float(a.entry.seconds), a.penalty), "the entry carries track_limit_penalty (%.1f s)" % a.penalty)
	cu.check(is_equal_approx(a.penalty_seconds, a.penalty), "penalty_seconds == track_limit_penalty (%.2f)" % a.penalty_seconds)
	cu.check(a.laps == 0, "raw lap times untouched (no lap record gained a penalty)")
	cu.check(a.warn_ticks == b.warn_ticks and a.pen_ticks == b.pen_ticks and a.final_pos.is_equal_approx(b.final_pos),
			"deterministic: warning ticks %s / penalty ticks %s equal in both runs" % [a.warn_ticks, a.pen_ticks])
	cu.finish(self)
