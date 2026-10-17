## Terrain spike (#22): 1 km x 1 km custom heightmap terrain loads headless, ground height query
## by world XZ agrees with the collider and the source heightmap (< 5 cm), rigid bodies rest on
## it, and the surface map is sampled by world XZ. Prints load/query timings.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/terrain_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _main() -> void:
	await physics_frame
	var t0 := Time.get_ticks_usec()
	var img: Image = TerrainSource.make_image(1001, 1.0)
	var t1 := Time.get_ticks_usec()
	var terrain := HeightmapTerrain.new()
	terrain.load_from_image(img, Vector2.ZERO)
	terrain.surface_map = TerrainSource.make_surface_map(1000.0, 256)
	root.add_child(terrain)
	terrain.build_collider()
	terrain.build_visual()
	var t2 := Time.get_ticks_usec()
	print("INFO: source gen %.0f ms, build (collider+visual) %.0f ms" % [(t1 - t0) / 1e3, (t2 - t1) / 1e3])
	cu.check(terrain.n == 1001 and terrain.extent() == 1000.0, "terrain is 1001x1001 samples = 1000 m x 1000 m")
	cu.check(terrain.get_child_count() == 101, "100 visual chunks plus the collider body")
	await physics_frame
	await physics_frame

	# Height query vs the source heightmap: exact at grid points, interpolation error off-grid.
	var rng := RandomNumberGenerator.new()
	rng.seed = 22
	var e_grid := 0.0
	var e_off := 0.0
	for i in 2000:
		var gx := rng.randi_range(0, 1000)
		var gz := rng.randi_range(0, 1000)
		e_grid = maxf(e_grid, absf(terrain.height_at(gx, gz) - img.get_pixel(gx, gz).r))
		var x := rng.randf_range(0.0, 1000.0)
		var z := rng.randf_range(0.0, 1000.0)
		e_off = maxf(e_off, absf(terrain.height_at(x, z) - TerrainSource.analytic(x, z)))
	cu.check_range("height query vs source heightmap at grid points (m)", e_grid, 0.0, 0.05)
	cu.check_range("height query vs continuous source off-grid, 1 m cell (m)", e_off, 0.0, 0.05)

	# Collider vs query: downward ray hits at random points.
	var space := root.get_world_3d().direct_space_state
	var e_ray := 0.0
	var hits := 0
	for i in 500:
		var x := rng.randf_range(1.0, 999.0)
		var z := rng.randf_range(1.0, 999.0)
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, 100, z), Vector3(x, -10, z))
		var r := space.intersect_ray(q)
		if r:
			hits += 1
			e_ray = maxf(e_ray, absf((r.position as Vector3).y - terrain.height_at(x, z)))
	cu.check(hits == 500, "all 500 downward rays hit the terrain collider (%d)" % hits)
	cu.check_range("collider ray height vs height_at (m)", e_ray, 0.0, 0.05)

	# Rigid bodies rest on it: spheres on the flat plateau and on slopes.
	var spheres: Array[RigidBody3D] = []
	var pts := [Vector2(500, 500), Vector2(505, 495), Vector2(150, 700), Vector2(820, 260), Vector2(300, 100)]
	for p in pts:
		var rb := RigidBody3D.new()
		var cs := CollisionShape3D.new()
		var sh := SphereShape3D.new()
		sh.radius = 0.5
		cs.shape = sh
		rb.add_child(cs)
		rb.position = Vector3(p.x, terrain.height_at(p.x, p.y) + 1.5, p.y)
		rb.linear_damp = 4.0
		rb.angular_damp = 4.0
		root.add_child(rb)
		spheres.append(rb)
	for i in 120 * 5:
		await physics_frame
	for k in spheres.size():
		var p := spheres[k].global_position
		# Centre sits r * sqrt(1 + |grad h|^2) above the surface point under it on a slope.
		var hx := terrain.height_at(p.x + 0.5, p.z) - terrain.height_at(p.x - 0.5, p.z)
		var hz := terrain.height_at(p.x, p.z + 0.5) - terrain.height_at(p.x, p.z - 0.5)
		var expect := terrain.height_at(p.x, p.z) + 0.5 * sqrt(1.0 + hx * hx + hz * hz)
		cu.check_range("sphere %d rest height vs terrain (m)" % k, absf(p.y - expect), 0.0, 0.05 if k < 2 else 0.1)
	cu.check_range("plateau sphere centre height error vs 18 + r (m)", absf(spheres[0].global_position.y - 18.5), 0.0, 0.05)

	# Surface map hook.
	cu.check(terrain.dominant_surface_at(300, 300) == &"tarmac", "surface at (300,300) is tarmac")
	cu.check(terrain.dominant_surface_at(300, 312) == &"dirt", "surface at (300,312) is dirt")
	cu.check(terrain.dominant_surface_at(100, 800) == &"grass", "surface at (100,800) is grass")
	cu.check(terrain.dominant_surface_at(500, 500) == &"gravel", "surface at (500,500) is gravel")
	var w := terrain.surface_at(300, 307)
	var s := 0.0
	for id in w:
		s += w[id]
	cu.check_range("blend weights sum to 1 (dirt/tarmac edge)", s, 0.9999, 1.0001)

	# Query cost.
	var tq := Time.get_ticks_usec()
	var acc := 0.0
	for i in 100000:
		acc += terrain.height_at(float(i % 1000) + 0.37, float((i * 7) % 1000) + 0.61)
	var per := (Time.get_ticks_usec() - tq) / 100000.0
	tq = Time.get_ticks_usec()
	for i in 20000:
		terrain.surface_at(float(i % 1000) + 0.3, float((i * 7) % 1000) + 0.4)
	var per_s := (Time.get_ticks_usec() - tq) / 20000.0
	print("INFO: height_at %.2f us/query, surface_at %.2f us/query (acc %.1f)" % [per, per_s, acc])
	cu.finish(self)
