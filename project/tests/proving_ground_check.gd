## Headless check for the Proving Ground level (#7). GUT is not merged yet, so this is a
## standalone SceneTree script; port the asserts to a GutTest once GUT lands.
## Run: godot --headless --path project -s res://tests/proving_ground_check.gd
extends SceneTree

const SCENE := "res://tracks/proving_ground/proving_ground.tscn"
var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


func ray_down(space: PhysicsDirectSpaceState3D, x: float, z: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 50, z), Vector3(x, -5, z))
	return space.intersect_ray(q)


func _initialize() -> void:
	var packed: PackedScene = load(SCENE)
	check(packed != null, "scene loads")
	var root: Node3D = packed.instantiate()
	check(root != null, "scene instantiates")
	get_root().add_child(root)
	await physics_frame
	await physics_frame

	for n in ["Ground", "Patch_Tarmac", "Patch_Gravel", "Patch_Mud", "Circle", "Slalom", "Slope", "Jump",
			"Spawn_Flat", "Spawn_Circle", "Spawn_Slope", "Spawn_Slalom", "Spawn_Jump", "Spawn_Gravel", "Spawn_Mud"]:
		check(root.has_node(n), "node %s exists" % n)
	for n in ["Spawn_Flat", "Spawn_Circle", "Spawn_Slope", "Spawn_Slalom", "Spawn_Jump", "Spawn_Gravel", "Spawn_Mud"]:
		check(root.get_node(n) is Marker3D, "%s is Marker3D" % n)

	var space := root.get_world_3d().direct_space_state

	# pad size
	var pad_shape: BoxShape3D = root.get_node("Ground/Collision").shape
	check(pad_shape.size.x >= 300.0 and pad_shape.size.z >= 300.0, "pad >= 300x300 (%s)" % pad_shape.size)

	# surface ids (metadata + group) and patch sizes
	var expect := {"Patch_Tarmac": "tarmac", "Patch_Gravel": "gravel", "Patch_Mud": "mud", "Ground": "tarmac"}
	for n in expect:
		var b: Node = root.get_node(n)
		check(b.get_meta("surface_id") == expect[n] and b.is_in_group("surface_" + expect[n]), "%s surface id %s" % [n, expect[n]])
		var s: BoxShape3D = b.get_node("Collision").shape
		if n != "Ground":
			check(s.size.x >= 40.0 and s.size.z >= 40.0, "%s >= 40x40" % n)
		var hit := ray_down(space, b.global_position.x, b.global_position.z)
		check(not hit.is_empty() and hit.collider.get_meta("surface_id") == expect[n], "%s ray hits surface %s" % [n, expect[n]])

	# slope normal angle
	var sl: Node3D = root.get_node("Slope/Surface")
	var sp: Vector3 = root.get_node("Spawn_Slope").global_position
	var hit := ray_down(space, sp.x + 20.0 + 20.0 * cos(deg_to_rad(10.0)), sp.z)
	check(not hit.is_empty(), "slope ray hits")
	if not hit.is_empty():
		var ang := rad_to_deg(acos(hit.normal.dot(Vector3.UP)))
		check(absf(ang - 10.0) <= 0.1, "slope angle 10 +/- 0.1 (%f)" % ang)
	var ss: BoxShape3D = sl.get_node("Collision").shape
	check(ss.size.x >= 30.0 and ss.size.z >= 8.0, "slope >= 30 long, >= 8 wide")
	check(root.get_node("Slope").get_meta("run_in") >= 20.0, "slope run-in >= 20")

	# circle radius from segment placement
	var circle: Node3D = root.get_node("Circle")
	var rmax := 0.0
	var rmin := 1e9
	var segs := 0
	for c in circle.get_children():
		if c is MeshInstance3D:
			segs += 1
			var r := Vector2(c.position.x, c.position.z).length()
			rmax = maxf(rmax, r)
			rmin = minf(rmin, r)
	check(segs >= 32 and absf(rmin - 30.0) <= 0.1 and absf(rmax - 30.0) <= 0.1, "circle radius 30 +/- 0.1 (%f..%f, %d segs)" % [rmin, rmax, segs])
	check(absf(float(circle.get_meta("radius")) - 30.0) <= 0.1 and float(circle.get_meta("width")) == 8.0, "circle metadata radius 30 width 8")

	# slalom
	var cones: Array = root.get_node("Slalom").get_children().filter(func(n): return n.name.begins_with("Cone_"))
	check(cones.size() == 8, "slalom has 8 cones")
	for i in range(cones.size() - 1):
		check(absf(cones[i + 1].position.x - cones[i].position.x - 18.0) < 0.01, "cone spacing 18 (%d)" % i)
		check(absf(cones[i].position.z) == 3.0 and cones[i].position.z * cones[i + 1].position.z < 0.0, "cone lateral +/-3 alternating (%d)" % i)

	# jump: ramp rises 1.0 at ~12 deg, then flat landing
	var jr: Node3D = root.get_node("Jump/Ramp")
	var jp: Vector3 = root.get_node("Spawn_Jump").global_position
	var h1 := ray_down(space, jp.x, jp.z + 50.0 + 4.0)
	check(not h1.is_empty() and absf(rad_to_deg(acos(h1.normal.dot(Vector3.UP))) - 12.0) < 0.1, "ramp angle 12")
	check(not h1.is_empty() and h1.position.y > 0.5 and h1.position.y < 1.0, "ramp rising (y=%f)" % h1.position.y)
	var jl: MeshInstance3D = root.get_node("Jump/Landing")
	var lz := jl.global_position.z
	check((jl.mesh as BoxMesh).size.z >= 25.0, "landing >= 25 m")
	var h2 := ray_down(space, jp.x, lz)
	check(not h2.is_empty() and absf(h2.position.y) < 0.01 and h2.normal.is_equal_approx(Vector3.UP), "landing flat at y=0")
	var top_y: float = jr.global_position.y + 0.5 * cos(deg_to_rad(12.0)) + 0.5 * (jr.get_node("Collision").shape as BoxShape3D).size.x * sin(deg_to_rad(12.0))
	check(absf(top_y - 1.0) <= 0.2, "ramp rise 1.0 +/- 0.2 (%f)" % top_y)

	# spawns face their feature: forward points toward the feature centre-ish
	var fwd: Vector3 = -root.get_node("Spawn_Slalom").global_transform.basis.z
	check(fwd.is_equal_approx(Vector3.RIGHT), "Spawn_Slalom faces +X")
	fwd = -root.get_node("Spawn_Gravel").global_transform.basis.z
	check(fwd.is_equal_approx(Vector3(0, 0, -1)), "Spawn_Gravel faces patch (-Z)")

	var f := FileAccess.open(SCENE, FileAccess.READ)
	check(f.get_length() < 1000000, "scene file < 1 MB (%d)" % f.get_length())

	print("RESULT: ", "OK" if failures == 0 else "FAILED (%d)" % failures)
	quit(1 if failures > 0 else 0)
