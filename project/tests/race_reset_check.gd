## Reset-to-track (#106): flip the car, press the reset action, check it is upright, on the centre
## line at the last gate facing the tangent, stopped, penalised 5 s and drivable.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/race_reset_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const DT := 1.0 / 120.0
var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _main() -> void:
	await physics_frame
	var world := Node3D.new()
	root.add_child(world)
	var ground := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 2, 4000)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	ground.add_child(cs)
	world.add_child(ground)
	var track := TrackSpline.make_circle(100.0, 8)
	track.gate_half_width = 20.0
	world.add_child(track)
	var timer := track.make_lap_timer(DT)
	var v: Vehicle = load("res://vehicle/vehicle.gd").new()
	v.transform = track.grid_transform(0).translated(Vector3(0, 0.3, 0))
	world.add_child(v)
	var mon := RaceMonitor.new()
	mon.setup(v, track, timer)
	world.add_child(mon)
	await _frames(120)

	# Timer passes gates 0..2 (synthetic crossings; the car stays put).
	timer.teleported()
	for g in 3:
		var s := track.sample(track.gate_offsets[g])
		timer.step(s["position"] - s["forward"] * 1.0)
		timer.step(s["position"] + s["forward"] * 1.0)
	cu.check(timer.running and timer.last_gate_crossed == 2, "timer reached gate 2")

	# Flip the car onto its roof, moving, and let it settle.
	v.global_transform = Transform3D(Basis(Vector3.FORWARD, PI), Vector3(30, 1.0, -30))
	v.linear_velocity = Vector3(5, 0, 3)
	v.angular_velocity = Vector3(1, 0, 2)
	await _frames(240)
	cu.check(v.global_transform.basis.y.y < 0.0, "car is upside down before the reset")

	# Press the reset action (the real input path, while flipped).
	Input.action_press(&"reset_to_track")
	await _frames(2)
	Input.action_release(&"reset_to_track")
	var expect := track.reset_transform(2)
	var p := v.global_position
	var line_pt := track.centre_line.get_closest_point(track.to_local(p))
	var horiz := Vector2(p.x - line_pt.x, p.z - line_pt.z).length()
	cu.check_range("distance to centre line after reset (m)", horiz, 0.0, 0.1)
	cu.check_range("distance to gate 2 (m)", Vector2(p.x - expect.origin.x, p.z - expect.origin.z).length(), 0.0, 0.5)
	var fwd := -v.global_transform.basis.z
	var tan: Vector3 = track.sample(track.nearest_offset(p))["forward"]
	cu.check_range("heading vs tangent (dot)", fwd.dot(tan), 0.99, 1.001)
	cu.check_range("up.y after reset", v.global_transform.basis.y.y, 0.99, 1.001)
	cu.check_range("speed right after reset (m/s)", v.linear_velocity.length(), 0.0, 0.5)
	cu.check(mon.resets == 1, "one reset counted")
	cu.check_range("penalty (s)", timer.penalty_ticks * DT, 5.0, 5.0)

	# Drivable: settle, then full throttle for 4 s moves it forward along the track.
	await _frames(120)
	var p0 := v.global_position
	var st := DriverInputState.new()
	st.throttle = 1.0
	for i in 480:
		v.apply_input(st)
		await physics_frame
	var d := v.global_position - p0
	cu.check_range("distance driven along heading after reset (m)", d.dot(tan), 10.0, 500.0)
	cu.check_range("still upright", v.global_transform.basis.y.y, 0.9, 1.0)
	cu.finish(self)
