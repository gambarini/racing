extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
var cu := CheckUtil.new()
const SCENE := "res://tracks/quarry/quarry_drive.tscn"


func _initialize() -> void:
	_main()


func _lap(route: StringName, line: StringName, csv: String, lat_g := 0.8) -> Dictionary:
	var drive: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	root.add_child(drive)
	await physics_frame
	var q := drive.quarry
	var pts := q.route_points(route, line)
	var drv := QuarryDriver.new()
	drv.lat_g = lat_g
	drv.setup(pts, q.route_mu(pts))
	drive.autopilot = drv
	var maxx := 0.0
	var ticks := 0
	var t0 := Time.get_ticks_msec()
	var split := []
	var last_bin := -1
	while drive.lap_timer.laps.is_empty() and ticks < 120 * 140:
		await physics_frame
		ticks += 1
		maxx = maxf(maxx, absf(drv.cross_track))
		if drv.index / 25 != last_bin:
			last_bin = drv.index / 25
			print("BIN %d t=%.1f v=%.1f vt=%.1f" % [last_bin * 25, ticks / 120.0, drive.vehicle.linear_velocity.length(), drv.target[drv.index]])
		if ticks % 30 == 0 and drv.index > 990 and drv.index < 1140:
			var st := drive.driver_input.state
			print("t=%d idx=%d v=%.1f vt=%.1f xt=%.2f steer=%.2f thr=%.2f brk=%.2f surf=%s y=%.2f" % [ticks / 120.0, drv.index, drive.vehicle.linear_velocity.length(), drv.target[drv.index], drv.cross_track, st.steer, st.throttle, st.brake, drive.vehicle.wheels[0].surface_id, drive.vehicle.global_position.y])
		if ticks % 600 == 0:
			split.append("%d:%.0f/%.0f" % [drv.index, drive.vehicle.linear_velocity.length(), drv.target[drv.index]])
	var out := {"lap": drive.lap_timer.laps[0] if not drive.lap_timer.laps.is_empty() else {}, "max_x": maxx,
		"grass": drive.grass_ticks, "off": drive.offmap_ticks, "ticks": ticks, "csv": drive.recorder.dump(csv), "wall_ms": Time.get_ticks_msec() - t0}
	print("LAP ", route, "/", line, " ", out.lap.get("time", -1.0), " joker=", out.lap.get("joker"), " maxx=", maxx, " grass=", drive.grass_ticks, " ticks=", ticks, " wall=", out.wall_ms)
	print("  ", split)
	drive.queue_free()
	await physics_frame
	return out


func _main() -> void:
	await physics_frame
	await _lap(&"main", &"tarmac", "user://qd_main.csv")
	quit()
