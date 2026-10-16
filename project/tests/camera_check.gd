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

	print("camera_check failures: ", failures)
	quit(1 if failures > 0 else 0)
