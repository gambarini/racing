## Headless check for the vehicle rigid body + raycast suspension (#8). GUT is not merged yet,
## so this is a standalone SceneTree script; port to GutTest once GUT lands.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/vehicle_suspension_check.gd
extends SceneTree

const VehicleScript := preload("res://vehicle/vehicle.gd")
const SuspensionMathScript := preload("res://vehicle/suspension_math.gd")
const DEFAULT_DEF := preload("res://vehicle/definitions/reference_car.tres")
const DT := 1.0 / 120.0
var failures := 0
var g := 9.81


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


func step(n: int) -> void:
	for i in n:
		await physics_frame


func make_world(tilt_deg := 0.0) -> Node3D:
	var root := Node3D.new()
	var ground := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 2, 200)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	ground.add_child(cs)
	ground.basis = Basis(Vector3.RIGHT, deg_to_rad(tilt_deg))
	root.add_child(ground)
	get_root().add_child(root)
	return root


func spawn(root: Node3D, xf: Transform3D, def: VehicleDefinition = null) -> Vehicle:
	var v: Vehicle = VehicleScript.new()
	if def != null:
		v.definition = def
	v.transform = xf
	root.add_child(v)
	return v


func fz_sum(v: Vehicle) -> float:
	var s := 0.0
	for w in v.wheels:
		s += w.fz
	return s


func roll_of(v: Vehicle) -> float:
	return v.global_transform.basis.y.x # ~ sin(roll) about the long axis


func _initialize() -> void:
	g = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.81))
	test_math()
	await test_settle_and_split()
	await test_drop_and_bump()
	await test_anti_roll()
	await test_slope()
	await test_perf()
	print("RESULT: ", "FAIL (%d)" % failures if failures > 0 else "OK")
	quit(1 if failures > 0 else 0)


func test_math() -> void:
	var M := SuspensionMathScript
	check(is_equal_approx(M.spring_force(0.1, 30000.0), 3000.0), "spring force = k*c")
	check(M.damper_force(1.0, 2000.0, 3000.0) == 2000.0, "bump damping on compression")
	check(M.damper_force(-1.0, 2000.0, 3000.0) == -3000.0, "rebound damping on extension")
	check(M.bump_stop_force(0.17, 0.2, 0.02, 4e5) == 0.0, "bump stop silent before zone")
	check(M.bump_stop_force(0.2, 0.2, 0.02, 4e5) > 5000.0, "bump stop rises sharply at full travel")
	check(M.arb_force(0.1, 0.05, 1e4) == -M.arb_force(0.05, 0.1, 1e4), "ARB forces antisymmetric")
	check(M.total_force(0.0, -5.0, 3e4, 2e3, 3e3, 0.2, 0.02, 4e5, 0.0) == 0.0, "strut cannot pull")
	var d: VehicleDefinition = DEFAULT_DEF
	check(d.mass == 1200.0 and d.wheelbase == 2.5 and d.track == 1.5 and d.wheel_radius == 0.32
			and d.travel == 0.20 and d.com_height == 0.45, "reference car definition values")
	check(d.com_from_front >= 0.5 and d.com_from_front <= 0.55, "CoM 50-55% from front")
	check(d.inertia.x > 0.0 and d.inertia.y > 0.0 and d.inertia.z > 0.0, "explicit inertia")


func test_settle_and_split() -> void:
	var root := make_world()
	var v := spawn(root, Transform3D(Basis.IDENTITY, Vector3(0, 0.3, 0)))
	await step(1)
	check(is_equal_approx(v.mass, 1200.0), "mass from definition")
	check(v.center_of_mass.is_equal_approx(DEFAULT_DEF.com_position()), "CoM from definition")
	check(v.inertia.is_equal_approx(DEFAULT_DEF.inertia), "inertia from definition (explicit)")
	check(v.wheels.size() == 4, "four wheels")
	await step(3 * 120)
	var y0 := v.global_position.y
	var y_min := y0
	var y_max := y0
	var vmax := 0.0
	var fz_err := 0.0
	for i in 5 * 120:
		await step(1)
		var y := v.global_position.y
		y_min = minf(y_min, y)
		y_max = maxf(y_max, y)
		vmax = maxf(vmax, v.linear_velocity.length())
		fz_err = maxf(fz_err, absf(fz_sum(v) - v.mass * g) / (v.mass * g))
	print("telemetry settle: y=%.4f range=%.6f vmax=%.5f fz_err=%.4f" % [y0, y_max - y_min, vmax, fz_err])
	check(y_max - y_min < 0.001, "settled body height variation < 1 mm")
	check(vmax < 0.01, "settled linear speed < 0.01 m/s")
	check(fz_err < 0.02, "sum Fz = m*g within 2%")
	check(absf(y0) < 0.005, "rest height: origin on ground (CoM %.3f m)" % (y0 + 0.45))
	var front := v.wheels[0].fz + v.wheels[1].fz
	var share := front / fz_sum(v)
	var expect := 1.0 - DEFAULT_DEF.com_from_front
	print("telemetry load split: front share=%.4f expected=%.4f" % [share, expect])
	check(absf(share - expect) < 0.02, "front-axle load share matches CoM")
	var w: Wheel = v.wheels[0]
	check(w.is_grounded and w.contact_normal.is_equal_approx(Vector3.UP) and w.compression > 0.0
			and w.fz > 0.0 and w.surface_id == &"default", "per-wheel contact info exposed")
	root.free()
	await step(1)


