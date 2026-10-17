## RaceManager on the Quarry (#149): grid slots for 2/8/12 cars lie in the flat start zone on tarmac
## with slope < 0.1 deg and no overlaps, then a short standing-start race with scripted autopilot
## cars (one deliberately ignores the pre-GO lock = jump start): countdown, same-tick GO, live
## positions, penalty ledger, finish and results. 1 lap, 4 cars.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/race_manager_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const CARS := 4
const JUMPER := 3
const MAX_TICKS := 120 * 150
const CAR_W := 1.8
const CAR_L := 4.2

var cu := CheckUtil.new()


## Drives the extra cars: lock, autopilot, apply_input, in a fixed order before the manager steps.
class Harness extends Node:
	var mgr: RaceManager
	var vehicles: Array[Vehicle] = []
	var pilots: Array[QuarryDriver] = []
	var states: Array[DriverInputState] = []
	var ungated := {}

	func _physics_process(delta: float) -> void:
		for i in vehicles.size():
			pilots[i].drive(vehicles[i], states[i], delta)
			if not ungated.has(i):
				mgr.gate_input(states[i])
			vehicles[i].apply_input(states[i])


func _initialize() -> void:
	_main()


func _clearance(a: Transform3D, b: Transform3D) -> float:
	var rel := a.affine_inverse() * b.origin
	return maxf(absf(rel.x) - CAR_W, absf(rel.z) - CAR_L)


func _grid_checks(drive: QuarryDrive, mgr: RaceManager) -> void:
	var terrain := drive.quarry.terrain
	var max_slope := 0.0
	var not_tarmac := 0
	var min_clear := 1.0e9
	var min_s := 1.0e9
	var max_s := -1.0e9
	for count in [2, 8, 12]:
		for i in count:
			var xf := mgr.grid_transform(i, count)
			var fwd := -xf.basis.z
			var p := xf.origin
			var front := p + fwd * (CAR_L * 0.5)
			var rear := p - fwd * (CAR_L * 0.5)
			var dh := terrain.height_at(front.x, front.z) - terrain.height_at(rear.x, rear.z)
			max_slope = maxf(max_slope, absf(rad_to_deg(atan2(dh, CAR_L))))
			for q in [front, rear, p]:
				if terrain.dominant_surface_at(q.x, q.z) != &"tarmac":
					not_tarmac += 1
			var s := drive.quarry.track.nearest_offset(p)
			s = s - drive.quarry.track.length() if s > drive.quarry.track.length() * 0.5 else s
			min_s = minf(min_s, s - CAR_L * 0.5)
			max_s = maxf(max_s, s)
			for j in range(i + 1, count):
				min_clear = minf(min_clear, _clearance(xf, mgr.grid_transform(j, count)))
	cu.check_range("grid slope over the car length (deg)", max_slope, 0.0, 0.1)
	cu.check(not_tarmac == 0, "all slot footprints on tarmac (%d off)" % not_tarmac)
	cu.check_range("grid min car-box clearance (m)", min_clear, 0.5, 100.0)
	cu.check_range("grid rearmost bumper s (m)", min_s, -80.0, 60.0)
	cu.check_range("grid frontmost s (m)", max_s, -80.0, 60.0)


