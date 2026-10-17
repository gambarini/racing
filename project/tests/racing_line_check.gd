## Quarry racing line data (#27): loop length, sample spacing, staying inside the road, speed
## bounds, grip monotonicity against the surface map, brake/accel limits, predicted lap time and
## the joker lap's rejoin gap.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/racing_line_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const LINE := "res://tracks/quarry/quarry_racing_line.tres"
const MARGIN := 1.0 ## criterion: |lane_offset| <= half road width - 1.0

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _main() -> void:
	await physics_frame
	var q: Quarry = (load("res://tracks/quarry/quarry.tscn") as PackedScene).instantiate()
	root.add_child(q)
	await physics_frame
	await physics_frame
	var line := load(LINE) as RacingLine
	cu.check(line != null and line.count() > 100, "racing line data loads headless")
	cu.check(line.has_joker(), "line has a joker lap")
	var p := RacingLineParams.new()
	_check_lap(q, line, p, false)
	line.variant = RacingLine.Variant.JOKER
	_check_lap(q, line, p, true)
	line.variant = RacingLine.Variant.MAIN
	_check_joker(q, line)
	await _check_debug(line)
	cu.finish(self)


func _check_lap(q: Quarry, line: RacingLine, p: RacingLineParams, joker: bool) -> void:
	var tag := "joker lap" if joker else "main lap"
	var n := line.count()
	var l := line.lap_length()
	# Loop length: within 1 % of the track (joker lap: plus the detour's extra length).
	var want := q.track.length() + (line.joker_length_delta() if joker else 0.0)
	cu.check_range("%s length (m)" % tag, l, want * 0.99, want * 1.01)
	if not joker:
		cu.check_range("main lap length vs 1668 m", l, 1668.0 * 0.99, 1668.0 * 1.01)
	# Spacing.
	var d := _d(line)
	var max_ds := 0.0
	for i in n:
		max_ds = maxf(max_ds, d.pos[i].distance_to(d.pos[(i + 1) % n]))
	cu.check_range("%s max sample spacing (m)" % tag, max_ds, 0.5, 4.0)
	# Stay inside the road, measured against the real centre lines (not the stored offsets).
	var jspan := line.joker_span_joker
	var worst_margin := INF
	var worst_stored := 0.0
	var gravel_ok := true
	var bounds_ok := true
	var brake_worst := 0.0
	var accel_worst := 0.0
	var tarmac_cap_ok := true
	var surface_ok := true
	for i in n:
		var pos: Vector3 = d.pos[i]
		var in_detour := joker and d.s[i] >= jspan.x - 1e-3 and d.s[i] <= jspan.y + 1e-3
		var margin: float
		if in_detour:
			margin = Quarry.JOKER_HALF - _dist_to_curve(q.joker_line, pos)
		else:
			var s := q.track.nearest_offset(pos)
			var c: Vector3 = q.track.sample(s)["position"]
			margin = q.road_half(s) - Vector2(c.x - pos.x, c.z - pos.z).length()
		worst_margin = minf(worst_margin, margin)
		worst_stored = maxf(worst_stored, absf(d.lane_offset[i]))
		var v: float = d.target_speed[i]
		if v < p.v_min - 1e-3 or v > p.v_max + 1e-3:
			bounds_ok = false
		# Grip monotonicity: the stored grip matches the surface map, and the speed never exceeds
		# the corner speed the same curvature allows at that grip (hence never the tarmac one).
		var w := q.terrain.surface_at(pos.x, pos.z)
		var mu_map := SurfaceBlend.blend(w).peak_mu_scale if not w.is_empty() else 0.5
		if absf(mu_map - d.surface_mu[i]) > 0.02:
			surface_ok = false
		if v > RacingLineSolver.corner_speed(d.curvature[i], d.surface_mu[i], p) + 1e-3:
			tarmac_cap_ok = false
		if not joker and d.s[i] >= 700.0 and d.s[i] <= 1050.0:
			if v > RacingLineSolver.corner_speed(d.curvature[i], 1.0, p) + 1e-3 or d.surface_mu[i] >= 1.0:
				gravel_ok = false
		var j := (i + 1) % n
		var a := (d.target_speed[j] * d.target_speed[j] - v * v) / (2.0 * maxf(d.pos[i].distance_to(d.pos[j]), 1e-3))
		brake_worst = maxf(brake_worst, -a - p.brake_limit(d.surface_mu[i]))
		accel_worst = maxf(accel_worst, a - p.accel_limit(v, d.surface_mu[i]))
	cu.check_range("%s smallest distance to road edge (m)" % tag, worst_margin, MARGIN, 20.0)
	print("INFO: %s largest stored |lane_offset| %.2f m" % [tag, worst_stored])
	cu.check(bounds_ok, "%s target speeds within [%.0f, %.0f] m/s" % [tag, p.v_min, p.v_max])
	cu.check(surface_ok, "%s stored grip matches the surface map" % tag)
	cu.check(tarmac_cap_ok, "%s speed <= corner speed at the sample's grip" % tag)
	if not joker:
		cu.check(gravel_ok, "gravel zone (s 700-1050) speed <= tarmac speed for equal curvature")
	cu.check_range("%s braking above the limit (m/s^2)" % tag, brake_worst, -100.0, 0.01)
	cu.check_range("%s acceleration above the limit (m/s^2)" % tag, accel_worst, -100.0, 0.01)
	var t := line.predicted_lap_time()
	var vmin := INF
	var vmax := 0.0
	for v in d.target_speed:
		vmin = minf(vmin, v)
		vmax = maxf(vmax, v)
	print("INFO: %s target speed %.1f .. %.1f m/s, predicted lap %.2f s" % [tag, vmin, vmax, t])
	cu.check_range("%s predicted lap time (s)" % tag, t, 55.0, 75.0)


