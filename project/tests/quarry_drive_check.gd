## Quarry drive test (#104): the M1 car laps the Quarry under a scripted path-following driver and
## the run is checked against the issue's criteria:
##  - joker route exists, is marked (entry/rejoin markers, joker gate flagged in the lap record) and
##    is 2-3 s slower than the main route over a flying lap,
##  - the telemetry CSV of a flying lap holds a crest (vert_g < -0.3) and a compression (vert_g > 0.5),
##    and the flat start zone has neither,
##  - a flying lap of the main route takes 55-75 s and never leaves the surface map,
##  - the first corner has two scripted lines ("tarmac" outside, "inside" over a loose gravel lane)
##    that are genuinely different (>= 4 m apart, the inside one rolls over gravel) and finish within
##    1.5 s of each other.
## A "flying lap" is the second lap of a run: lap 1 starts from the grid.
## CSVs: user://quarry_lap_main.csv, quarry_lap_joker.csv, quarry_lap_inside.csv
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/quarry_drive_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const SMOOTH := 8 ## rows (67 ms) of moving average applied to vert_g before thresholds
const MAX_TICKS := 120 * 160
const GHOST := "user://test_ghost_quarry_drive.dat" ## never the player's user://ghost_best.dat (#153)

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


## Two laps of `route` along `line`; returns the flying-lap record plus run statistics.
func _run(route: StringName, line: StringName, csv: String) -> Dictionary:
	var drive: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	drive.get_node("TimeTrial").ghost_path = GHOST
	root.add_child(drive)
	await physics_frame
	var q := drive.quarry
	var pts := q.route_points(route, line)
	var drv := QuarryDriver.new()
	drv.setup(pts, q.route_mu(pts))
	drive.autopilot = drv
	var s_of := PackedFloat32Array() # path distance per tick, aligned with the CSV rows
	s_of.resize(MAX_TICKS)
	var gravel_ticks := 0 # ticks with a wheel on gravel while in the first corner
	var lane_lo := float(Quarry.LANES[0]["a"])
	var lane_hi := float(Quarry.LANES[0]["b"])
	var ticks := 0
	var lap1_end_tick := -1
	while drive.lap_timer.laps.size() < 2 and ticks < MAX_TICKS:
		await physics_frame
		s_of[ticks] = drv.cum[drv.index]
		ticks += 1
		if lap1_end_tick < 0 and drive.lap_timer.laps.size() == 1:
			lap1_end_tick = ticks
		var s := s_of[ticks - 1]
		if s > lane_lo and s < lane_hi:
			for w in drive.vehicle.wheels:
				if w.is_grounded and w.surface_id == &"gravel":
					gravel_ticks += 1
					break
	var out := {
		"lap": drive.lap_timer.laps[1] if drive.lap_timer.laps.size() > 1 else {},
		"laps": drive.lap_timer.laps.size(), "ticks": ticks, "lap1_end_tick": lap1_end_tick,
		"grass_ticks": drive.grass_ticks, "offmap_ticks": drive.offmap_ticks,
		"gravel_ticks": gravel_ticks, "s_of": s_of, "path_len": drv.length,
		"csv": drive.recorder.dump(csv), "points": pts,
	}
	var lap: Dictionary = out.lap
	var lap1: Dictionary = drive.lap_timer.laps[0] if drive.lap_timer.laps.size() > 0 else {}
	print("INFO: %s/%s flying lap %.3f s, joker=%s, lap 1 %.2f s, grass ticks %d, off-map ticks %d, gravel ticks in corner %d" % [
			route, line, lap.get("raw_time", -1.0), lap.get("joker"), lap1.get("raw_time", -1.0),
			drive.grass_ticks, drive.offmap_ticks, gravel_ticks])
	drive.queue_free()
	await physics_frame
	return out


