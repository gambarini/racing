## AI personality check (#30): scene-level criteria on the Quarry.
##  1. Solo AI per difficulty preset (Easy / Medium / Hard mean personality), 4 laps: flying-lap time
##     strictly ordered Easy > Medium > Hard, each step >= 1.0 s/lap (estimate); 3+ laps complete;
##     max centre-line offset <= road half width.
##  2. Consistency 0.2 vs 1.0 at the same skill: std-dev of 5 flying laps larger for 0.2; 1.0 injects
##     no errors (mistake count 0).
##  3. Same-car fairness: 8 identical cars, Medium field (seeded personalities, tactics on, real
##     RaceManager): per-AI best-lap spread (best - worst) in [0.5, 4] s (estimate).
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/ai_personality_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const LINE := "res://tracks/quarry/quarry_racing_line.tres"
const DT := 1.0 / 120.0
const SOLO_LAPS := 4
const MIN_STEP := 1.0 ## s per lap between presets (estimate)
const ROAD_HALF := 6.5
const FIELD := 8
const FIELD_LAPS := 4
const FIELD_SEED := 2026
const SPREAD_MIN := 0.5 ## s (estimate)
const SPREAD_MAX := 4.0 ## s (estimate)

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


static func _mean_personality(difficulty: int) -> AiPersonality:
	var p := AiPersonality.new()
	p.skill = AiPersonality.MEAN_SKILL[difficulty]
	p.consistency = AiPersonality.MEAN_CONSISTENCY[difficulty]
	return p


static func _std(xs: Array) -> float:
	var m := 0.0
	for x: float in xs:
		m += x
	m /= maxf(xs.size(), 1)
	var ss := 0.0
	for x: float in xs:
		ss += (x - m) * (x - m)
	return sqrt(ss / maxf(xs.size(), 1))


static func _mean(xs: Array) -> float:
	var m := 0.0
	for x: float in xs:
		m += x
	return m / maxf(xs.size(), 1)


## Solo run of `laps` laps with personality `p`. Returns lap times (s), max centre offset, grass
## ticks, mistakes.
func _solo(p: AiPersonality, laps: int, seed_value := 1) -> Dictionary:
	var drive: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	drive.get_node("Vehicle/VehicleAudio").free()
	drive.get_node("TimeTrial").ghost_path = "user://ai_personality_check.dat"
	root.add_child(drive)
	await physics_frame
	var base: RacingLine = load(LINE)
	var ai := drive.start_ai(base)
	ai.setup_personality(base, p, seed_value)
	var lt := drive.lap_timer
	var ticks := 0
	var max_centre := 0.0
	var max_ticks := 120 * 120 * laps
	while lt.laps.size() < laps and ticks < max_ticks:
		await physics_frame
		ticks += 1
		max_centre = maxf(max_centre, absf(ai.line.lane_offset_at(ai.s) - ai.cross_track))
	var times: Array = []
	for rec in lt.laps:
		times.append(float(rec["raw_time"]))
	var out := {"times": times, "max_centre": max_centre, "grass": drive.grass_ticks, "mistakes": ai.mistakes}
	drive.queue_free()
	await physics_frame
	return out


func _flying(times: Array) -> Array:
	return times.slice(1)


func _presets() -> void:
	var means := []
	var names := ["Easy", "Medium", "Hard"]
	for d in 3:
		var r: Dictionary = await _solo(_mean_personality(d), SOLO_LAPS)
		var fl := _flying(r.times)
		means.append(_mean(fl))
		print("INFO: %s (skill %.3f, consistency %.2f): laps %s, flying mean %.3f s, max centre %.2f m, grass ticks %d, mistakes %d" % [
				names[d], AiPersonality.MEAN_SKILL[d], AiPersonality.MEAN_CONSISTENCY[d], str(r.times), means[d], r.max_centre, r.grass, r.mistakes])
		cu.check(r.times.size() >= 3, "%s completes 3+ laps (%d)" % [names[d], r.times.size()])
		cu.check_range("%s max centre-line offset (m) vs road half width" % names[d], r.max_centre, 0.0, ROAD_HALF)
	cu.check(means[0] - means[1] >= MIN_STEP, "Easy - Medium >= %.1f s/lap (%.3f)" % [MIN_STEP, means[0] - means[1]])
	cu.check(means[1] - means[2] >= MIN_STEP, "Medium - Hard >= %.1f s/lap (%.3f)" % [MIN_STEP, means[1] - means[2]])


