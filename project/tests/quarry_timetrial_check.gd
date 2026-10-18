## Time trial in the Quarry scene (#132): TimeTrial (ghost recorder/replay) wired into QuarryDrive with
## a real Vehicle, LapTimer in flying-lap mode and the scripted autopilot. Runs, all against one
## user:// ghost file that is deleted first:
##  1. joker route (slow): first valid lap is saved (saved=true),
##  2. main route with a reset penalty on every lap: valid=false, saved=false, file bytes unchanged,
##  3. main route (2 laps): 60 Hz samples, ticks match the LapTimer, a faster lap overwrites the file,
##     ghost reaches the recorded final pose / the car at the finish tick, file round-trips,
##  4. joker route again: valid but slower than the saved best, file bytes unchanged.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/quarry_timetrial_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const GHOST := "user://test_ghost_quarry_timetrial.dat" ## never the player's user://ghost_best.dat (#153)
const MAX_TICKS := 120 * 160
const GHOST_MAX_DIST := 0.5 ## m, ghost vs car on a live replay of the saved best (#153; QA measured 0.30 m)
const CONTROL_OFFSET := Vector3(1.0, 0.0, 0.0) ## negative control: ghost displaced by 1 m
const CONTROL_SHIFT := 24 ## negative control: ghost 0.2 s (24 ticks at 120 Hz) out of time

var cu := CheckUtil.new()
var _finished: Array[Dictionary] = []
var _tt: TimeTrial
var _lt: LapTimer
var _veh: Vehicle
var _ghost_log: Array[Vector3] = [] ## live replay: ghost position per tick (lap 2 only)
var _car_log: Array[Vector3] = []


func _initialize() -> void:
	_main()


func _on_finished(ticks: int, valid: bool, saved: bool) -> void:
	_finished.append({"ticks": ticks, "valid": valid, "saved": saved,
			"timer_tick": _lt.tick, "pos": _veh.global_position})


## Drives until `laps` timer laps are done on `route`; `penalty` adds a reset penalty to each running lap.
func _run(route: StringName, laps: int, penalty := false, log_ghost := false) -> Dictionary:
	_finished.clear()
	_ghost_log.clear()
	_car_log.clear()
	var drive: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	drive.get_node("Vehicle/VehicleAudio").free() # audio is not under test and holds streams at exit
	drive.get_node("TimeTrial").ghost_path = GHOST
	root.add_child(drive)
	await physics_frame
	_tt = drive.time_trial
	_lt = drive.lap_timer
	_veh = drive.vehicle
	_tt.lap_finished.connect(_on_finished)
	var completed_at: Array[int] = []
	_lt.lap_completed.connect(func(_r: Dictionary) -> void: completed_at.append(_lt.tick))
	var q := drive.quarry
	var pts := q.route_points(route, &"tarmac")
	var drv := QuarryDriver.new()
	drv.setup(pts, q.route_mu(pts))
	drive.autopilot = drv
	var ticks := 0
	var was_running := false
	while _lt.laps.size() < laps and ticks < MAX_TICKS:
		await physics_frame
		ticks += 1
		if penalty and _lt.running and not was_running:
			_lt.add_penalty(1.0)
		was_running = _lt.running
		# Live replay of the saved best: log ghost and car on every tick of lap 2 (lap 1 starts from rest).
		if log_ghost and _lt.running and _lt.laps.size() == 1 and _tt._replay_tick >= 0:
			_ghost_log.append(_tt.ghost.global_position)
			_car_log.append(_veh.global_position)
	return {"drive": drive, "tt": _tt, "timer": _lt, "ticks": ticks, "finished": _finished.duplicate(),
			"completed_at": completed_at}


## Stops every voice before freeing, so the audio server holds no playback (clean exit).
func _dispose(d: QuarryDrive) -> void:
	for pl in d.find_children("*", "AudioStreamPlayer", true, false):
		pl.stop()
	d.queue_free()


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path)


## Worst ghost-to-car distance over the logged ticks; the ghost sample is taken `shift` ticks
## late and displaced by `offset`. Returns {dist, tick} (tick = first one above GHOST_MAX_DIST, else the worst).
func _worst_ghost_dist(offset := Vector3.ZERO, shift := 0) -> Dictionary:
	var worst := 0.0
	var worst_tick := -1
	var first_bad := -1
	for i in _car_log.size():
		var g := _ghost_log[clampi(i + shift, 0, _ghost_log.size() - 1)] + offset
		var d := g.distance_to(_car_log[i])
		if d > worst:
			worst = d
			worst_tick = i
		if d > GHOST_MAX_DIST and first_bad < 0:
			first_bad = i
	return {"dist": worst, "tick": first_bad if first_bad >= 0 else worst_tick}


