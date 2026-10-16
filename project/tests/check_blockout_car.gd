## Headless check for the M1 blockout car and its Vehicle binder (issue #57).
## Run: godot --headless --path project --import
##      godot --headless --fixed-fps 120 --path project --script res://tests/check_blockout_car.gd
## Authored values mirror art-source/vehicle/build_blockout_car.py.
extends SceneTree

const GLB := "res://vehicle/blockout_car/blockout_car.glb"
const R := 0.32
const HUBS := {
	"wheel_FL": Vector3(0.75, 0.32, 1.25), "wheel_FR": Vector3(-0.75, 0.32, 1.25),
	"wheel_RL": Vector3(0.75, 0.32, -1.25), "wheel_RR": Vector3(-0.75, 0.32, -1.25),
}
var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS  ", msg)
	else:
		failures += 1
		printerr("FAIL  ", msg)


func tri_count(mi: MeshInstance3D) -> int:
	var t := 0
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var idx = arr[Mesh.ARRAY_INDEX]
		t += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
	return t


func _initialize() -> void:
	var packed := load(GLB) as PackedScene
	if packed == null:
		printerr("FAIL  cannot load ", GLB, " (run --import first)")
		quit(1)
		return
	var root := packed.instantiate()
	get_root().add_child(root)
	check_asset(root)
	root.free()
	await check_binder()
	print("RESULT: ", "OK" if failures == 0 else "%d FAILED" % failures)
	quit(0 if failures == 0 else 1)


func check_asset(root: Node) -> void:
	var car := root.find_child("Car_blockout", true, false) as Node3D
	check(car != null, "root node Car_blockout exists")
	var ex = car.get_meta("extras", null) if car else null
	check(ex is Dictionary and is_equal_approx(float(ex.get("wheel_radius", -1.0)), R), "root wheel_radius == 0.32")
	for n in ["caliper_FL", "caliper_FR", "caliper_RL", "caliper_RR", "marker_com", "marker_cam_bonnet",
			"marker_cam_bumper", "marker_light_head", "marker_light_brake", "marker_exhaust_L",
			"marker_exhaust_R", "marker_driver"]:
		check(root.find_child(n, true, false) != null, n + " exists")
	var tris := 0
	var meshes: Array = root.find_children("*", "MeshInstance3D", true, false)
	var names: Array = []
	var mats := {}
	var body := root.find_child("body", true, false) as MeshInstance3D
	for mi: MeshInstance3D in meshes:
		names.append(String(mi.name))
		tris += tri_count(mi)
		for s in mi.mesh.get_surface_count():
			mats[mi.mesh.surface_get_material(s)] = true
	names.sort()
	check(names == ["body", "wheel_FL", "wheel_FR", "wheel_RL", "wheel_RR"], "hull not rendered; meshes = %s" % [names])
	check(tris <= 12000, "total triangles %d <= 12000" % tris)
	check(mats.size() >= 2, "at least two distinct materials (%d)" % mats.size())
	if body:
		var sz := body.get_aabb().size
		check(sz.z >= 3.9 and sz.z <= 4.2, "body length %.3f" % sz.z)
		check(sz.x >= 1.70 and sz.x <= 1.80, "body width %.3f" % sz.x)
		check(sz.y >= 1.25 and sz.y <= 1.45, "body height %.3f" % sz.y)
	for wname in HUBS:
		var w := root.find_child(wname, true, false) as MeshInstance3D
		check(w != null, wname + " exists")
		if w == null:
			continue
		check(w.position.distance_to(HUBS[wname]) <= 0.01, "%s hub %s" % [wname, w.position])
		check(absf(w.get_aabb().size.y - 0.64) <= 0.01, "%s mesh height %.3f" % [wname, w.get_aabb().size.y])
		check(tri_count(w) <= 2000, "%s tris %d <= 2000" % [wname, tri_count(w)])
		var wex = w.get_meta("extras", null)
		check(wex is Dictionary and is_equal_approx(float(wex.get("wheel_radius", -1.0)), R), wname + " wheel_radius")
	var com := root.find_child("marker_com", true, false) as Node3D
	check(com != null and absf(com.position.y - 0.45) <= 0.01 and absf(com.position.z - (-0.0625)) <= 0.01,
		"marker_com %s" % [com.position if com else null])
	var hf := root.find_child("marker_light_head", true, false) as Node3D
	var hr := root.find_child("marker_light_brake", true, false) as Node3D
	check(hf != null and hr != null and hf.position.z > hr.position.z, "nose points to +Z")
	var bodies: Array = root.find_children("*", "StaticBody3D", true, false)
	check(bodies.size() == 1, "one hidden StaticBody3D from -convcolonly")
	if bodies.size() == 1:
		var shapes: Array = bodies[0].find_children("*", "CollisionShape3D", true, false)
		var ok: bool = shapes.size() == 1 and shapes[0].shape is ConvexPolygonShape3D
		check(ok, "collider is a ConvexPolygonShape3D")
		if ok:
			check(shapes[0].shape.points.size() <= 64, "hull vertices %d <= 64" % shapes[0].shape.points.size())


