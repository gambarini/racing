## Jolt spike smoke check (#2): backend setting, rigid body rest on static floor, one ray hit.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/jolt_smoke_check.gd
extends SceneTree

var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var engine_name = ProjectSettings.get_setting("physics/3d/physics_engine")
	print("physics/3d/physics_engine = ", engine_name)
	check(engine_name == "Jolt Physics", "physics engine setting is Jolt Physics")

	var root := Node3D.new()
	get_root().add_child(root)
	var floor_body := StaticBody3D.new()
	var fcs := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(50, 2, 50)
	fcs.shape = fbox
	fcs.position = Vector3(0, -1, 0) # top surface at y = 0
	floor_body.add_child(fcs)
	root.add_child(floor_body)

	var rb := RigidBody3D.new()
	var rcs := CollisionShape3D.new()
	var rbox := BoxShape3D.new()
	rbox.size = Vector3(1, 1, 1)
	rcs.shape = rbox
	rb.add_child(rcs)
	rb.position = Vector3(0, 2, 0)
	root.add_child(rb)

	# 2 s simulated at 120 Hz = 240 physics frames.
	for i in 240:
		await physics_frame
		if i % 40 == 0:
			print("t=", i, " y=", rb.global_position.y, " vy=", rb.linear_velocity.y)
	var rest_y := rb.global_position.y - 0.5 # bottom face height above floor surface
	print("rest height above surface (m) = ", rest_y)
	# Jolt's default penetration slop (2 cm) lets resting bodies sink up to that far; see ADR 001.
	# Tuning it is out of scope for #2, so the tolerance is slop + 1 mm. Rest must also be stable.
	var slop: float = ProjectSettings.get_setting("physics/jolt_physics_3d/simulation/penetration_slop", 0.02)
	print("penetration_slop = ", slop)
	check(absf(rest_y) <= slop + 0.001, "box rests within penetration slop (+1 mm) of surface after 2 s")
	check(absf(rb.linear_velocity.y) < 0.01, "box is at rest")

	var space := root.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(10, 5, 10), Vector3(10, -5, 10))
	var hit := space.intersect_ray(q)
	check(not hit.is_empty() and absf(hit.position.y) < 0.001, "intersect_ray hits floor top at y=0")

	print("jolt_smoke_check failures: ", failures)
	quit(1 if failures > 0 else 0)