## Reads a telemetry CSV; header must hold vert_g and speed_kmh.
func _read_csv(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	var header := f.get_line().split(",")
	var iv := header.find("vert_g")
	var isp := header.find("speed_kmh")
	var vert := PackedFloat32Array()
	var speed := PackedFloat32Array()
	while not f.eof_reached():
		var cells := f.get_line().split(",")
		if cells.size() != header.size():
			continue
		vert.append(float(cells[iv]))
		speed.append(float(cells[isp]))
	return {"has_col": iv >= 0, "vert": vert, "speed": speed, "rows": vert.size()}


func _smooth(a: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(a.size())
	var acc := 0.0
	for i in a.size():
		acc += a[i]
		if i >= SMOOTH:
			acc -= a[i - SMOOTH]
		out[i] = acc / minf(float(i + 1), float(SMOOTH))
	return out


func _main() -> void:
	await physics_frame
	DirAccess.remove_absolute(GHOST) # every run starts without a ghost (#153)
	var main := await _run(&"main", &"tarmac", "user://quarry_lap_main.csv")
	var joker := await _run(&"joker", &"tarmac", "user://quarry_lap_joker.csv")
	var inside := await _run(&"main", &"inside", "user://quarry_lap_inside.csv")
	var q := Quarry.new()
	root.add_child(q)
	await physics_frame

	# Lap completion, time window and map bounds.
	for r in [main, joker, inside]:
		cu.check(r.laps >= 2 and not r.lap.is_empty(), "the car completes two laps (flying lap recorded)")
		cu.check(r.offmap_ticks == 0, "the car never leaves the surface map (%d ticks outside)" % r.offmap_ticks)
	var t_main: float = main.lap.get("raw_time", 0.0)
	var t_joker: float = joker.lap.get("raw_time", 0.0)
	var t_inside: float = inside.lap.get("raw_time", 0.0)
	cu.check_range("main route flying lap (s)", t_main, 55.0, 75.0, main.csv)
	cu.check(main.grass_ticks == 0, "main route flying lap stays on the road (%d grass ticks)" % main.grass_ticks)

	# Joker.
	cu.check(main.lap.get("joker") == false, "the main-route lap is not flagged as a joker lap")
	cu.check(joker.lap.get("joker") == true, "the joker-route lap is flagged by the joker gate")
	cu.check_range("joker route time loss (s)", t_joker - t_main, 2.0, 3.0, joker.csv)
	cu.check(q.has_node("JokerEntry") and q.has_node("JokerRejoin"), "joker entry and rejoin points are marked")
	var rejoin: Vector3 = q.get_node("JokerRejoin").position
	var main_at: Vector3 = q.track.sample(Quarry.JOKER_B)["position"]
	cu.check_range("joker rejoin to main line distance (m)", Vector2(rejoin.x, rejoin.z).distance_to(Vector2(main_at.x, main_at.z)), 0.0, 3.0)
	var entry: Vector3 = q.get_node("JokerEntry").position
	main_at = q.track.sample(Quarry.JOKER_A)["position"]
	cu.check_range("joker entry to main line distance (m)", Vector2(entry.x, entry.z).distance_to(Vector2(main_at.x, main_at.z)), 0.0, 3.0)
	print("INFO: joker detour %.0f m vs main %.0f m over the same span" % [q.joker_length, Quarry.JOKER_B - Quarry.JOKER_A])

	# Two lines at the first corner.
	var max_sep := 0.0
	var pa: PackedVector3Array = main.points
	var pb: PackedVector3Array = inside.points
	for i in pa.size():
		max_sep = maxf(max_sep, Vector2(pa[i].x, pa[i].z).distance_to(Vector2(pb[i].x, pb[i].z)))
	cu.check_range("separation of the two scripted lines at the apex (m)", max_sep, 4.0, 12.0)
	cu.check(inside.gravel_ticks > 100 and main.gravel_ticks == 0,
			"the inside line rolls over the gravel lane (%d ticks), the tarmac line does not (%d)" % [inside.gravel_ticks, main.gravel_ticks])
	cu.check(inside.grass_ticks == 0, "inside line stays on the road (%d grass ticks)" % inside.grass_ticks)
	cu.check_range("lap time difference of the two lines (s)", absf(t_main - t_inside), 0.0, 1.5)
	print("INFO: two lines: tarmac %.3f s, inside %.3f s (delta %+.3f s)" % [t_main, t_inside, t_inside - t_main])

	# Telemetry CSV of the flying lap: crest and compression, none on the flat start zone.
	var csv := _read_csv(main.csv)
	cu.check(csv.has_col, "telemetry CSV has a vert_g column")
	var vert := _smooth(csv.vert)
	var s_of: PackedFloat32Array = main.s_of
	var len: float = main.path_len
	var first := int(main.lap1_end_tick)
	var last := int(main.ticks)
	cu.check(csv.rows >= last, "CSV holds the whole run (%d rows, %d ticks)" % [csv.rows, last])
	var vmax := -9.0
	var vmin := 9.0
	var s_max := 0.0
	var s_min := 0.0
	var flat_lo := 9.0
	var flat_hi := -9.0
	var flat_rows := 0
	for i in range(first, mini(last, vert.size())):
		var s := s_of[i]
		if vert[i] > vmax:
			vmax = vert[i]
			s_max = s
		if vert[i] < vmin:
			vmin = vert[i]
			s_min = s
		var rel := fposmod(s + 100.0, len) - 100.0 # -100 .. len - 100 around the start line
		if rel > -60.0 and rel < 40.0 and csv.speed[i] > 100.0:
			flat_rows += 1
			flat_lo = minf(flat_lo, vert[i])
			flat_hi = maxf(flat_hi, vert[i])
	print("INFO: vert_g flying lap: max %.2f g at s=%.0f, min %.2f g at s=%.0f (smoothed over %d rows); flat start zone %.2f .. %.2f g" % [
			vmax, s_max, vmin, s_min, SMOOTH, flat_lo, flat_hi])
	cu.check(vmax > 0.5, "a compression exceeds +0.5 g in the lap telemetry (%.2f g)" % vmax)
	cu.check(vmin < -0.3, "a crest drops below -0.3 g in the lap telemetry (%.2f g)" % vmin)
	var crest_s := 0.0
	var comp_s := 0.0
	for f in Quarry.FEATURES:
		if f["kind"] == "crest":
			crest_s = f["s"]
		elif f["kind"] == "compression":
			comp_s = f["s"]
	cu.check(absf(s_min - crest_s) < 25.0, "the crest spike is within 25 m of the designed crest (s=%.0f vs %.0f)" % [s_min, crest_s])
	cu.check(absf(s_max - comp_s) < 25.0, "the compression spike is within 25 m of the designed compression (s=%.0f vs %.0f)" % [s_max, comp_s])
	cu.check(flat_rows > 30, "control: the flat start zone was sampled (%d rows)" % flat_rows)
	cu.check(flat_hi < 0.5 and flat_lo > -0.3, "control: the flat start zone has no spike (%.2f .. %.2f g)" % [flat_lo, flat_hi])
	DirAccess.remove_absolute(GHOST)
	cu.finish(self)
