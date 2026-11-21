## Self-steer regression guard (#215, playtest #18: "the car can also turn by itself sometimes").
## Proves that zero steering input gives no unexpected steer angle or yaw:
##  A. flat tarmac and flat gravel, 30/60/100 km/h, steer 0, throttle held 2.5 s then released 2.5 s:
##     max |yaw rate| < 1.0 deg/s (estimate) and max |front steer angle| < 0.1 deg.
##  B. keyboard release through DriverInput + SteeringFilter (no direct vehicle injection): full
##     steer held 1 s, then released; front steer angle < 0.5 deg within 0.5 s and stays there.
##  C. Quarry road: the car is placed on the centre line at stations s with steer 0 at 40 and 80 km/h
##     for 1.0 s each; yaw rate and steer angle are tabulated by s. Steer angle must stay 0; yaw
##     rate above 2 deg/s is listed (camber / slope drift is expected there, see wiki Vehicle Physics).
## CSV: user://self_steer_<surface>_<kmh>.csv (A) and user://self_steer_quarry.csv (C)
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/self_steer_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")
const DT := 1.0 / 120.0
const YAW_LIMIT_DEG := 1.0
const STEER_LIMIT_DEG := 0.1
const QUARRY := "res://tracks/quarry/quarry_drive.tscn"
const QUARRY_STEP_S := 40.0
const QUARRY_RUN_TICKS := 120
const QUARRY_YAW_LIST_DEG := 2.0

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


func _case_a() -> void:
	for surf in ["tarmac", "gravel"]:
		for kmh in [30.0, 60.0, 100.0]:
			var inputs := [{"t": 0.0, "throttle": 1.0}, {"t": 2.5, "throttle": 0.0}]
			var sc := Scenario.new(self, "Spawn_" + surf, inputs, 120 * 5)
			sc.initial_speed = kmh / 3.6
			sc.world_setup = _add_strips
			var csv := "user://self_steer_%s_%d.csv" % [surf, int(kmh)]
			sc.csv_path = csv
			var r: Dictionary = await sc.run()
			var max_yaw := 0.0
			var max_steer := 0.0
			for i in r.ticks - 1:
				var f0: Vector3 = r.fwd[i]
				var f1: Vector3 = r.fwd[i + 1]
				var yaw := absf(rad_to_deg(f0.cross(f1).y / DT)) # heading change per second
				max_yaw = maxf(max_yaw, yaw)
				max_steer = maxf(max_steer, absf(rad_to_deg(r.steer_angle[i])))
			cu.check_range("A %s %d km/h max |yaw rate| deg/s" % [surf, int(kmh)], max_yaw, 0.0, YAW_LIMIT_DEG, csv)
			cu.check_range("A %s %d km/h max |front steer| deg" % [surf, int(kmh)], max_steer, 0.0, STEER_LIMIT_DEG, csv)


func _flat_vehicle() -> Vehicle:
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


func _front_deg(v: Vehicle) -> float:
	return rad_to_deg(0.5 * (v.wheels[0].steer_angle + v.wheels[1].steer_angle))


## B: hold full keyboard steer 1 s, release; per speed.
func _case_b() -> void:
	for kmh in [0.0, 30.0, 100.0]:
		var v := _flat_vehicle()
		for i in 240:
			await physics_frame
		var di := DriverInput.new()
		di.process_mode = Node.PROCESS_MODE_DISABLED # fed through step_raw below, not the InputMap
		get_root().add_child(di)
		var ticks_hold := 120
		var worst_after := 0.0
		var t_ok := -1
		var peak := 0.0
		for i in ticks_hold + 120: # 1 s held, 1 s released
			var held := i < ticks_hold
			di.speed_kmh = v.linear_velocity.length() * 3.6
			di.step_raw(1.0 if held else 0.0, 0.0, 0.0, false, DT)
			v.apply_input(di.state)
			# keep the car rolling at the test speed (steering must not depend on drag)
			var fwd := -v.global_transform.basis.z
			v.linear_velocity = fwd * (kmh / 3.6)
			await physics_frame
			var a := absf(_front_deg(v))
			if held:
				peak = maxf(peak, a)
			else:
				var k := i - ticks_hold
				if a < 0.5 and t_ok == -1:
					t_ok = k
				if t_ok >= 0:
					worst_after = maxf(worst_after, a)
					if a >= 0.5:
						t_ok = -2 # re-exceeded
		cu.check(peak > 10.0, "B %d km/h: full steer reached %.1f deg while held" % [int(kmh), peak])
		cu.check(t_ok >= 0 and float(t_ok) * DT <= 0.5, "B %d km/h: steer < 0.5 deg after %.3f s (limit 0.5 s) and stays" % [int(kmh), float(t_ok) * DT])
		cu.check_range("B %d km/h: max |steer| after settling, deg" % int(kmh), worst_after, 0.0, 0.5)
		cu.check(is_zero_approx(di.state.steer), "B %d km/h: filtered steer exactly 0 (no latched residue)" % int(kmh))
		v.get_parent().queue_free()
		di.queue_free()
		await physics_frame


