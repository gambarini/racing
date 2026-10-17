## AI driver check (#28): scene-level criteria.
##  1. Speed PI on a flat tarmac straight (Proving Ground): settles < 1 m/s within 4 s, no pedal overlap.
##  2. Quarry, M1 car, 2 consecutive laps under AiDriver through the DriverInput state: both laps
##     complete through all gates accepted by the LapTimer, no wrong-way flag, lap time bounds,
##     max cross-track error < road half width. Telemetry CSV is written (user://ai_driver_lap.csv).
##  3. Determinism: two further runs give identical lap ticks.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/ai_driver_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const Scenario := preload("res://tests/support/scenario.gd")
const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const LINE := "res://tracks/quarry/quarry_racing_line.tres"
const MAX_TICKS := 120 * 170
const SCRIPTED_REF := 63.95 ## s, scripted-driver flying lap (Track-Design wiki)

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _speed_hold() -> void:
	var ai := AiDriver.new()
	var target := 20.0
	var state := {"overlap": 0.0, "last_bad": 0.0}
	var ctrl := func(tick: int, v: Vehicle, st: DriverInputState) -> void:
		var sp := -v.global_transform.basis.z.dot(v.linear_velocity)
		var t := ai.speed_control(target, sp, 1.0 / 120.0)
		st.throttle = maxf(t, 0.0)
		st.brake = maxf(-t, 0.0)
		state.overlap = maxf(state.overlap, minf(st.throttle, st.brake))
		if absf(target - sp) >= 1.0:
			state.last_bad = float(tick) / 120.0
	var sc := Scenario.new(self, "Spawn_Flat", [], 120 * 8)
	sc.initial_speed = 8.0
	sc.controller = ctrl
	var r: Dictionary = await sc.run()
	cu.check_range("PI: last time |speed error| >= 1 m/s (s)", state.last_bad, 0.0, 4.0)
	cu.check_range("PI: max pedal overlap", state.overlap, 0.0, 0.1)
	cu.check_range("PI: final speed error (m/s)", absf(target - r.end_speed), 0.0, 1.0)


func _lap_run(csv := "") -> Dictionary:
	var drive: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	drive.get_node("Vehicle/VehicleAudio").free()
	drive.get_node("TimeTrial").ghost_path = "user://ai_driver_check.dat"
	root.add_child(drive)
	await physics_frame
	var line: RacingLine = load(LINE)
	var ai := AiDriver.new()
	ai.setup(line, MAX_TICKS if csv != "" else 0)
	ai.telemetry_enabled = csv != ""
	for k in OS.get_environment("AI_TUNE").split(",", false):
		var kv := k.split("=")
		ai.set(kv[0], float(kv[1]))
	drive.ai_driver = ai
	var wrong := WrongWayDetector.new()
	var wrong_ticks := 0
	var max_ct := 0.0
	var max_centre := 0.0
	var ticks := 0
	var lt := drive.lap_timer
	while lt.laps.size() < 2 and ticks < MAX_TICKS:
		await physics_frame
		ticks += 1
		var v: Vehicle = drive.vehicle
		var tg := line.tangent_at(ai.s)
		if wrong.step(v.linear_velocity, tg):
			wrong_ticks += 1
		max_ct = maxf(max_ct, absf(ai.cross_track))
		# distance from the road centre line = line lane offset + car offset from the line
		var centre := absf(line.lane_offset_at(ai.s) - ai.cross_track)
		max_centre = maxf(max_centre, centre)
	if csv != "":
		ai.save_telemetry(csv)
	var out := {"laps": lt.laps.duplicate(), "ticks": ticks, "wrong_ticks": wrong_ticks, "max_ct": max_ct,
			"max_centre": max_centre, "out_of_order": lt.out_of_order_crossings, "gates": lt.gates.size(),
			"grass": drive.grass_ticks, "pos": drive.vehicle.global_position, "rows": ai.telemetry_rows}
	drive.queue_free()
	await physics_frame
	return out


func _main() -> void:
	await physics_frame
	await _speed_hold()

	var warm := await _lap_run(OS.get_environment("AI_CSV") if OS.get_environment("AI_CSV") != "" else "user://ai_driver_lap.csv")
	var a := await _lap_run()
	var b := await _lap_run()
	for r in [warm, a]:
		cu.check(r.laps.size() >= 2, "two consecutive laps completed (%d)" % r.laps.size())
	cu.check(a.gates == 12, "track has 12 gates (%d)" % a.gates)
	cu.check(a.out_of_order == 0 and warm.out_of_order == 0, "LapTimer accepted every gate in order (out-of-order crossings %d)" % a.out_of_order)
	cu.check(a.wrong_ticks == 0, "zero wrong-way flags (%d ticks)" % a.wrong_ticks)
	if a.laps.size() >= 2:
		var t1: float = a.laps[0]["raw_time"]
		var t2: float = a.laps[1]["raw_time"]
		print("INFO: lap 1 %.3f s, lap 2 %.3f s, max cross-track from line %.2f m, from centre %.2f m, grass ticks %d, line predicts %.2f s" % [
				t1, t2, a.max_ct, a.max_centre, a.grass, (load(LINE) as RacingLine).predicted_lap_time()])
		cu.check_range("lap 1 time (s)", t1, 55.0, 75.0)
		cu.check_range("lap 2 (flying) time (s)", t2, 55.0, 75.0)
		cu.check_range("flying lap vs scripted reference (ratio)", t2 / SCRIPTED_REF, 0.0, 1.10)
	cu.check_range("max centre-line offset (m) vs road half width 6.5", a.max_centre, 0.0, 6.5)
	cu.check(warm.rows > 1000, "telemetry rows recorded (%d)" % warm.rows)
	cu.check(a.ticks == b.ticks and a.pos == b.pos, "deterministic: identical ticks %d / %d and end position" % [a.ticks, b.ticks])
	var la: Array = a.laps
	var lb: Array = b.laps
	var same := la.size() == lb.size()
	for i in mini(la.size(), lb.size()):
		same = same and la[i]["ticks"] == lb[i]["ticks"]
	cu.check(same, "identical lap ticks across two runs")
	for i in 5:
		await process_frame
	cu.finish(self)
