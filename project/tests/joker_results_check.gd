## Joker enforcement, penalty ledger and results on the Quarry (#150): scripted cars (teleported
## along the route polylines at a fixed speed, no physics) race 2 laps under RaceManager.step().
## Car 0 takes the joker in lap 1, car 1 never, car 2 never but gets a reset penalty through
## LapTimer, car 3 retires (DNF), car 4 takes the joker on both laps.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/joker_results_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const SPEED := 40.0  ## m/s, every car
const LAPS := 2
const LEAD_IN := 20.0  ## m before the line

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


## tail of the main loop + one polyline per lap + a few points past the line.
func _path(main: PackedVector3Array, laps: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var lead := int(LEAD_IN / 1.5)
	for i in range(main.size() - lead, main.size()):
		out.append(main[i])
	for lap in laps:
		out.append_array(lap)
	for i in 12:
		out.append(main[i])
	return out


func _main() -> void:
	await physics_frame
	var quarry: Quarry = (load("res://tracks/quarry/quarry.tscn") as PackedScene).instantiate()
	root.add_child(quarry)
	await physics_frame
	var main := quarry.route_points(&"main", &"tarmac")
	var jok := quarry.route_points(&"joker", &"tarmac")
	var paths: Array[PackedVector3Array] = [
		_path(main, [jok, main]), _path(main, [main, main]), _path(main, [main, main]),
		_path(main, [main, main]), _path(main, [jok, jok])]
	var n := paths.size()
	var cum: Array[PackedFloat32Array] = []
	for p in paths:
		var c := PackedFloat32Array()
		c.resize(p.size())
		var acc := 0.0
		for i in p.size():
			if i > 0:
				acc += p[i].distance_to(p[i - 1])
			c[i] = acc
		cum.append(c)

	var mgr := RaceManager.new()
	mgr.setup(quarry.track, LAPS)
	mgr.finish_grace_seconds = 600.0
	root.add_child(mgr)
	mgr.set_physics_process(false)
	for i in n:
		mgr.add_car(null, "Scripted %d" % i)
	mgr.retire(3)
	var results: Array = []
	mgr.race_finished.connect(func(r: Array) -> void: results.assign(r))
	var avail_before := mgr.joker_available(0)
	var idx := PackedInt32Array()
	idx.resize(n)
	var pos := PackedVector3Array()
	pos.resize(n)
	var spd := PackedFloat32Array()
	spd.resize(n)
	var dist := 0.0
	for i in n:
		pos[i] = paths[i][0]
	mgr.start_countdown()
	var went := false
	var avail_racing := false
	var reset_done := false
	var guard := 0
	while mgr.state != RaceManager.State.FINISHED and guard < 120 * 400:
		guard += 1
		if mgr.state == RaceManager.State.RACING:
			if not went:
				went = true
				avail_racing = mgr.joker_available(0)
			dist += SPEED / 120.0
			for i in n:
				if i == 3:
					pos[i] = paths[3][0]
					spd[i] = 0.0
					continue
				var c := cum[i]
				while idx[i] + 1 < c.size() - 1 and c[idx[i] + 1] < dist:
					idx[i] += 1
				var j: int = mini(idx[i], c.size() - 2)
				var f := clampf((dist - c[j]) / maxf(c[j + 1] - c[j], 1e-6), 0.0, 1.0)
				pos[i] = paths[i][j].lerp(paths[i][j + 1], f)
				spd[i] = SPEED
			if not reset_done and mgr.tick - mgr.go_tick > 600:
				reset_done = true
				mgr.timers[2].add_penalty(5.0)  # what RaceMonitor.reset_to_track() does
		mgr.step(pos, spd)
	print("INFO: ticks ", guard, " state ", mgr.state)
	cu.check(mgr.state == RaceManager.State.FINISHED and results.size() == n, "race finished with %d results" % results.size())
	var by_car := {}
	for r in results:
		by_car[r["car"]] = r
		print("INFO: ", r)
	cu.check(not avail_before and avail_racing, "joker_available false before GO, true once racing")
	cu.check(mgr.joker_taken[0] and mgr.joker_lap[0] == 1, "car 0 flagged joker in lap 1 (lap %d)" % mgr.joker_lap[0])
	cu.check(not mgr.joker_taken[1] and not mgr.joker_taken[2], "main line cars not flagged")
	cu.check(mgr.joker_taken[4] and mgr.joker_lap[4] == 1 and mgr.timers[4].joker_crossings == 2, "car 4 used the joker twice, lap 1 recorded")
	cu.check(not mgr.joker_available(0), "joker_available false after use / finish")
	var miss := 0
	for e in mgr.ledger:
		if e["reason"] == RaceManager.JOKER_REASON:
			miss += 1
			cu.check(e["car"] == 1 or e["car"] == 2, "joker_missed on a main-line car (%d)" % e["car"])
	cu.check(miss == 2, "exactly two joker_missed entries (%d)" % miss)
	cu.check_range("car 0 penalties (s)", by_car[0]["penalties"], 0.0, 0.0)
	cu.check_range("car 4 penalties (s), second use is free", by_car[4]["penalties"], 0.0, 0.0)
	cu.check_range("car 1 penalties (s)", by_car[1]["penalties"], 10.0, 10.0)
	cu.check_range("car 2 penalties (s), joker 10 + reset 5", by_car[2]["penalties"], 15.0, 15.0)
	cu.check(by_car[2]["penalty_list"].size() == 2, "car 2 ledger lists joker_missed and reset")
	var reasons := []
	for e in by_car[2]["penalty_list"]:
		reasons.append(e["reason"])
	cu.check(reasons.has(&"joker_missed") and reasons.has(&"reset"), "car 2 reasons %s" % str(reasons))
	cu.check(by_car[3]["dnf"] and by_car[3]["penalties"] == 0.0 and results[n - 1]["car"] == 3, "DNF car last, no joker penalty")
	cu.check(by_car[1]["joker_taken"] == false and by_car[0]["joker_taken"] == true, "results carry joker_taken")
	# Skipping the joker is never faster: same speed, so the joker car is slower on the road by its detour cost.
	var cost: float = by_car[0]["race_time"] - by_car[1]["race_time"]
	var gap: float = by_car[1]["time"] - by_car[0]["time"]
	print("INFO: joker road cost %.3f s, results gap %.3f s" % [cost, gap])
	cu.check(gap > 0.0, "car with the joker ranks ahead of the same car without")
	cu.check_range("results gap = 10 - road cost (s)", gap, 10.0 - cost - 0.01, 10.0 - cost + 0.01)
	cu.check_range("results gap >= 10 - 2.54 s within 0.5 s", gap, 10.0 - 2.54 - 0.5, 100.0)
	cu.check(by_car[0]["rank"] < by_car[1]["rank"], "ranked by time + penalties")
	# Laps stay raw; best lap is a raw lap time.
	var raw_lap: float = mgr.timers[2].laps[0]["raw_time"]
	cu.check_range("car 2 best lap is raw (s)", by_car[2]["best_lap"], minf(raw_lap, mgr.timers[2].laps[1]["raw_time"]), minf(raw_lap, mgr.timers[2].laps[1]["raw_time"]))
	cu.check(by_car[2]["name"] == "Scripted 2", "name in results")
	mgr.queue_free()
	quarry.queue_free()
	for i in 3:
		await process_frame
	cu.finish(self)
