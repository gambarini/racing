## Renders chase-view screenshots of the Quarry readability markers (#214) to
## res://tracks/quarry/shots/*.png. Needs a real renderer (NOT --headless):
##   godot --path project --resolution 1280x720 -s res://tracks/quarry/render_shots.gd
## Shots: straight at ~100 km/h (s 420), a corner approach (70 m before the first tight corner),
## start/finish, joker split. `-- --no-markers` hides the markers (draw-call baseline). The camera uses the chase_near profile (distance, height, look height,
## FOV at 100 km/h) behind a car origin 0.4 m above the centre line. Prints the draw calls, objects
## and node count of the last frame.
extends SceneTree

const SHOTS := [
	["straight_100kmh", 420.0], ["corner_approach", -1.0], ["start_finish", -22.0], ["joker_split", 685.0],
]


func _initialize() -> void:
	_main()


func _main() -> void:
	var q := Quarry.new()
	root.add_child(q)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	root.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.7, 0.9)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.7)
	root.add_child(env)
	var prof := load("res://camera/chase_near.tres") as CameraProfile
	var cam := Camera3D.new()
	cam.fov = ChaseMath.target_fov(100.0 / 3.6, prof)
	cam.far = 800.0
	root.add_child(cam)
	cam.make_current()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tracks/quarry/shots"))
	await process_frame
	q.markers.visible = not OS.get_cmdline_user_args().has("--no-markers")
	for shot in SHOTS:
		var s: float = shot[1]
		if s == -1.0:
			s = float(q.markers.corners[0]["s_turn"]) - 100.0
		var smp := q.track.sample(fposmod(s, q.track.length()))
		var p: Vector3 = smp["position"]
		var f: Vector3 = smp["forward"]
		var car := p + Vector3(0, 0.4, 0)
		cam.global_position = car - f * prof.distance + Vector3(0, prof.height, 0)
		cam.look_at(car + Vector3(0, prof.look_height, 0), Vector3.UP)
		for i in 6:
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var path := "res://tracks/quarry/shots/%s.png" % shot[0]
		img.save_png(path)
		print("INFO: %s: draw calls %d, objects %d, nodes %d" % [shot[0],
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
				Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
		print("saved ", ProjectSettings.globalize_path(path), " ", img.get_size())
	quit()
