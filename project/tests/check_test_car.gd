## Headless pipeline check for the M0 test car (issue #56).
## Run: godot --headless --path project --import
##      godot --headless --path project --script res://tests/check_test_car.gd
## Exits non-zero on any failed assertion. Authored values mirror art-source/test/build_test_car.py.
extends SceneTree

const GLB := "res://test/test_car/test_car.glb"
# Godot-space authored values: Blender (x, y, z) -> Godot (x, z, -y)
const BODY_SIZE := Vector3(1.8, 1.3, 4.0)
const WHEEL_RADIUS := 0.32
const HUBS := {
	"wheel_FL": Vector3(0.85, 0.32, 1.3),
	"wheel_FR": Vector3(-0.85, 0.32, 1.3),
	"wheel_RL": Vector3(0.85, 0.32, -1.3),
	"wheel_RR": Vector3(-0.85, 0.32, -1.3),
}
const SIZE_TOL := 0.01
const HUB_TOL := 0.005

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS  ", msg)
	else:
		failures += 1
		printerr("FAIL  ", msg)

func _init() -> void:
	var packed := load(GLB) as PackedScene
	if packed == null:
		printerr("FAIL  cannot load ", GLB, " (run --import first)")
		quit(1)
		return
	var root := packed.instantiate()
	get_root().add_child(root)

	var car := root.find_child("Car_test", true, false) as Node3D
	check(car != null, "root node Car_test exists")
	check(car != null and car.scale.is_equal_approx(Vector3.ONE), "car root scale is 1")

	# body bbox in metres
	var body := root.find_child("body", true, false) as MeshInstance3D
	check(body != null, "body mesh exists")
	if body:
		var sz := body.get_aabb().size
		check(sz.distance_to(BODY_SIZE) <= SIZE_TOL, "body bbox %s within %s m of %s" % [sz, SIZE_TOL, BODY_SIZE])

	# wheels + custom property
	for wname in HUBS:
		var w := root.find_child(wname, true, false) as Node3D
		check(w != null, wname + " exists")
		if w == null:
			continue
		var d := w.position.distance_to(HUBS[wname])
		check(d <= HUB_TOL, "%s origin %s within %s m of %s" % [wname, w.position, HUB_TOL, HUBS[wname]])
		var ex = w.get_meta("extras", null)
		check(ex is Dictionary and ex.has("wheel_radius") and is_equal_approx(float(ex["wheel_radius"]), WHEEL_RADIUS),
			wname + " custom property wheel_radius == %s" % WHEEL_RADIUS)
		var mi := w as MeshInstance3D
		if mi:
			var a := mi.get_aabb()
			check(a.get_center().length() <= HUB_TOL and absf(a.size.y * 0.5 - WHEEL_RADIUS) <= HUB_TOL,
				wname + " mesh is centred on the hub and matches radius")
	var ex_root = car.get_meta("extras", null) if car else null
	check(ex_root is Dictionary and is_equal_approx(float(ex_root.get("wheel_radius", -1.0)), WHEEL_RADIUS),
		"Car_test custom property wheel_radius readable")

	# calipers and markers present
	for n in ["caliper_FL", "caliper_FR", "caliper_RL", "caliper_RR", "marker_com", "marker_cam_bonnet",
			"marker_cam_bumper", "marker_cam_cockpit", "marker_exhaust_L", "marker_exhaust_R",
			"marker_light_head", "marker_light_brake", "marker_driver"]:
		check(root.find_child(n, true, false) != null, n + " exists")

	# nose toward +Z
	var front := root.find_child("marker_light_head", true, false) as Node3D
	var rear := root.find_child("marker_light_brake", true, false) as Node3D
	check(front != null and rear != null and front.position.z > rear.position.z,
		"nose points to +Z (front marker z > rear marker z)")
	var fl := root.find_child("wheel_FL", true, false) as Node3D
	var rl := root.find_child("wheel_RL", true, false) as Node3D
	check(fl != null and rl != null and fl.position.z > rl.position.z, "front wheels at +Z")
	check(fl != null and fl.position.x > 0.0, "left wheels at +X")

	# Convex collision from body-convcolonly. Godot drops the "-convcolonly" suffix, and the
	# resulting name clashes with "body", so the StaticBody3D gets an auto name: find it by type.
	var bodies: Array = root.find_children("*", "StaticBody3D", true, false)
	check(bodies.size() == 1, "exactly one StaticBody3D from -convcolonly")
	if bodies.size() == 1:
		var shapes: Array = bodies[0].find_children("*", "CollisionShape3D", true, false)
		check(shapes.size() == 1 and shapes[0].shape is ConvexPolygonShape3D, "collider is a ConvexPolygonShape3D")
		if shapes.size() == 1 and shapes[0].shape is ConvexPolygonShape3D:
			var pts: PackedVector3Array = shapes[0].shape.points
			var bb := AABB(pts[0], Vector3.ZERO)
			for p in pts:
				bb = bb.expand(p)
			check(bb.size.distance_to(BODY_SIZE) <= SIZE_TOL, "hull extents %s match body" % bb.size)
	# hull must not render: no MeshInstance3D other than body + 4 wheels
	var meshes: Array = root.find_children("*", "MeshInstance3D", true, false)
	var names: Array = []
	for m in meshes:
		names.append(String(m.name))
	names.sort()
	check(names == ["body", "wheel_FL", "wheel_FR", "wheel_RL", "wheel_RR"], "hull not rendered; meshes = %s" % [names])

	root.free()
	print("RESULT: ", "OK" if failures == 0 else "%d FAILED" % failures)
	quit(0 if failures == 0 else 1)