## Yaw about +Y read from the axle direction (independent of the spin about X).
func yaw_of(n: Node3D) -> float:
	var ax := n.basis * Vector3.RIGHT
	return atan2(-ax.z, ax.x)


func check_binder() -> void:
	var world := Node3D.new()
	var ground := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 2, 200)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	ground.add_child(cs)
	world.add_child(ground)
	get_root().add_child(world)
	var v := Vehicle.new()
	v.definition = load("res://vehicle/definitions/reference_car.tres")
	v.position = Vector3(0, 0.05, 0)
	world.add_child(v)
	var vis := VehicleVisual.new()
	v.add_child(vis)
	await physics_frame
	check(vis.model_root.find_children("*", "StaticBody3D", true, false).is_empty(), "binder removed the hull StaticBody3D")
	check(v.find_children("*", "CollisionShape3D", true, false).size() == 1, "Vehicle keeps only its own chassis collider")
	for i in 120:
		await physics_frame
	for w in v.wheels:
		check(w.is_grounded, String(w.name) + " grounded at rest")
	vis.advance(0.0)
	for w in v.wheels:
		var tag := String(w.name).trim_prefix("Wheel")
		var node := vis.model_root.find_child("wheel_" + tag, true, false) as Node3D
		var hub: Vector3 = node.get_parent().to_global(node.position)
		check(hub.distance_to(vis.hub_world(w)) <= 0.01, "%s visual hub matches Wheel hub" % tag)
		var expected := w.contact_point + Vector3.UP * R
		check(hub.distance_to(expected) <= 0.01, "%s hub == contact + up*radius (%.4f m off)" % [tag, hub.distance_to(expected)])
	# spin: omega = 10 rad/s for 1 s (frozen physics state, binder driven manually)
	v.freeze = true
	for w in v.wheels:
		w.omega = 10.0
	for i in 100:
		vis.advance(0.01)
	var rl := vis.model_root.find_child("wheel_RL", true, false) as Node3D
	var top := rl.basis * Vector3.UP
	var ang := fposmod(atan2(top.z, top.y), TAU)
	var want := fposmod(10.0, TAU)
	check(absf(wrapf(ang - want, -PI, PI)) <= 0.01, "omega 10 rad/s for 1 s -> %.4f rad (want %.4f)" % [ang, want])
	# positive omega: top moves toward +Z (model frame)
	for w in v.wheels:
		w.omega = 1.0
	var t0 := rl.basis * Vector3.UP
	vis.advance(0.01)
	var t1 := rl.basis * Vector3.UP
	check(wrapf(atan2(t1.z, t1.y) - atan2(t0.z, t0.y), -PI, PI) > 0.0, "positive omega moves the wheel top toward +Z")
	# steer
	for w in v.wheels:
		w.omega = 0.0
		w.steer_angle = 0.3
	vis.advance(0.0)
	for tag in ["FL", "FR"]:
		var wn := vis.model_root.find_child("wheel_" + tag, true, false) as Node3D
		var cn := vis.model_root.find_child("caliper_" + tag, true, false) as Node3D
		check(absf(yaw_of(wn) - (-0.3)) <= 0.001, tag + " wheel yaw -0.3")
		check(absf(yaw_of(cn) - (-0.3)) <= 0.001, tag + " caliper yaw -0.3")
	for tag in ["RL", "RR"]:
		var wn := vis.model_root.find_child("wheel_" + tag, true, false) as Node3D
		check(absf(yaw_of(wn)) <= 0.001, tag + " wheel yaw stays 0")
	# calipers never spin
	for w in v.wheels:
		w.omega = 7.0
	vis.advance(0.1)
	var cal := vis.model_root.find_child("caliper_FL", true, false) as Node3D
	check(absf(cal.basis.get_euler(EULER_ORDER_YXZ).x) <= 0.001, "caliper does not spin")
	world.queue_free()
