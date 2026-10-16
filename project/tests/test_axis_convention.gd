extends GutTest
## Axis convention (#88): sim forward is -Z; model nose is +Z; VehicleVisual rotates 180 deg.
## VehicleVisual.model_root is the only node under the Vehicle allowed to carry a PI yaw.

var _world: Node3D
var _v: Vehicle
var _vis: VehicleVisual


func before_each() -> void:
	_world = Node3D.new()
	var ground := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 2, 400)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	ground.add_child(cs)
	_world.add_child(ground)
	add_child(_world)
	_v = Vehicle.new()
	_v.definition = load("res://vehicle/definitions/reference_car.tres")
	_v.position = Vector3(0, 0.05, 0)
	_world.add_child(_v)
	_vis = VehicleVisual.new()
	_v.add_child(_vis)


func after_each() -> void:
	_world.queue_free()


func test_nose_marker_is_on_minus_z_side() -> void:
	await wait_physics_frames(2)
	var nose := _vis.model_root.find_child("marker_light_head", true, false) as Node3D
	var tail := _vis.model_root.find_child("marker_light_brake", true, false) as Node3D
	assert_not_null(nose, "nose marker exists")
	assert_not_null(tail, "tail marker exists")
	var fwd := -_v.global_basis.z
	assert_gt((nose.global_position - _v.global_position).dot(fwd), 0.0, "nose is on the -Z side of the body")
	assert_lt((tail.global_position - _v.global_position).dot(fwd), 0.0, "tail is on the +Z side of the body")


func test_only_model_root_is_turned_pi() -> void:
	await wait_physics_frames(2)
	assert_almost_eq(_vis.model_root.rotation.y, PI, 1e-5,"model_root.rotation.y == PI")
	var turned: Array = []
	for n in _v.find_children("*", "Node3D", true, false):
		if n != _vis.model_root and absf(absf(wrapf((n as Node3D).rotation.y, -PI, PI)) - PI) < 0.01:
			turned.append(n.name)
	assert_eq(turned, [], "no other Vehicle descendant has a PI yaw")


func test_forward_force_moves_toward_minus_z() -> void:
	await wait_physics_frames(60)
	for i in 60:
		_v.apply_central_force(-_v.global_basis.z * 4000.0)
		await wait_physics_frames(1)
	assert_gt(_v.linear_velocity.dot(-_v.global_basis.z), 0.0, "forward force moves the body toward -Z")
	assert_lt(_v.linear_velocity.z, 0.0, "world velocity z is negative")
