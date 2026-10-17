## Windowed top-down screenshot of the Quarry with the racing-line debug draw (#27).
## Run (needs a display, no --headless):
##   godot --path project -s res://ai/capture_racing_line_shot.gd -- [out.png] [main|joker]
extends SceneTree


func _initialize() -> void:
	var out := "user://racing_line_quarry.png"
	var variant := RacingLine.Variant.MAIN
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out = args[0]
	if args.size() > 1 and args[1] == "joker":
		variant = RacingLine.Variant.JOKER
	run(out, variant)


func run(out: String, variant: RacingLine.Variant) -> void:
	var quarry: Quarry = (load("res://tracks/quarry/quarry.tscn") as PackedScene).instantiate()
	root.add_child(quarry)
	var dbg := RacingLineDebug.new()
	dbg.line = load("res://tracks/quarry/quarry_racing_line.tres")
	dbg.variant = variant
	dbg.half_width = 2.0
	dbg.start_visible = true
	root.add_child(dbg)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60.0, 30.0, 0.0)
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 560.0
	root.add_child(cam)
	cam.position = Vector3(380.0, 200.0, 380.0)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0) ## looks down, screen up = -Z
	cam.make_current()
	root.size = Vector2i(1200, 1200)
	for i in 40:
		await process_frame
	var img := root.get_texture().get_image()
	var err := img.save_png(out)
	print("saved ", ProjectSettings.globalize_path(out) if out.begins_with("user://") else out, " err=", err)
	quit(0 if err == OK else 1)