func _check_joker(q: Quarry, line: RacingLine) -> void:
	var j := line.joker
	var m := line.joker_span_main
	var js := line.joker_span_joker
	print("INFO: joker span main %.1f..%.1f m, joker lap %.1f..%.1f m" % [m.x, m.y, js.x, js.y])
	cu.check_range("joker detour entry on main s (m, track 710)", m.x, 700.0, 720.0)
	cu.check_range("joker detour rejoin on main s (m, track 985)", m.y, 975.0, 995.0)
	# Gap between the detour ends and the main line (nearest point on the main polyline).
	var a: Vector3 = j.point_at(js.x)
	var b: Vector3 = j.point_at(js.y)
	var ga := _gap(line, a)
	var gb := _gap(line, b)
	cu.check_range("joker entry gap to main line (m)", ga, 0.0, 0.5)
	cu.check_range("joker rejoin gap to main line (m)", gb, 0.0, 0.5)
	# Beyond the detour the two laps are the same line: s offset by the detour's extra length.
	var delta := line.joker_length_delta()
	var worst := 0.0
	for k in 20:
		var sm := fposmod(m.y + 20.0 + k * 40.0, line.length)
		if sm > line.length - 5.0 or sm < m.y:
			continue
		worst = maxf(worst, line.point_at(sm).distance_to(j.point_at(sm + delta)))
	cu.check_range("joker lap = main lap after the detour, offset by %.1f m (max gap m)" % delta, worst, 0.0, 0.5)
	var spd_main := line.target_speed_at(m.x + 100.0)
	print("INFO: joker lap time %.2f s, main %.2f s, speed in detour mid %.1f vs main %.1f m/s" % [
			j.predicted_lap_time(), line.predicted_lap_time(), j.target_speed_at((js.x + js.y) * 0.5), spd_main])


## Debug draw: builds one ribbon, colours slow red and fast green, toggles with its action.
func _check_debug(line: RacingLine) -> void:
	var dbg := RacingLineDebug.new()
	dbg.line = line
	root.add_child(dbg)
	await process_frame
	cu.check(not dbg.visible, "debug draw starts hidden")
	var ribbon := dbg.get_node_or_null("Ribbon") as MeshInstance3D
	cu.check(ribbon != null and ribbon.mesh.get_surface_count() == 1, "debug draw builds a ribbon mesh")
	var slow := RacingLineDebug.speed_colour(8.0, 8.0, 40.0)
	var fast := RacingLineDebug.speed_colour(40.0, 8.0, 40.0)
	cu.check(slow.r > 0.9 and slow.g < 0.1 and fast.g > 0.9 and fast.r < 0.1, "slow is red, fast is green")
	var ev := InputEventAction.new()
	ev.action = RacingLineDebug.ACTION_TOGGLE
	ev.pressed = true
	cu.check(InputMap.has_action(RacingLineDebug.ACTION_TOGGLE), "toggle_racing_line action exists")
	Input.parse_input_event(ev)
	await process_frame
	await process_frame
	cu.check(dbg.visible, "toggle action shows the debug draw")
	dbg.queue_free()


func _gap(line: RacingLine, p: Vector3) -> float:
	var s := line.nearest_s(p)
	var c := line.point_at(s)
	return Vector2(c.x - p.x, c.z - p.z).length()


func _d(line: RacingLine) -> RacingLine:
	return line.joker if line.variant == RacingLine.Variant.JOKER else line


func _dist_to_curve(c: Curve3D, p: Vector3) -> float:
	var off := c.get_closest_offset(p)
	var q := c.sample_baked(off)
	return Vector2(q.x - p.x, q.z - p.z).length()
