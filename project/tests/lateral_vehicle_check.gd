## Headless integration check (#74): real Vehicle with Fy on. Run:
## godot --headless --fixed-fps 120 --path project -s res://tests/lateral_vehicle_check.gd
extends SceneTree

var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


func make_vehicle(roll_deg := 0.0) -> Vehicle:
	var root := Node3D.new()
	var ground := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 2, 4000)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	ground.add_child(cs)
	ground.rotation = Vector3(0.0, 0.0, deg_to_rad(roll_deg))
	root.add_child(ground)
	get_root().add_child(root)
	var v: Vehicle = load("res://vehicle/vehicle.gd").new()
	v.transform = Transform3D(ground.basis, ground.basis.y * 0.05)
	root.add_child(v)
	return v


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	var v := make_vehicle()
	check(v.tire_forces_enabled, "tire_forces_enabled defaults to true")
	await frames(240)
	var p0 := v.global_position
	await frames(240)
	var creep := v.global_position.distance_to(p0)
	check(creep < 0.005 and v.linear_velocity.length() < 0.01, "rests on flat ground: creep %.4f m" % creep)
	# Sideways slide: Fy appears, opposes the sideslip, and the lateral speed dies out.
	var right := v.global_transform.basis.x
	var fwd := -v.global_transform.basis.z
	v.linear_velocity = fwd * 10.0 + right * 3.0
	for w in v.wheels:
		w.omega = 10.0 / w.radius
	await frames(6)
	var w0: Wheel = v.wheels[0]
	check(w0.alpha > 0.0 and w0.fy < 0.0, "alpha>0 gives Fy<0 (alpha %.3f, fy %.0f)" % [w0.alpha, w0.fy])
	var finite := true
	for i in 360:
		await frames(1)
		finite = finite and is_finite(v.linear_velocity.length())
	var lat := absf(v.linear_velocity.dot(right))
	check(finite, "state finite")
	check(lat < 0.3, "lateral speed decays 3 -> %.3f m/s" % lat)
	# Parked on a 10 deg side slope with brakes on: holds (grip comes from Fy).
	var s := make_vehicle(10.0)
	for w in s.wheels:
		w.brake_torque = 4000.0
	await frames(240)
	var q0 := s.global_position
	await frames(360)
	var drift := s.global_position.distance_to(q0)
	check(drift < 0.05, "side slope hold: moved %.4f m in 3 s" % drift)
	check(s.linear_velocity.length() < 0.05, "side slope hold: speed %.4f" % s.linear_velocity.length())
	print("RESULT: ", "FAIL (%d)" % failures if failures > 0 else "OK")
	quit(1 if failures > 0 else 0)
