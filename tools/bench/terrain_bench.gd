## Terrain frame-cost bench (#22). Needs a window (no --headless) for render numbers.
## Run: tools/bench/run_bench.sh terrain
## Loads the 1 km^2 terrain, 12 boxes resting on it, a camera flying a circle at 45 m height;
## prints mean/p99/max of script, physics and render CPU/GPU time over 600 frames.
extends SceneTree


func _initialize() -> void:
	_main()


func _main() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	await process_frame
	var terrain := HeightmapTerrain.new()
	terrain.load_from_image(TerrainSource.make_image(1001, 1.0), Vector2.ZERO)
	root.add_child(terrain)
	terrain.build_collider()
	terrain.build_visual()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.far = 2000.0
	root.add_child(cam)
	for i in 12:
		var rb := RigidBody3D.new()
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = Vector3(1.8, 1.0, 4.0)
		cs.shape = sh
		rb.add_child(cs)
		var x := 480.0 + i * 4.0
		rb.position = Vector3(x, terrain.height_at(x, 500.0) + 2.0, 500.0)
		root.add_child(rb)
	var vp := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var series := {"script process ms": [], "physics process ms": [], "render CPU ms": [], "render GPU ms": [], "wall frame ms": []}
	Engine.max_fps = 0
	var last := Time.get_ticks_usec()
	for f in 660:
		var a := f * 0.01
		cam.position = Vector3(500.0 + 400.0 * cos(a), 45.0, 500.0 + 400.0 * sin(a))
		cam.look_at(Vector3(500, 18, 500))
		await process_frame
		var now := Time.get_ticks_usec()
		var wall := (now - last) / 1000.0
		last = now
		if f >= 60:
			series["wall frame ms"].append(wall)
			series["script process ms"].append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
			series["physics process ms"].append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
			series["render CPU ms"].append(RenderingServer.viewport_get_measured_render_time_cpu(vp))
			series["render GPU ms"].append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
	print("BENCH adapter: ", RenderingServer.get_video_adapter_name())
	print("BENCH objects / primitives in last frame: ",
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), " / ",
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	for name in series:
		var arr: Array = series[name]
		arr.sort()
		var sum := 0.0
		for v in arr:
			sum += v
		print("BENCH %s: mean %.3f p99 %.3f max %.3f" % [name, sum / arr.size(), arr[int(arr.size() * 0.99)], arr[-1]])
	quit()
