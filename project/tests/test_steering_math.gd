extends GutTest
## Ackermann geometry, brake split and input clamping (#82).

const MAX := 0.5934119 # 34 deg


func test_full_right_ackermann() -> void:
	var a := SteeringMath.wheel_angles(1.0, MAX, 1.0, 2.5, 1.5)
	assert_almost_eq(rad_to_deg(a.y), 34.0, 0.01)
	assert_almost_eq(rad_to_deg(a.x), 25.6, 0.3)


func test_parallel_and_center_and_mirror() -> void:
	var p := SteeringMath.wheel_angles(1.0, MAX, 0.0, 2.5, 1.5)
	assert_almost_eq(rad_to_deg(p.x), 34.0, 0.01)
	assert_almost_eq(rad_to_deg(p.y), 34.0, 0.01)
	var z := SteeringMath.wheel_angles(0.0, MAX, 1.0, 2.5, 1.5)
	assert_eq(z, Vector2.ZERO)
	var l := SteeringMath.wheel_angles(-1.0, MAX, 1.0, 2.5, 1.5)
	var r := SteeringMath.wheel_angles(1.0, MAX, 1.0, 2.5, 1.5)
	assert_almost_eq(l.x, -r.y, 1e-6)
	assert_almost_eq(l.y, -r.x, 1e-6)


func _vehicle() -> Vehicle:
	var v := Vehicle.new()
	add_child_autofree(v)
	return v


func test_apply_input_clamps_and_brake_split() -> void:
	var v := _vehicle()
	var s := DriverInputState.new()
	s.steer = 3.0
	s.throttle = 2.0
	s.brake = 0.5
	s.handbrake = true
	v.apply_input(s)
	assert_eq(v.steer, 1.0)
	assert_eq(v.throttle, 1.0)
	assert_true(v.handbrake)
	assert_eq(v.wheels[0].brake_torque, 800.0)
	assert_eq(v.wheels[3].brake_torque, 500.0)
	assert_almost_eq(rad_to_deg(v.wheels[1].steer_angle), 34.0, 0.01)
	assert_eq(v.wheels[2].steer_angle, 0.0)
	s.steer = -5.0
	s.brake = -1.0
	v.apply_input(s)
	assert_eq(v.steer, -1.0)
	assert_eq(v.wheels[0].brake_torque, 0.0)
	assert_lt(v.wheels[0].steer_angle, 0.0)