func _main() -> void:
	await physics_frame
	var t0 := Time.get_ticks_msec()
	var drive: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	drive.get_node("Vehicle/VehicleAudio").free()
	drive.get_node("TimeTrial").ghost_path = "user://race_manager_check_ghost.dat"
	root.add_child(drive)
	await physics_frame
	drive.set_physics_process(false) # the harness and the manager drive and time the cars
	drive.time_trial.set_physics_process(false)
	var q := drive.quarry
	var mgr := RaceManager.new()
	mgr.setup(q.track, 1)
	root.add_child(mgr)
	_grid_checks(drive, mgr)

	var harness := Harness.new()
	harness.mgr = mgr
	root.add_child(harness)
	var pts := q.route_points(&"main", &"tarmac")
	for i in CARS:
		var v: Vehicle = drive.vehicle
		if i > 0:
			v = Vehicle.new()
			v.surface_map = q.terrain.surface_map
			drive.add_child(v)
		var xf := mgr.grid_transform(i, CARS)
		xf.origin.y = q.terrain.height_at(xf.origin.x, xf.origin.z) + drive.spawn_lift
		v.global_transform = xf
		var drv := QuarryDriver.new()
		drv.setup(pts, q.route_mu(pts))
		harness.vehicles.append(v)
		harness.pilots.append(drv)
		harness.states.append(DriverInputState.new())
		mgr.add_car(v)
	harness.ungated[JUMPER] = true
	await physics_frame

	var events: Array[String] = []
	var go_tick := [0]
	var timers_running_at_go := [0]
	mgr.countdown_tick.connect(func(n: int) -> void: events.append("count %d @%d" % [n, mgr.tick]))
	mgr.race_started.connect(func() -> void:
		go_tick[0] = mgr.tick
		for t in mgr.timers:
			if t.running and t.tick == mgr.timers[0].tick:
				timers_running_at_go[0] += 1)
	var results: Array = []
	mgr.race_finished.connect(func(r: Array) -> void: results.assign(r))
	var rank_log := {}
	mgr.start_countdown()
	var ticks := 0
	while mgr.state != RaceManager.State.FINISHED and ticks < MAX_TICKS:
		await physics_frame
		ticks += 1
		if ticks % 1200 == 0 and mgr.state == RaceManager.State.RACING:
			var line := ""
			for r in CARS:
				line += " P%d=car%d(gap %.1fs)" % [r + 1, mgr.order[r], mgr.gap_ahead(mgr.order[r])]
			print("INFO: t=%ds%s" % [ticks / 120, line])
		if ticks == 100:
			rank_log["pre_go"] = Array(mgr.order)
	print("INFO: ", events, " GO @", go_tick[0], " finished after ", ticks, " ticks")

	cu.check(events.size() == 3, "three countdown ticks (%s)" % str(events))
	cu.check(go_tick[0] > 0 and timers_running_at_go[0] == CARS, "all %d timers started on the GO tick" % CARS)
	cu.check(rank_log.get("pre_go") == [0, 1, 2, 3], "grid order before GO is slot order (%s)" % str(rank_log.get("pre_go")))
	cu.check(mgr.jump_started[JUMPER] and mgr.penalty_seconds[JUMPER] == 5.0, "deliberate early car flagged +5 s")
	cu.check(mgr.ledger.size() >= 1 and mgr.ledger[0]["reason"] == &"jump_start", "ledger reason jump_start")
	var others_ok := true
	for i in CARS:
		if i != JUMPER and mgr.jump_started[i]:
			others_ok = false
	cu.check(others_ok, "gated cars not flagged")
	cu.check(mgr.state == RaceManager.State.FINISHED and results.size() == CARS, "race_finished with %d results" % results.size())
	for r in results:
		print("INFO: result ", r)
	var sorted_ok := true
	for i in range(1, results.size()):
		if not results[i - 1]["dnf"] and not results[i]["dnf"] and results[i - 1]["time"] > results[i]["time"]:
			sorted_ok = false
	cu.check(sorted_ok, "results ordered by time")
	if results.size() > 0:
		var first_t: float = results[0]["race_time"]
		cu.check_range("winner race time, 1 lap from the grid (s)", first_t, 55.0, 110.0)

	var wall := (Time.get_ticks_msec() - t0) / 1000.0
	cu.check_range("wall time (s)", wall, 0.0, 120.0)
	for pl in drive.find_children("*", "AudioStreamPlayer", true, false):
		pl.stop()
	drive.queue_free()
	mgr.queue_free()
	harness.queue_free()
	for i in 5:
		await process_frame
	cu.finish(self)
