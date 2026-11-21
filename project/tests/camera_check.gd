## Headless check for the chase camera scene (#14) with a scripted Node3D target.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/camera_check.gd
extends SceneTree

const TURN_START := 4.0
const TURN_TIME := 1.0
const SPEED := 30.0
var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


## Scripted path: 0->30 m/s over 3 s, straight to 4 s, 90 deg left turn over 1 s, straight to 7 s.
## Returns [position, heading_yaw].
func path(t: float) -> Array:
	var w := (PI / 2.0) / TURN_TIME
	var pos := Vector3.ZERO
	var yaw := 0.0
	if t <= 3.0:
		pos = Vector3(0, 0, -5.0 * t * t)
	else:
		pos = Vector3(0, 0, -45.0 - SPEED * (minf(t, TURN_START) - 3.0))
	if t > TURN_START:
		var tau := minf(t - TURN_START, TURN_TIME)
		# Heading d(a) = (-sin a, 0, -cos a); integrate SPEED * d over the arc.
		pos += Vector3(SPEED * (cos(w * tau) - 1.0) / w, 0, -SPEED * sin(w * tau) / w)
		yaw = w * tau
		var rest := maxf(0.0, t - TURN_START - TURN_TIME)
		var d := Vector3(-sin(PI / 2.0), 0, -cos(PI / 2.0))
		if tau >= TURN_TIME:
			pos += d * SPEED * rest
			yaw = PI / 2.0
	return [pos, yaw]


func make_cam(target: Node3D) -> ChaseCamera:
	var cam: ChaseCamera = load("res://camera/chase_camera.tscn").instantiate()
	cam.target = target
	get_root().add_child(cam)
	return cam


func place(target: Node3D, t: float) -> void:
	var s := path(t)
	target.position = s[0]
	target.rotation = Vector3(0, s[1], 0)


func run_path(fps: float) -> Vector3:
	var target := Node3D.new()
	get_root().add_child(target)
	var cam := make_cam(target)
	var dt := 1.0 / fps
	var n := int(round(7.0 * fps))
	for i in n + 1:
		place(target, i * dt)
		cam.advance(dt)
	var r := cam.global_position
	cam.queue_free()
	target.queue_free()
	return r


## Scripted 180 deg spin at ~80 km/h (#216): heading turns at 300 deg/s for 0.6 s while the car keeps
## sliding along its old velocity, then the velocity swings to the new nose over 0.8 s.
func spin_check() -> void:
	var fps := 60.0
	var dt := 1.0 / fps
	var target := Node3D.new()
	get_root().add_child(target)
	var cam := make_cam(target)
	var spin_t := 0.6
	var rate := PI / spin_t
	var v0 := Vector3(0, 0, -22.2)
	var pos := Vector3.ZERO
	var prev_cam := 0.0
	var max_rate := 0.0
	var max_step := 0.0
	var recover_t := -1.0  # time since the car yaw rate dropped under 60 deg/s
	var aligned_at := -1.0
	var reversed_until := 0.0  # last time (since spin end) the nose points towards the camera
	var steer_ok_late := true
	var n := int(4.0 * fps)
	for i in n:
		var t := i * dt
		var h := minf(t, spin_t) * rate if t > 0.5 else 0.0
		var yaw_rate := rate if (t > 0.5 and t < 0.5 + spin_t) else 0.0
		var k := clampf((t - 0.5 - spin_t) / 0.8, 0.0, 1.0)
		var nose := Vector3(-sin(h), 0, -cos(h))
		var vel := v0.lerp(nose * 22.2, k)
		pos += vel * dt
		target.position = pos
		target.rotation = Vector3(0, h, 0)
		if t > 0.5 + spin_t and recover_t < 0.0:
			recover_t = t
		cam.advance(dt)
		var cy: float = cam.rig.yaw
		if i > 1:
			var step := absf(rad_to_deg(angle_difference(prev_cam, cy)))
			max_step = maxf(max_step, step)
			max_rate = maxf(max_rate, step * fps)
		prev_cam = cy
		if recover_t >= 0.0:
			var rel: float = angle_difference(cy, h)
			var since := t - recover_t
			if cos(rel) < 0.0:
				reversed_until = since
			if aligned_at < 0.0 and absf(rad_to_deg(rel)) <= 10.0 and vel.dot(nose) > 0.0:
				aligned_at = since
			# Steering readability proxy: with steer sign s and heading rate w, nose screen x moves
			# by -cos(rel) * w * s; normal driving (rel ~ 0) gives negative, reversed when cos < 0.
			if since > 1.0 and cos(rel) <= 0.0:
				steer_ok_late = false
	print("spin: max cam yaw rate %.1f deg/s, max step %.2f deg/frame, aligned %.2f s after spin end, controls reversed for %.2f s" % [max_rate, max_step, aligned_at, reversed_until])
	check(max_rate <= 240.0, "spin: camera yaw rate %.1f <= 240 deg/s" % max_rate)
	check(max_step <= 15.0, "spin: single-frame camera yaw jump %.2f <= 15 deg" % max_step)
	check(aligned_at >= 0.0 and aligned_at <= 1.0, "spin: camera aligned within 10 deg %.2f s after spin end (<= 1.0)" % aligned_at)
	check(reversed_until <= 1.0, "spin: worst-case time controls look reversed %.2f s <= 1.0" % reversed_until)
	check(steer_ok_late, "spin: steering sign matches normal driving after the recovery window")
	cam.queue_free()
	target.queue_free()


