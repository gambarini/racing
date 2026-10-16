## Headless check (#82): DriverInput -> Vehicle scripted turn and braking. Run:
## godot --headless --fixed-fps 120 --path project -s res://tests/steering_check.gd
extends SceneTree

var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


func make_vehicle() -> Vehicle:
	var root := Node3D.new()
	var ground := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 2, 4000)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	ground.add_child(cs)
	root.add_child(ground)
	get_root().add_child(root)
	var v: Vehicle = load("res://vehicle/vehicle.gd").new()
	v.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.05, 0))
	root.add_child(v)
	return v


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func roll_at(v: Vehicle, speed: float) -> void:
	v.linear_velocity = -v.global_transform.basis.z * speed
	for w in v.wheels:
		w.omega = speed / w.radius


func heading_deg(v: Vehicle) -> float:
	var f := -v.global_transform.basis.z
	return rad_to_deg(atan2(f.x, -f.z)) # + = clockwise from above (right turn)


func _initialize() -> void:
	var v := make_vehicle()
	await frames(240)
	# Tire direction: both front wheels at 0.1 rad while rolling straight.
	v.tire_params = TireParams.new()
	v.tire_params.relaxation_length = 0.01 # near-instant slip so the geometric angle is visible
	roll_at(v, 10.0)
	v.wheels[0].steer_angle = 0.1
	v.wheels[1].steer_angle = 0.1
	await frames(1)
	var a := 0.0
	for i in 3:
		await frames(1)
		a = maxf(a, absf(v.wheels[0].alpha))
	print("front |alpha| peak in first 0.1 s: ", a)
	check(absf(a - 0.1) < 0.02, "front slip angle %.3f ~ 0.10 rad (sign: right steer gives negative alpha)" % a)
	check(v.wheels[0].alpha < 0.0 and v.wheels[0].fy > 0.0, "right steer gives fy > 0 (toward right)")
	v.wheels[0].steer_angle = 0.0
	v.wheels[1].steer_angle = 0.0

	# Scripted turn through DriverInput, no glue besides apply_input.
	var v2 := make_vehicle()
	v2.global_position += Vector3(100, 0, 0)
	await frames(240)
	roll_at(v2, 10.0)
	var di := DriverInput.new()
	get_root().add_child(di)
	var h0 := heading_deg(v2)
	var yaw_sum := 0.0
	var max_alpha := 0.0
	for i in 240:
		di.step_raw(0.0, 0.0, 0.0, false, 1.0 / 120.0)
		di.state.steer = 0.2
		v2.apply_input(di.state)
		await frames(1)
		yaw_sum += v2.angular_velocity.y
		max_alpha = maxf(max_alpha, absf(v2.wheels[0].alpha))
	var dh := heading_deg(v2) - h0
	print("TURN heading change %.1f deg, mean yaw rate y %.3f rad/s, front alpha max %.3f" % [dh, yaw_sum / 240.0, max_alpha])
	check(yaw_sum < 0.0, "yaw rate about +Y negative = clockwise (right turn)")
	check(dh > 8.0 and dh < 45.0, "heading change %.1f in 8..45 deg" % dh)

	# Braking from 20 m/s, no ABS.
	var v3 := make_vehicle()
	v3.global_position += Vector3(-100, 0, 0)
	await frames(240)
	roll_at(v3, 20.0)
	var s := DriverInputState.new()
	s.brake = 1.0
	var p0 := v3.global_position
	var t := 0
	while v3.linear_velocity.length() > 0.2 and t < 1200:
		v3.apply_input(s)
		await frames(1)
		t += 1
	var dist := v3.global_position.distance_to(p0)
	print("BRAKE 20 m/s stop distance %.1f m in %.2f s" % [dist, t / 120.0])
	check(dist >= 16.0 and dist <= 28.0, "stopping distance %.1f in 16..28 m" % dist)
	print("RESULT: ", "FAIL (%d)" % failures if failures > 0 else "OK")
	quit(1 if failures > 0 else 0)