func _consistency() -> void:
	var stds := {}
	for c in [0.2, 1.0]:
		var p := AiPersonality.new()
		p.skill = AiPersonality.MEAN_SKILL[1]
		p.consistency = c
		var r: Dictionary = await _solo(p, 6)
		var fl := _flying(r.times)
		stds[c] = _std(fl)
		print("INFO: consistency %.1f: 5 flying laps %s, std %.3f s, mistakes %d, max centre %.2f m" % [c, str(fl), stds[c], r.mistakes, r.max_centre])
		cu.check(fl.size() >= 5, "consistency %.1f completes 5 flying laps (%d)" % [c, fl.size()])
		cu.check_range("consistency %.1f max centre-line offset (m)" % c, r.max_centre, 0.0, ROAD_HALF)
		if c == 1.0:
			cu.check(r.mistakes == 0, "consistency 1.0 injects no errors (%d)" % r.mistakes)
		else:
			cu.check(r.mistakes > 0, "consistency 0.2 makes mistakes (%d)" % r.mistakes)
	cu.check(stds[0.2] > stds[1.0], "lap std-dev larger at consistency 0.2 (%.3f s) than 1.0 (%.3f s)" % [stds[0.2], stds[1.0]])


## 8 identical cars (the default Vehicle), a Medium field with tactics, standing start.
func _field() -> void:
	var drive: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	drive.get_node("Vehicle/VehicleAudio").free()
	drive.get_node("TimeTrial").ghost_path = "user://ai_personality_check.dat"
	root.add_child(drive)
	await physics_frame
	drive.set_physics_process(false)
	drive.time_trial.set_physics_process(false)
	var base: RacingLine = load(LINE)
	var mgr := RaceManager.new()
	mgr.setup(drive.quarry.track, FIELD_LAPS)
	root.add_child(mgr)
	mgr.set_physics_process(false)
	var vehicles: Array[Vehicle] = []
	var drivers: Array[AiDriver] = []
	var states: Array[DriverInputState] = []
	var pos := PackedVector3Array()
	var spd := PackedFloat32Array()
	var field := AiPersonality.make_field(AiPersonality.Difficulty.MEDIUM, FIELD, FIELD_SEED)
	for i in FIELD:
		var v: Vehicle = drive.vehicle
		if i > 0:
			v = Vehicle.new()
			v.surface_map = drive.quarry.terrain.surface_map
			drive.add_child(v)
		var xf := mgr.grid_transform(i, FIELD)
		xf.origin.y = drive.quarry.terrain.height_at(xf.origin.x, xf.origin.z) + drive.spawn_lift
		v.global_transform = xf
		vehicles.append(v)
		var ai := AiDriver.new()
		ai.setup_personality(base, field[i], FIELD_SEED + i)
		mgr.add_car(null)
		ai.attach_tactics(mgr, i, FIELD_SEED)
		drivers.append(ai)
		states.append(DriverInputState.new())
		pos.append(xf.origin)
		spd.append(0.0)
	var pilot := Node.new()
	pilot.set_script(preload("res://tests/support/field_pilot.gd"))
	pilot.vehicles = vehicles
	pilot.drivers = drivers
	pilot.states = states
	pilot.pos = pos
	pilot.spd = spd
	pilot.mgr = mgr
	root.add_child(pilot)
	await physics_frame
	mgr.start_countdown()
	var t := 0
	while mgr.state != RaceManager.State.FINISHED and t < 120 * 100 * FIELD_LAPS:
		await physics_frame
		t += 1
	cu.check(mgr.state == RaceManager.State.FINISHED, "field race finished (%d ticks)" % t)
	var bests := []
	for i in FIELD:
		var best := 1.0e9
		var laps: Array = []
		for rec in mgr.timers[i].laps:
			laps.append(snappedf(rec["ticks"] * DT, 0.01))
			best = minf(best, rec["ticks"] * DT)
		bests.append(best)
		print("INFO: car %d skill %.3f consistency %.2f: laps %s, best %.2f s, centre max %.2f m, mistakes %d" % [
				i, field[i].skill, field[i].consistency, str(laps), best, pilot.max_centre[i], drivers[i].mistakes])
	var lo := 1.0e9
	var hi := 0.0
	for b: float in bests:
		lo = minf(lo, b)
		hi = maxf(hi, b)
	print("INFO: field spread (best - worst per-AI best lap) %.3f s over %d cars, contacts %d" % [hi - lo, FIELD, pilot.contacts])
	cu.check_range("Medium field per-AI best-lap spread (s)", hi - lo, SPREAD_MIN, SPREAD_MAX)
	pilot.queue_free()
	for v in vehicles:
		if v != drive.vehicle:
			v.queue_free()
	mgr.queue_free()
	drive.queue_free()
	await physics_frame


func _main() -> void:
	await physics_frame
	await _presets()
	await _consistency()
	await _field()
	for i in 5:
		await process_frame
	cu.finish(self)
