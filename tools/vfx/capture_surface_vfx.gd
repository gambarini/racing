## Windowed capture of the 5 per-surface VFX screenshots (#128). Needs a display (not --headless).
## Per surface: teleport to the mid-zone, hold 15 m/s, then brake hard and save the viewport.
## Run: tools/vfx/capture.sh [out_dir]
extends SceneTree

const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const IDS: Array[StringName] = [&"tarmac", &"dirt", &"gravel", &"mud", &"grass"]

var out_dir := ProjectSettings.globalize_path("user://vfx") ## overridden by the first user arg


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



func _main() -> void:
	await physics_frame
	DirAccess.make_dir_recursive_absolute(out_dir)
	var probe := _spawn(true)
	await physics_frame
	var mids := {}
	for id in IDS:
		mids[id] = VfxScenario.mid_zone(probe.quarry, id)
	probe.queue_free()
	await physics_frame
	for id in IDS:
		var dr := _spawn()
		await physics_frame
		var s: float = mids[id]
		VfxScenario.teleport(dr, s - 40.0, VfxScenario.lat(dr.quarry, id, s), 15.0)
		await VfxScenario.hold(self, dr, 15.0, 180)
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
		print("saved %s speed %.1f size %s" % [id, VfxScenario.speed(dr), img.get_size()])
		dr.queue_free()
		await physics_frame
	quit()
