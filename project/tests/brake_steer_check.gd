## Physics-car full-brake checks (#229, part of #222; extends #215/#223/#216 to the real Vehicle).
##  A. zero steer, brake 1.0, from 40 and 80 km/h on flat tarmac and flat gravel: peak |yaw rate| < 1 deg/s.
##  B. steer +-0.3, brake 1.0 and 0, from 40 and 80 km/h on tarmac: above 5 m/s and after a 0.3 s settle the
##     yaw sign equals the turn sign for every sample, and the mean |yaw rate| is above 1 deg/s (estimate).
##  C. spin made under braking (real Vehicle + ChaseCamera, scripted): after spin end (|yaw rate| < 20 deg/s,
##     estimate) the nose-to-camera angle is beyond 90 deg for <= 0.5 s total and within 10 deg by 0.38 s.
## Violations are bugs against #223 / #216, not fixed here.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/brake_steer_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")
const DT := 1.0 / 120.0
const YAW_LIMIT_DEG := 1.0
const SETTLE_S := 0.3
const MIN_SPEED := 5.0
const MIN_MEAN_YAW_DEG := 1.0
const SPIN_END_DEG_S := 20.0
const SPIN_MIN_DEG_S := 60.0 ## yaw rate the car must reach for the scenario to count as a spin
const REVERSED_MAX_S := 0.5
const ALIGN_BY_S := 0.38

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _add_strips(world: Node3D) -> void:
	for spec in [["tarmac", -250.0], ["gravel", -300.0]]:
		var body := StaticBody3D.new()
		body.name = "Strip_" + String(spec[0])
		body.add_to_group("surface_" + String(spec[0]))
		body.set_meta("surface_id", String(spec[0]))
		body.position = Vector3(float(spec[1]), -0.03, -150.0)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(20.0, 0.1, 500.0)
		cs.shape = box
		body.add_child(cs)
		world.add_child(body)
		var m := Marker3D.new()
		m.name = "Spawn_" + String(spec[0])
		m.position = Vector3(float(spec[1]), 0.4, 80.0)
		world.add_child(m)


func _scenario(spawn: String, kmh: float, inputs: Array, ticks: int) -> Scenario:
	var sc := Scenario.new(self, spawn, inputs, ticks)
	sc.initial_speed = kmh / 3.6
	sc.world_setup = _add_strips # narrow strips: only the straight A runs use them
	return sc


## Signed yaw rate (deg/s, + = left) at sample i of a scenario result.
func _yaw(r: Dictionary, i: int) -> float:
	var f0: Vector3 = r.fwd[i]
	var f1: Vector3 = r.fwd[i + 1]
	return rad_to_deg(atan2(f0.cross(f1).y, f0.dot(f1)) / DT)


func _case_a() -> void:
	for surf in ["tarmac", "gravel"]:
		for kmh in [40.0, 80.0]:
			var sc := _scenario("Spawn_" + surf, kmh, [{"t": 0.0, "brake": 1.0}], 120 * 3)
			sc.csv_path = "user://brake_steer_a_%s_%d.csv" % [surf, int(kmh)]
			var r: Dictionary = await sc.run()
			var peak := 0.0
			for i in r.ticks - 1:
				peak = maxf(peak, absf(_yaw(r, i)))
			cu.check_range("A %s %d km/h brake 1.0 steer 0: peak |yaw| deg/s" % [surf, int(kmh)], peak, 0.0, YAW_LIMIT_DEG, sc.csv_path)