## C: zero-steer probes along the Quarry road.
func _case_c() -> void:
	var drive: QuarryDrive = (load(QUARRY) as PackedScene).instantiate()
	drive.get_node("TimeTrial").ghost_path = "user://test_ghost_self_steer.dat"
	get_root().add_child(drive)
	await physics_frame
	var q := drive.quarry
	var v := drive.vehicle
	var pts := q.route_points(&"main", &"tarmac")
	var cum := PackedFloat32Array()
	cum.resize(pts.size())
	for i in range(1, pts.size()):
		cum[i] = cum[i - 1] + Vector2(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z).length()
	var csv := FileAccess.open("user://self_steer_quarry.csv", FileAccess.WRITE)
	csv.store_line("s,kmh,max_yaw_deg_s,max_steer_deg,mean_yaw_deg_s,surface,slope_deg")
	drive.set_physics_process(false) # this check drives the vehicle itself
	drive.driver_input.set_physics_process(false)
	var worst_steer := 0.0
	var listed := 0
	var rows := 0
	var s := 20.0
	while s < cum[cum.size() - 1] - 20.0:
		var idx := 0
		while idx < cum.size() - 2 and cum[idx] < s:
			idx += 1
		for kmh in [40.0, 80.0]:
			var a := pts[idx]
			var b := pts[mini(idx + 2, pts.size() - 1)]
			var fwd := b - a
			fwd.y = 0.0
			fwd = fwd.normalized()
			var hit := drive.get_world_3d().direct_space_state.intersect_ray(
					PhysicsRayQueryParameters3D.create(a + Vector3(0, 5, 0), a - Vector3(0, 10, 0)))
			if hit.is_empty():
				continue
			var up: Vector3 = hit.normal
			var f := fwd.slide(up).normalized()
			v.global_transform = Transform3D(Basis(f.cross(up), up, -f), hit.position + up * 0.1)
			v.reset_dynamics()
			v.linear_velocity = f * (kmh / 3.6)
			for w in v.wheels:
				w.omega = (kmh / 3.6) / w.radius
			var st := DriverInputState.new()
			var max_yaw := 0.0
			var sum_yaw := 0.0
			var max_steer := 0.0
			var n := 0
			for i in QUARRY_RUN_TICKS:
				v.apply_input(st)
				await physics_frame
				if i < 20:
					continue # settle on the springs
				var yaw_signed := rad_to_deg(v.angular_velocity.dot(up))
				max_yaw = maxf(max_yaw, absf(yaw_signed))
				sum_yaw += yaw_signed
				max_steer = maxf(max_steer, absf(_front_deg(v)))
				n += 1
			var surf := String(v.wheels[0].surface_id)
			var slope := rad_to_deg(acos(clampf(up.y, -1.0, 1.0)))
			csv.store_line("%.0f,%.0f,%.3f,%.4f,%.3f,%s,%.2f" % [s, kmh, max_yaw, max_steer, sum_yaw / n, surf, slope])
			rows += 1
			worst_steer = maxf(worst_steer, max_steer)
			if max_yaw > QUARRY_YAW_LIST_DEG:
				listed += 1
				print("LIST: Quarry s=%.0f %d km/h max yaw %.2f deg/s mean %.2f steer %.3f surface %s slope %.1f deg" % [
						s, int(kmh), max_yaw, sum_yaw / n, max_steer, surf, slope])
		s += QUARRY_STEP_S
	csv.close()
	print("INFO: Quarry probes %d, listed (yaw > %.1f deg/s) %d, csv %s" % [rows, QUARRY_YAW_LIST_DEG, listed, ProjectSettings.globalize_path("user://self_steer_quarry.csv")])
	cu.check(rows > 20, "C Quarry probes run (%d)" % rows)
	cu.check_range("C Quarry max |front steer| over all probes, deg", worst_steer, 0.0, 1e-6)
	drive.queue_free()
	await physics_frame


func _main() -> void:
	await physics_frame
	await _case_a()
	await _case_b()
	await _case_c()
	cu.finish(self)