func test_drop_and_bump() -> void:
	var root := make_world()
	var v := spawn(root, Transform3D(Basis.IDENTITY, Vector3(0, 0.0, 0)))
	await step(4 * 120)
	var y_rest := v.global_position.y
	v.global_position = Vector3(0, y_rest + 0.1, 0)
	v.linear_velocity = Vector3.ZERO
	var crossings := 0
	var prev := 1.0
	var settle_t := -1.0
	var last_bad := 0.0
	for i in int(3.0 * 120):
		await step(1)
		var dy := v.global_position.y - y_rest
		if absf(dy) > 0.002:
			last_bad = (i + 1) * DT
			if prev * dy < 0.0:
				crossings += 1
			prev = dy
	settle_t = last_bad
	print("telemetry drop 0.1m: crossings=%d settle=%.3fs" % [crossings, settle_t])
	check(crossings <= 2, "rebound overshoot <= 1 oscillation cycle (%d crossings)" % crossings)
	check(settle_t < 1.5, "settles to +/-2 mm within 1.5 s (%.2f s)" % settle_t)
	# Hard drop: bump stop engages, hub never enters the chassis.
	v.global_position = Vector3(0, y_rest + 1.2, 0)
	v.linear_velocity = Vector3.ZERO
	var c_max := 0.0
	var f_max := 0.0
	var d_min := INF
	for i in 2 * 120:
		await step(1)
		for w in v.wheels:
			c_max = maxf(c_max, w.compression)
			f_max = maxf(f_max, w.fz)
			d_min = minf(d_min, w.hit_distance)
	print("telemetry hard drop: c_max=%.4f f_max=%.0f min_hit=%.4f" % [c_max, f_max, d_min])
	check(c_max <= DEFAULT_DEF.travel + 1e-6, "compression clamped to travel")
	check(f_max > 2.0 * v.mass * g / 4.0 * 2.0, "bump stop force rises sharply (%.0f N)" % f_max)
	check(d_min >= DEFAULT_DEF.wheel_radius - 0.01, "hub never penetrates chassis (min %.3f)" % d_min)
	root.free()
	await step(1)


func peak_roll(arb: bool) -> float:
	var root := make_world()
	var v := spawn(root, Transform3D(Basis.IDENTITY, Vector3(0, 0.0, 0)))
	v.arb_enabled = arb
	await step(3 * 120)
	var com_w := v.global_position + v.global_transform.basis * v.center_of_mass
	var fl := 0.5 * v.mass * g
	var roll := 0.0
	for i in 3 * 120:
		# D'Alembert: inertial force at CoM balanced by lateral ground reaction at the wheels.
		v.apply_force(Vector3(-fl, 0, 0), com_w - v.global_position)
		for w in v.wheels:
			v.apply_force(Vector3(fl * 0.25, 0, 0), w.contact_point - v.global_position)
		await step(1)
		com_w = v.global_position + v.global_transform.basis * v.center_of_mass
		roll = roll_of(v)
	root.free()
	await step(1)
	return roll


func test_anti_roll() -> void:
	var off := await peak_roll(false)
	var on := await peak_roll(true)
	print("telemetry roll at 0.5 g (sin): arb off=%.5f on=%.5f reduction=%.1f%%" % [off, on, (1.0 - on / off) * 100.0])
	# Ground reaction is +x (turn centre on +x), so the body must roll toward -x (outside): up.x < 0.
	check(off < 0.0 and on < 0.0, "roll sign: body rolls to the outside")
	check(absf(on) <= absf(off) * 0.85, "ARB reduces roll by >= 15%")


func test_slope() -> void:
	var tilt := deg_to_rad(10.0)
	var root := make_world(10.0)
	var b := Basis(Vector3.RIGHT, tilt) # ground tilted the same way: forward (-Z) rises
	var v := spawn(root, Transform3D(b, b.y * 0.01))
	v.static_hold = true
	var p0 := v.global_position
	var vmax := 0.0
	for i in 5 * 120:
		await step(1)
		if i > 120:
			vmax = maxf(vmax, absf(v.linear_velocity.dot(b.y)))
	var moved := v.global_position.distance_to(p0)
	print("telemetry slope hold: moved=%.4f m, max |v_normal|=%.4f" % [moved, vmax])
	check(moved < 0.05, "holds on 10 deg slope: moved < 5 cm (%.3f m)" % moved)
	check(vmax < 0.02, "no jitter on slope: |v_normal| < 0.02 m/s")
	root.free()
	await step(1)


func test_perf() -> void:
	var root := make_world()
	var v := spawn(root, Transform3D(Basis.IDENTITY, Vector3(0, 0, 0)))
	await step(2 * 120)
	var n := 2000
	var t0 := Time.get_ticks_usec()
	for i in n:
		v.step_suspension(DT)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0 / n
	print("telemetry perf: suspension tick avg %.4f ms (budget 0.05, fail > 0.2)" % ms)
	check(ms < 0.2, "suspension tick avg < 0.2 ms")
	root.free()
	await step(1)
