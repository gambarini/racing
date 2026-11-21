## Renders chase-view screenshots of the Quarry readability markers (#214) to
## res://tracks/quarry/shots/*.png. Needs a real renderer (NOT --headless):
##   godot --path project --resolution 1280x720 -s res://tracks/quarry/render_shots.gd
## Shots: straight at ~100 km/h (s 420), a corner approach (70 m before the first tight corner),
## start/finish, joker split. The camera sits 7 m behind and 2.6 m above a point on the centre
## line, looking 25 m ahead (about the chase_near framing).
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
	var cam := Camera3D.new()
	cam.fov = 75.0
	cam.far = 800.0
	root.add_child(cam)
	cam.make_current()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tracks/quarry/shots"))
	await process_frame
	for shot in SHOTS:
		var s: float = shot[1]
		if s == -1.0:
			s = float(q.markers.corners[0]["s_in"]) - 70.0
		var smp := q.track.sample(fposmod(s, q.track.length()))
		var p: Vector3 = smp["position"]
		var f: Vector3 = smp["forward"]
		cam.global_position = p - f * 7.0 + Vector3(0, 2.6, 0)
		cam.look_at(p + f * 25.0 + Vector3(0, 0.5, 0), Vector3.UP)
		for i in 6:
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var path := "res://tracks/quarry/shots/%s.png" % shot[0]
		img.save_png(path)
		print("saved ", ProjectSettings.globalize_path(path), " ", img.get_size())
	quit()
