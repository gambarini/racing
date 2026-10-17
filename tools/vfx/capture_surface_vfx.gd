## Windowed capture of the 5 per-surface VFX screenshots (#128). Needs a display (not --headless).
## Per surface: teleport to the mid-zone, hold 15 m/s, then brake hard and save the viewport.
## Run: tools/vfx/capture.sh [out_dir]
extends SceneTree

const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const IDS: Array[StringName] = [&"tarmac", &"dirt", &"gravel", &"mud", &"grass"]
const GRASS_S := 10.0
const GRASS_OFFSET := 8.0

var out_dir := "/tmp/vfx"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0]
	_main()


func _spawn(remove := false) -> QuarryDrive:
	var d: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	d.get_node("Vehicle/VehicleAudio").free() # audio is not under test and holds streams at exit
	if remove:
		d.get_node("Vehicle/VehicleVfx").free()
	root.add_child(d)
	return d


func _vfx(d: QuarryDrive) -> VehicleVfx:
	return d.get_node("Vehicle/VehicleVfx")


func _lat(q: Quarry, id: StringName, s: float) -> float:
	return q.road_half(s) + GRASS_OFFSET if id == &"grass" else 0.0


func _pos(q: Quarry, s: float, lat: float) -> Vector3:
	var smp: Dictionary = q.track.sample(s)
	var fwd: Vector3 = smp["forward"]
	return (smp["position"] as Vector3) + fwd.cross(Vector3.UP) * lat


func _weight(q: Quarry, s: float, lat: float, id: StringName) -> float:
	var p := _pos(q, s, lat)
	return q.terrain.surface_map.sample(p.x, p.z).get(id, 0.0)


## Middle of the longest purest stretch of `id` on the main line.
func _mid_zone(q: Quarry, id: StringName) -> float:
	if id == &"grass":
		return GRASS_S
	var n := int(q.track.length() / 2.0)
	var run_lo := 0
	var best_lo := 0
	var best_len := 0
	for i in n + 1:
		var pure := false
		if i < n:
			pure = true
			for dd in range(-5, 6, 5):
				if _weight(q, i * 2.0 + dd, 0.0, id) < 0.99:
					pure = false
					break
		if pure:
			continue
		if i - run_lo > best_len:
			best_len = i - run_lo
			best_lo = run_lo
		run_lo = i + 1
	return (best_lo + best_lo + best_len - 1) * 1.0


func _teleport(d: QuarryDrive, s: float, lat: float, speed: float) -> void:
	var fwd: Vector3 = d.quarry.track.sample(s)["forward"]
	var pos := _pos(d.quarry, s, lat)
	pos.y = d.quarry.terrain.height_at(pos.x, pos.z) + d.spawn_lift
	d.vehicle.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), pos)
	d.vehicle.linear_velocity = fwd * speed
	d.vehicle.angular_velocity = Vector3.ZERO
	for w in d.vehicle.wheels:
		w.omega = speed / w.radius


func _speed(d: QuarryDrive) -> float:
	return d.vehicle.linear_velocity.dot(-d.vehicle.global_transform.basis.z)


func _hold(d: QuarryDrive, speed: float, ticks: int) -> void:
	for i in ticks:
		var err := speed - _speed(d)
		var st := d.driver_input.state
		st.steer = 0.0
		st.handbrake = false
		st.throttle = clampf(err * 0.5, 0.0, 1.0)
		st.brake = clampf(-err * 0.5, 0.0, 1.0)
		await physics_frame



func _main() -> void:
	await physics_frame
	DirAccess.make_dir_recursive_absolute(out_dir)
	var probe := _spawn(true)
	await physics_frame
	var mids := {}
	for id in IDS:
		mids[id] = _mid_zone(probe.quarry, id)
	probe.queue_free()
	await physics_frame
	for id in IDS:
		var dr := _spawn()
		await physics_frame
		var s: float = mids[id]
		_teleport(dr, s - 40.0, _lat(dr.quarry, id, s), 15.0)
		await _hold(dr, 15.0, 180)
		for i in 40:
			var st := dr.driver_input.state
			st.steer = 0.0
			st.throttle = 0.0
			st.brake = 1.0
			await physics_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.save_png("%s/%s.png" % [out_dir, id])
		print("saved %s speed %.1f size %s" % [id, _speed(dr), img.get_size()])
		dr.queue_free()
		await physics_frame
	quit()
