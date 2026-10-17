## Headless check (#19): per-wheel SurfaceMap blending in the real Vehicle + telemetry columns,
## and continuity of mu_peak across a 0.5 m transition at 30 m/s. Run:
## godot --headless --fixed-fps 120 --path project -s res://tests/surface_blend_check.gd
extends SceneTree

const IDS: Array[StringName] = [&"tarmac", &"gravel"]
const DT := 1.0 / 120.0
var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


func frames(n: int) -> void:
	for i in n:
		await physics_frame


## Tagged-tarmac flat ground (so outside-map fallback is tarmac) and a vehicle on it.
func scene(map: SurfaceMap, pos: Vector3) -> Vehicle:
	var root := Node3D.new()
	get_root().add_child(root)
	var ground := StaticBody3D.new()
	ground.set_meta(&"surface_id", &"tarmac")
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 2, 4000)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	ground.add_child(cs)
	root.add_child(ground)
	var v: Vehicle = load("res://vehicle/vehicle.gd").new()
	v.transform = Transform3D(Basis.IDENTITY, pos)
	v.surface_map = map
	root.add_child(v)
	return v


## Map over x in [-20, 20], z in [-40, 20], 0.5 m texels. `gravel` is a Callable(x_centre, z_centre).
func make_map(gravel: Callable) -> SurfaceMap:
	var cols := 80
	var rows := 120
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for r in rows:
		for c in cols:
			var g: bool = gravel.call(-20.0 + (c + 0.5) * 0.5, -40.0 + (r + 0.5) * 0.5)
			img.set_pixel(c, r, Color(0, 1, 0, 0) if g else Color(1, 0, 0, 0))
	var m := SurfaceMap.new()
	m.origin = Vector2(-20, -40)
	m.size = Vector2(40, 60)
	m.ids = IDS.duplicate()
	m.images = [img]
	return m


func _initialize() -> void:
	# --- Independent wheels: left (x < 0) gravel, right tarmac -----------------------------------
	var v := scene(make_map(func(x, _z): return x < 0.0), Vector3(0, 0.05, 0))
	await frames(240)
	var rec := TelemetryRecorder.new()
	rec.vehicle = v
	rec.record(DT)
	var reg := SurfaceRegistry.ids()
	var gi := reg.find(&"gravel")
	var ti := reg.find(&"tarmac")
	var ok := true
	for i in 4:
		var left := i % 2 == 0
		var wg: float = rec.row[TelemetrySchema.weight_col(i, gi)]
		var wt: float = rec.row[TelemetrySchema.weight_col(i, ti)]
		print("wheel ", i, " weights gravel=", wg, " tarmac=", wt, " dominant=",
				rec.surface_name(rec.row[TelemetrySchema.wheel_col(i, TelemetrySchema.SURFACE_CH)]))
		ok = ok and ((wg > 0.99 and wt < 0.01) if left else (wt > 0.99 and wg < 0.01))
	check(ok, "left wheels gravel, right wheels tarmac in per-wheel weight telemetry")
	check(rec.surface_name(rec.row[TelemetrySchema.wheel_col(0, TelemetrySchema.SURFACE_CH)]) == "gravel"
			and rec.surface_name(rec.row[TelemetrySchema.wheel_col(1, TelemetrySchema.SURFACE_CH)]) == "tarmac",
			"dominant surface id per wheel")
	check(absf(v.wheels[0].fz - v.wheels[1].fz) < 1500.0, "car still sits on the ground (sanity)")
	rec.free()
	v.get_parent().queue_free()
	await frames(2)

	# --- Outside map bounds falls back to the collider id -----------------------------------------
	var far := scene(make_map(func(_x, _z): return true), Vector3(100, 0.05, 0))
	await frames(240)
	check(far.wheels[0].surface_weights == {&"tarmac": 1.0}, "outside map bounds -> collider surface (tarmac)")
	far.get_parent().queue_free()
	await frames(2)

	# --- Continuity at 30 m/s across a 0.5 m transition (tarmac z > -15, gravel z < -15) ----------
	var d := scene(make_map(func(_x, z): return z < -15.0), Vector3(0, 0.05, -2))
	await frames(120)
	var prev := -1.0
	var max_step := 0.0
	var monotone := true
	var n_mid := 0
	var min_mu := 10.0
	var max_mu := -10.0
	var w := d.wheels[0]
	for i in 90:
		d.linear_velocity = -d.global_transform.basis.z * 30.0
		await physics_frame
		var mu := SurfaceBlend.blend(w.surface_weights).peak_mu_scale
		if prev >= 0.0:
			max_step = maxf(max_step, absf(mu - prev))
			if mu > prev + 1e-6:
				monotone = false
		if mu > 0.651 and mu < 0.999:
			n_mid += 1
		prev = mu
		min_mu = minf(min_mu, mu)
		max_mu = maxf(max_mu, mu)
	# Ruling: step <= |delta| * (v dt / width) * 1.05 = 0.35 * 0.25 / 0.5 * 1.05 = 0.184 per tick.
	var bound := 0.35 * 30.0 * DT / 0.5 * 1.05 # design ruling #19 (PR #115)
	print("continuity: max per-tick peak_mu_scale step = ", max_step, " (ramp-implied bound ", bound, "), final=", prev)
	check(absf(prev - 0.65) < 1e-3, "wheel ends on gravel after the transition")
	check(monotone, "mu_peak scale monotone across the transition")
	check(min_mu >= 0.65 - 1e-6 and max_mu <= 1.0 + 1e-6, "no overshoot outside the two surfaces' values")
	check(max_step <= bound, "per-tick step bounded by the linear ramp (no pops)")
	d.get_parent().queue_free()
	await frames(2)

	print("surface_blend_check failures: ", failures)
	quit(1 if failures > 0 else 0)
