## Windowed screenshot of the telemetry overlay on the Proving Ground (#79).
## Run (needs a display, no --headless):
##   godot --path project -s res://debug/capture_telemetry_shot.gd -- [out.png]
## Applies a scripted throttle + steer directly to the wheels (DriverInput wiring is #82), waits
## for steady cornering, switches the overlay on and saves the viewport.
extends SceneTree

const SCENE := "res://tracks/proving_ground/proving_ground_drive.tscn"


func _initialize() -> void:
	var out := "user://telemetry_overlay.png"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out = args[0]
	var root: Node = load(SCENE).instantiate()
	(root.get_node("TelemetryOverlay") as TelemetryOverlay).start_visible = true
	get_root().add_child(root)
	run(root, out)


func run(root: Node, out: String) -> void:
	var v: Vehicle = root.get_node("Vehicle")
	var ov: TelemetryOverlay = root.get_node("TelemetryOverlay")
	ov.visible = true # _ready may not have run yet
	for i in 300: # 2.5 s at 120 Hz
		var t := float(i) / 120.0
		if i == 240: # steering is not wired into the sim yet (#82): kick sideways to provoke slip, so Fy shows
			v.linear_velocity += v.global_transform.basis.x * 2.5
		for j in v.wheels.size():
			var w: Wheel = v.wheels[j]
			w.drive_torque = 350.0 if j >= 2 else 0.0
			if j < 2:
				w.steer_angle = 0.12 if t > 2.0 else 0.0
		await physics_frame
	await process_frame
	await process_frame
	print("overlay visible=", ov.visible, " label=", ov._label.text.left(60) if ov._label else "none")
	var img := get_root().get_texture().get_image()
	var err := img.save_png(out)
	print("saved ", ProjectSettings.globalize_path(out) if out.begins_with("user://") else out, " err=", err)
	quit(0 if err == OK else 1)