func _case_b() -> void:
	for brake in [1.0, 0.0]:
		for steer in [0.3, -0.3]:
			for kmh in [40.0, 80.0]:
				var sc := _scenario("Spawn_Flat", kmh, [{"t": 0.0, "steer": steer, "brake": brake}], 120 * 3)
				sc.csv_path = "user://brake_steer_b_%d_%+.1f_%d.csv" % [int(brake), steer, int(kmh)]
				var r: Dictionary = await sc.run()
				var wrong := 0
				var sum := 0.0
				var n := 0
				for i in r.ticks - 1:
					if float(r.t[i]) < SETTLE_S or float(r.speed[i]) <= MIN_SPEED:
						continue
					var y := _yaw(r, i)
					sum += absf(y)
					n += 1
					if y * steer >= 0.0: # steer + = right = negative yaw
						wrong += 1
				var mean := sum / maxf(float(n), 1.0)
				var tag := "B brake %.0f steer %+.1f %d km/h" % [brake, steer, int(kmh)]
				cu.check(n > 0 and wrong == 0, "%s: %d of %d samples with yaw against the steer" % [tag, wrong, n])
				cu.check(mean > MIN_MEAN_YAW_DEG, "%s: mean |yaw| %.2f deg/s > %.1f (n=%d)" % [tag, mean, MIN_MEAN_YAW_DEG, n])


func _spin_specs() -> Array:
	return [
		{"name": "brake 0.3 + steer step 1.0 + handbrake at 80 km/h", "kmh": 80.0, "inputs": [
			{"t": 0.0, "brake": 0.3, "steer": 1.0}, {"t": 0.3, "brake": 0.3, "steer": 1.0, "handbrake": true}]},
		{"name": "brake 0.2 + steer step -1.0 + handbrake at 80 km/h", "kmh": 80.0, "inputs": [
			{"t": 0.0, "brake": 0.2}, {"t": 0.3, "brake": 0.2, "steer": -1.0, "handbrake": true}]},
		{"name": "brake 0.3 + steer step 1.0 + handbrake at 50 km/h", "kmh": 50.0, "inputs": [
			{"t": 0.0, "brake": 0.3, "steer": 1.0}, {"t": 0.3, "brake": 0.3, "steer": 1.0, "handbrake": true}]},
	]


## C: spin under braking, with a chase camera on the real Vehicle.
func _case_c() -> void:
	for spec in _spin_specs():
		var cs := {"cam": null, "spin_end": -1.0, "rev": 0.0, "aligned": -1.0, "max_yaw": 0.0}
		var sc := _scenario("Spawn_Flat", spec.kmh, spec.inputs, 120 * 5)
		sc.controller = func(tick: int, v: Vehicle, _st: DriverInputState) -> void:
			if cs.cam == null:
				var c: ChaseCamera = load("res://camera/chase_camera.tscn").instantiate()
				c.target = v
				v.get_tree().root.add_child(c)
				cs.cam = c
			var cam: ChaseCamera = cs.cam
			cam.advance(DT)
			var yaw := absf(rad_to_deg(v.angular_velocity.y))
			cs.max_yaw = maxf(cs.max_yaw, yaw)
			var rel := absf(angle_difference(cam.rig.yaw, ChaseMath.yaw_of(-v.global_basis.z)))
			if cs.spin_end < 0.0:
				if cs.max_yaw > SPIN_MIN_DEG_S and yaw < SPIN_END_DEG_S:
					cs.spin_end = float(tick) * DT
				return
			if rel > PI * 0.5:
				cs.rev += DT
			if cs.aligned < 0.0 and rad_to_deg(rel) <= 10.0:
				cs.aligned = float(tick) * DT - cs.spin_end
		await sc.run()
		cs.cam.queue_free()
		var tag := "C %s" % spec.name
		print("INFO: %s: peak yaw %.0f deg/s, spin end %.2f s, beyond-90 %.2f s, aligned %.2f s after" % [
				tag, cs.max_yaw, cs.spin_end, cs.rev, cs.aligned])
		cu.check(cs.spin_end >= 0.0, "%s: car spun (peak %.0f deg/s) and the spin ended" % [tag, cs.max_yaw])
		cu.check_range("%s: nose-to-camera beyond 90 deg after spin end, s" % tag, cs.rev, 0.0, REVERSED_MAX_S)
		cu.check(cs.aligned >= 0.0 and cs.aligned <= ALIGN_BY_S,
				"%s: realigned within 10 deg %.2f s after spin end (<= %.2f)" % [tag, cs.aligned, ALIGN_BY_S])


func _main() -> void:
	await physics_frame
	await _case_a()
	await _case_b()
	await _case_c()
	cu.finish(self)