func _main() -> void:
	await physics_frame
	if FileAccess.file_exists(GHOST):
		DirAccess.remove_absolute(GHOST)
	var t0 := Time.get_ticks_msec()

	# 1. Joker route, fresh file: first valid lap saves.
	var r1 := await _run(&"joker", 1)
	var bytes1 := _bytes(GHOST)
	var lap1: Dictionary = r1.finished[0] if r1.finished.size() > 0 else {}
	cu.check(not r1.timer.laps.is_empty() and r1.finished.size() == r1.timer.laps.size(),
			"one lap_finished per LapTimer lap (%d vs %d)" % [r1.finished.size(), r1.timer.laps.size()])
	cu.check(lap1.get("valid") == true and lap1.get("saved") == true, "first valid lap saves (%s)" % str(lap1))
	cu.check(bytes1.size() > 0, "ghost file exists after the first valid lap")
	_dispose(r1.drive)
	await physics_frame

	# 2. Invalid laps (reset penalty) never save, even when faster.
	var r2 := await _run(&"main", 1, true)
	var f2: Dictionary = r2.finished[0] if r2.finished.size() > 0 else {}
	cu.check(f2.get("valid") == false and f2.get("saved") == false, "penalised lap: valid=false, saved=false (%s)" % str(f2))
	cu.check(f2.get("ticks", 1 << 30) < lap1.get("ticks", 0), "control: the invalid lap is faster than the saved best (%s vs %s)" % [f2.get("ticks"), lap1.get("ticks")])
	cu.check(_bytes(GHOST) == bytes1, "invalid lap leaves the ghost file byte-identical")
	_dispose(r2.drive)
	await physics_frame

	# 3. Main route, 2 laps: faster than the joker best, so it overwrites.
	var r3 := await _run(&"main", 2)
	var tt: TimeTrial = r3.tt
	var fin: Array = r3.finished
	cu.check(fin.size() == 2 and r3.timer.laps.size() == 2,
			"2 laps: lap_finished x2 matches LapTimer (%d/%d)" % [fin.size(), r3.timer.laps.size()])
	cu.check(tt.process_physics_priority > r3.drive.process_physics_priority,
			"TimeTrial runs after the node that steps the LapTimer (priority %d > %d)" % [tt.process_physics_priority, r3.drive.process_physics_priority])
	var same_tick: bool = fin.size() == r3.completed_at.size()
	for i in mini(fin.size(), r3.completed_at.size()):
		same_tick = same_tick and fin[i].timer_tick == r3.completed_at[i]
	cu.check(same_tick, "observe() handles each lap on the very tick the timer completed it")
	var best: GhostLap = tt.best
	cu.check(best != null and fin.size() == 2 and fin[1].saved == true, "faster flying lap overwrites the saved best")
	cu.check(_bytes(GHOST) != bytes1, "file bytes changed after the faster lap")
	if best != null and fin.size() == 2:
		var lap2_ticks: int = r3.timer.laps[1]["ticks"]
		var expect := ceili(best.ticks * 60.0 / 120.0)
		cu.check(absi(best.sample_count() - expect) <= 1, "60 Hz samples: %d vs ceil(ticks*60/120)=%d" % [best.sample_count(), expect])
		cu.check(absi(best.ticks - lap2_ticks) <= 1, "best.ticks %d vs LapTimer lap-2 ticks %d" % [best.ticks, lap2_ticks])
		var loaded := GhostLap.load_file(GHOST)
		cu.check(loaded != null and loaded.ticks == best.ticks and loaded.sample_count() == best.sample_count(),
				"saved file round-trips ticks and samples")
		# Ghost driven to its last sample.
		tt._replay_tick = best.ticks
		tt._update_ghost()
		var gp: Vector3 = tt.ghost.global_position
		var final_pose := best.pose_at_index(best.sample_count() - 1).origin
		cu.check_range("ghost at last sample vs recorded final pose (m)", gp.distance_to(final_pose), 0.0, 0.5)
		cu.check_range("ghost at last sample vs car at finish tick (m)", gp.distance_to(fin[1].pos), 0.0, 0.5)
		cu.check(tt.ghost.visible, "ghost is visible while replaying")
		print("INFO: main laps %d, %d ticks; joker best %d ticks; best.samples %d" % [fin[0].ticks, fin[1].ticks, lap1.get("ticks", -1), best.sample_count()])
	var bytes3 := _bytes(GHOST)
	var best_ticks: int = best.ticks if best != null else 1 << 30
	_dispose(r3.drive)
	await physics_frame

	# 5. Live replay of the saved best (#153): the ghost stays within 0.5 m of a car driving the same line.
	var r5 := await _run(&"main", 2, false, true)
	cu.check(_car_log.size() > 120 * 20, "live replay: lap-2 ticks logged (%d)" % _car_log.size())
	var live := _worst_ghost_dist()
	cu.check(live.dist <= GHOST_MAX_DIST,
			"ghost-to-car <= %.1f m on every lap-2 tick: worst %.3f m at lap tick %d" % [GHOST_MAX_DIST, live.dist, live.tick])
	var off := _worst_ghost_dist(CONTROL_OFFSET)
	cu.check(off.dist > GHOST_MAX_DIST, "negative control: ghost offset 1 m fails the check (worst %.3f m at tick %d)" % [off.dist, off.tick])
	var shifted := _worst_ghost_dist(Vector3.ZERO, CONTROL_SHIFT)
	cu.check(shifted.dist > GHOST_MAX_DIST, "negative control: ghost 0.2 s out of time fails the check (worst %.3f m at tick %d)" % [shifted.dist, shifted.tick])
	cu.check(r5.finished.size() == 2, "live replay run completed both laps")
	_dispose(r5.drive)
	await physics_frame

	# 4. Slower valid lap does not overwrite the faster best.
	var r4 := await _run(&"joker", 1)
	var f4: Dictionary = r4.finished[0] if r4.finished.size() > 0 else {}
	cu.check(f4.get("valid") == true and f4.get("saved") == false, "slower valid lap: valid=true, saved=false (%s)" % str(f4))
	cu.check(f4.get("ticks", 0) > best_ticks, "control: the joker lap is slower than the best")
	cu.check(_bytes(GHOST) == bytes3, "slower lap leaves the ghost file byte-identical")
	_dispose(r4.drive)
	await physics_frame

	var wall := (Time.get_ticks_msec() - t0) / 1000.0
	cu.check_range("wall time (s)", wall, 0.0, 90.0)
	DirAccess.remove_absolute(GHOST)
	for i in 5:
		await process_frame
	cu.finish(self)
