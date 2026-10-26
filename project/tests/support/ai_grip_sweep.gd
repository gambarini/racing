## Developer tool (#171): one Quarry AI run at a chosen skill / speed_scale, printing per-lap
## maximum centre-line offset and writing a per-tick CSV (s, speed, target, offset...).
## Env: AI_SKILL (0 = shipped line), AI_SCALE, AI_LAPS, AI_CSV (path), AI_<PARAM>=value for any AiDriver
## float property (e.g. AI_LOOK_K=0.4, name upper-cased), AI_LINE (res path override).
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/support/ai_grip_sweep.gd
extends SceneTree

const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const HALF := 6.5


func _initialize() -> void:
	_main()


func _main() -> void:
	var skill := float(OS.get_environment("AI_SKILL")) if OS.get_environment("AI_SKILL") != "" else 0.0
	var scale := float(OS.get_environment("AI_SCALE")) if OS.get_environment("AI_SCALE") != "" else 0.9
	var laps := int(OS.get_environment("AI_LAPS")) if OS.get_environment("AI_LAPS") != "" else 3
	var path := OS.get_environment("AI_LINE") if OS.get_environment("AI_LINE") != "" else "res://tracks/quarry/quarry_racing_line.tres"
	var csv := OS.get_environment("AI_CSV")
	var drive: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	drive.get_node("Vehicle/VehicleAudio").free()
	drive.get_node("TimeTrial").ghost_path = "user://ai_grip_sweep.dat"
	root.add_child(drive)
	await physics_frame
	var line: RacingLine = load(path)
	if skill > 0.0:
		line = _resolve(line, skill)
	var max_ticks := 120 * 260
	var ai := drive.start_ai(line, max_ticks)
	ai.speed_scale = scale
	for p in ["look_k", "look_min", "look_max", "kp", "ki", "brake_kp", "brake_deadband", "lead_time", "slip_target_deg", "slip_span_deg", "counter_gain", "grip_a_max", "grip_accel_ref", "grip_lead"]:
		var e := OS.get_environment("AI_" + String(p).to_upper())
		if e != "":
			ai.set(p, float(e))
	ai.telemetry_enabled = csv != ""
	var lt := drive.lap_timer
	var ticks := 0
	var max_centre := 0.0
	var worst_s := 0.0
	var lap_max := 0.0
	var seen := 0
	var off_ticks := 0
	var rows := PackedStringArray()
	rows.append("tick,s,speed,target,centre,cross_track,rear_slip,front_slip,steer_ang,fy_front,fy_rear,yaw,kappa,fx_rear,thr,steer_cmd,cap")
	while lt.laps.size() < laps and ticks < max_ticks:
		await physics_frame
		ticks += 1
		var centre := absf(line.lane_offset_at(ai.s) - ai.cross_track)
		if centre > HALF:
			off_ticks += 1
		if centre > max_centre:
			max_centre = centre
			worst_s = ai.s
		lap_max = maxf(lap_max, centre)
		if lt.laps.size() > seen:
			seen = lt.laps.size()
			print("LAP %d: %.3f s, max centre %.2f m" % [seen, lt.laps[seen - 1]["raw_time"], lap_max])
			lap_max = 0.0
		if csv != "" and ticks % 6 == 0:
			var w := drive.vehicle.wheels
			var yaw := drive.vehicle.angular_velocity.y
			rows.append("%d,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.4f,%.2f,%.2f,%.2f,%.2f" % [ticks, ai.s, ai.speed_now, ai.target_speed,
					line.lane_offset_at(ai.s) - ai.cross_track, ai.cross_track, ai.rear_slip_deg, rad_to_deg(w[0].alpha),
					w[0].steer_angle, w[0].fy + w[1].fy, w[2].fy + w[3].fy, yaw, line.curvature_at(ai.s), w[2].fx + w[3].fx, ai.throttle_out, ai.steer_out, ai.grip_cap_now])
		if off_ticks > 1500:
			break
	print("RESULT skill %.3f scale %.2f: laps %d, max centre %.2f m at s=%.0f, off-road ticks %d, grass %d, ticks %d" % [
			skill, scale, lt.laps.size(), max_centre, worst_s, off_ticks, drive.grass_ticks, ticks])
	if csv != "":
		var f := FileAccess.open(csv, FileAccess.WRITE)
		f.store_string("\n".join(rows) + "\n")
	drive.queue_free()
	await physics_frame
	quit(0)


func _resolve(src: RacingLine, skill: float) -> RacingLine:
	var out := src.duplicate() as RacingLine
	var n := src.count()
	var ds := PackedFloat32Array()
	ds.resize(n)
	for i in n:
		var a := src.pos[i]
		var b := src.pos[(i + 1) % n]
		ds[i] = Vector2(b.x - a.x, b.z - a.z).length()
	var p := RacingLineParams.new()
	p.skill_scale = skill
	out.target_speed = RacingLineSolver.solve(src.curvature, ds, src.surface_mu, p)
	return out
