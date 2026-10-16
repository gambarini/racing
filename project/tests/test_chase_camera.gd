extends GutTest
## Pure chase camera maths (#14): yaw blend, FOV, spring, rig convergence, angle wrap.

const DT := 1.0 / 60.0

var p := CameraProfile.new()


func test_profile_defaults() -> void:
	assert_eq(p.distance, 6.0)
	assert_eq(p.height, 2.2)
	assert_eq(p.fov_max, 85.0)
	var near: CameraProfile = load("res://camera/chase_near.tres")
	var far: CameraProfile = load("res://camera/chase_far.tres")
	assert_eq(near.distance, 5.0)
	assert_eq(near.height, 1.8)
	assert_eq(far.distance, 8.0)
	assert_eq(far.height, 2.8)
	assert_eq(far.follow_freq, 5.0)


func test_blend_40deg_at_20ms() -> void:
	var y := ChaseMath.target_yaw(0.0, deg_to_rad(40.0), 20.0, p)
	assert_almost_eq(rad_to_deg(y), 24.0, 1.0)


func test_blend_low_speed_is_heading() -> void:
	var y := ChaseMath.target_yaw(0.0, deg_to_rad(40.0), 2.0, p)
	assert_almost_eq(rad_to_deg(y), 0.0, 0.01)


func test_blend_reversing_is_heading() -> void:
	var y := ChaseMath.target_yaw(0.3, 0.3 + PI, 15.0, p)
	assert_almost_eq(y, 0.3, 0.001)


func test_blend_wraps_across_pi() -> void:
	# heading 170 deg, velocity -170 deg: shortest way is +20 deg, so the blend goes through 180.
	var y := ChaseMath.target_yaw(deg_to_rad(170.0), deg_to_rad(-170.0), 20.0, p)
	assert_almost_eq(rad_to_deg(y), 170.0 + 12.0, 1.0)


func test_fov_curve() -> void:
	assert_almost_eq(ChaseMath.target_fov(0.0, p), 70.0, 0.1)
	assert_almost_eq(ChaseMath.target_fov(35.0, p), 77.5, 0.5)
	assert_almost_eq(ChaseMath.target_fov(60.0, p), 85.0, 0.2)
	assert_almost_eq(ChaseMath.target_fov(200.0, p), 85.0, 0.2)
	assert_almost_eq(ChaseMath.target_fov(-5.0, p), 70.0, 0.1)


func test_spring_converges_without_overshoot() -> void:
	var x := 1.0
	var v := 0.0
	var peak := 1.0
	for i in 180:
		var r := ChaseMath.spring_step(x, v, 0.0, 0.0, 5.0, DT)
		x = r[0]
		v = r[1]
		peak = minf(peak, x)
	assert_lt(absf(x), 1e-3)
	assert_gt(peak, -1e-6, "critically damped: no overshoot")


func test_spring_is_step_size_independent() -> void:
	var a := ChaseMath.spring_step(1.0, 0.5, 0.0, 2.0, 5.0, 0.1)
	var x := 1.0
	var v := 0.5
	var t := 0.0
	for i in 10:
		var r := ChaseMath.spring_step(x, v, 2.0 * t, 2.0, 5.0, 0.01)
		x = r[0]
		v = r[1]
		t += 0.01
	assert_almost_eq(x, a[0], 1e-9)
	assert_almost_eq(v, a[1], 1e-9)


func test_rig_yaw_converges_to_blend_target() -> void:
	var rig := ChaseRig.new()
	var heading := Vector3(0, 0, -1)
	var vdir := Vector3(-sin(deg_to_rad(40.0)), 0, -cos(deg_to_rad(40.0)))
	rig.step(Vector3.ZERO, Vector3.ZERO, heading, p, DT)
	var pos := Vector3.ZERO
	for i in 180:
		var v := vdir * 20.0
		pos += v * DT
		rig.step(pos, v, heading, p, DT)
	var want := ChaseMath.target_yaw(0.0, deg_to_rad(40.0), 20.0, p)
	assert_lt(absf(rad_to_deg(angle_difference(rig.yaw, want))), 0.5)


func test_rig_no_yaw_step_when_velocity_sweeps_across_pi() -> void:
	var rig := ChaseRig.new()
	var heading := Vector3(0, 0, 1) # facing +Z, yaw = 180 deg
	rig.step(Vector3.ZERO, Vector3.ZERO, heading, p, DT)
	var worst := 0.0
	var prev := rig.yaw
	for i in 240:
		var a := deg_to_rad(120.0) * i * DT # sweeps velocity direction through 180 deg
		var v := Vector3(sin(a), 0, cos(a)) * 20.0
		rig.step(Vector3.ZERO, v, heading, p, DT)
		worst = maxf(worst, absf(rad_to_deg(angle_difference(prev, rig.yaw))))
		prev = rig.yaw
	assert_lt(worst, 5.0)


func test_rig_steady_state_offset() -> void:
	var rig := ChaseRig.new()
	var heading := Vector3(0, 0, -1)
	var pos := Vector3.ZERO
	rig.step(pos, Vector3(0, 0, -30), heading, p, DT)
	for i in 180:
		pos += Vector3(0, 0, -30) * DT
		rig.step(pos, Vector3(0, 0, -30), heading, p, DT)
	assert_almost_eq(rig.pos.z - pos.z, p.distance, 0.1)
	assert_almost_eq(rig.pos.y - pos.y, p.height, 0.1)
	assert_almost_eq(rig.pos.x - pos.x, 0.0, 0.1)
