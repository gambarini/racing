## Headless integration check: real #8 Vehicle + #9 tire model + #10 wheel spin.
## Standalone SceneTree script (async physics frames are noisy under GUT headless).
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/wheel_spin_vehicle_check.gd
extends SceneTree

const R := 0.32
var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


func _initialize() -> void:
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
	v.tire_forces_enabled = true
	v.position = Vector3(0, 0.05, 0)
	root.add_child(v)
	for i in 120:
		await physics_frame
	var fwd := -v.global_transform.basis.z
	v.linear_velocity = fwd * 20.0
	for w in v.wheels:
		w.omega = 20.0 / R
	var worst := 0.0
	var finite := true
	for i in 360:
		await physics_frame
		for w in v.wheels:
			worst = maxf(worst, absf(w.kappa))
			finite = finite and is_finite(w.omega)
	check(finite, "omega finite")
	check(worst < 0.02, "rolling 20 m/s for 3 s: max |kappa| = %.4f" % worst)
	var vx0 := v.linear_velocity.dot(fwd)
	v.handbrake = true
	for i in 48:
		await physics_frame
	var vx := v.linear_velocity.dot(fwd)
	check(v.wheels[2].omega < 0.1 * vx0 / R and v.wheels[3].omega < 0.1 * vx0 / R,
			"handbrake: rear omega %.2f < 10 %% of rolling %.1f" % [v.wheels[2].omega, vx0 / R])
	check(absf(v.wheels[0].kappa) < 0.05 and absf(v.wheels[1].kappa) < 0.05,
			"front keeps rolling (kappa %.3f)" % v.wheels[0].kappa)
	check(vx < vx0 and vx > 0.0, "car slowed by rear lock but still moving (%.1f -> %.1f)" % [vx0, vx])
	v.handbrake = false
	for i in 120:
		await physics_frame
	check(absf(v.wheels[2].kappa) < 0.05, "rear recovers rolling within 1 s (kappa %.3f)" % v.wheels[2].kappa)
	print("RESULT: ", "FAIL (%d)" % failures if failures > 0 else "OK")
	quit(1 if failures > 0 else 0)