## Backward travel: camera stays behind the nose, not the velocity.
func reverse_check() -> void:
	var dt := 1.0 / 60.0
	var target := Node3D.new()
	get_root().add_child(target)
	var cam := make_cam(target)
	var worst := 0.0
	for i in 240:
		target.position = Vector3(0, 0, 15.0 * i * dt)  # nose -Z, moving +Z
		cam.advance(dt)
		worst = maxf(worst, absf(rad_to_deg(cam.rig.yaw)))
	check(worst < 1.0, "reversing: camera yaw stays behind the nose (%.3f deg)" % worst)
	check(cam.global_position.z > target.position.z, "reversing: camera behind the nose side (+Z)")
	cam.queue_free()
	target.queue_free()


func _initialize() -> void:
	await process_frame
	# Steady state at 30 m/s straight, 3 s.
	var target := Node3D.new()
	get_root().add_child(target)
	var cam := make_cam(target)
	var dt := 1.0 / 60.0
	var near: CameraProfile = cam.profile
	for i in 241:
		target.position = Vector3(0, 0, -SPEED * i * dt)
		cam.advance(dt)
	var off := cam.global_position - target.position
	check(absf(off.z - near.distance) < 0.10, "steady distance %.3f vs %.1f" % [off.z, near.distance])
	check(absf(off.y - near.height) < 0.10, "steady height %.3f vs %.1f" % [off.y, near.height])
	check(cam.fov >= 70.0 and cam.fov <= 85.0, "fov in range %.2f" % cam.fov)
	# Runtime profile change takes effect next frame.
	near.distance = 8.0
	var before := cam.global_position
	cam.advance(dt)
	check(cam.global_position.distance_to(before) > 0.0 and cam.rig.pos.z - target.position.z > 6.0 - 1.0,
		"profile edit applies next frame")
	near.distance = 5.0
	cam.queue_free()
	target.queue_free()

	# Frame-rate independence.
	var a := run_path(60.0)
	var b := run_path(144.0)
	check(a.distance_to(b) < 0.02, "60 vs 144 fps final camera delta %.4f m" % a.distance_to(b))

	# Wrap: target circling so heading and velocity cross +/-180 deg.
	var t2 := Node3D.new()
	get_root().add_child(t2)
	var c2 := make_cam(t2)
	var worst := 0.0
	var prev := 0.0
	var r := 40.0
	var om := 20.0 / r
	for i in 600:
		var ang := om * i * dt
		t2.position = Vector3(r * cos(ang), 0, r * sin(ang))
		t2.rotation = Vector3(0, ChaseMath.yaw_of(Vector3(-sin(ang), 0, cos(ang))), 0)
		c2.advance(dt)
		if i > 1:
			worst = maxf(worst, absf(rad_to_deg(angle_difference(prev, c2.rig.yaw))))
		prev = c2.rig.yaw
	check(worst < 5.0, "max yaw step %.3f deg/frame" % worst)
	c2.queue_free()
	t2.queue_free()

	# Jitter: 120 Hz physics, 60 Hz render, straight at 30 m/s.
	var t3 := Node3D.new()
	get_root().add_child(t3)
	var c3 := make_cam(t3)
	var disp: Array[float] = []
	var last := Vector3.ZERO
	var tick := 1.0 / 120.0
	for f in 300:
		t3.position = Vector3(0, 0, -SPEED * (f * 2 + 2) * tick)
		c3.advance(2.0 * tick)
		if f > 60:
			disp.append(c3.global_position.distance_to(last))
		last = c3.global_position
	var mean := 0.0
	for d in disp:
		mean += d
	mean /= disp.size()
	var var_sum := 0.0
	for d in disp:
		var_sum += (d - mean) * (d - mean)
	var sd := sqrt(var_sum / disp.size())
	check(sd < 0.01, "per-frame displacement stddev %.5f m" % sd)
	c3.queue_free()
	t3.queue_free()

	spin_check()
	reverse_check()

	print("camera_check failures: ", failures)
	quit(1 if failures > 0 else 0)
