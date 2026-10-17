## Quarry surface VFX check (#128): VehicleVfx on the car-in-track scene, run headless.
##  1. the scene's VehicleVfx is a child of the Vehicle, exactly one per car, finds/creates exactly
##     one TyreMarks,
##  2. emitter proxy: at mid-zone of each of the 5 Quarry surfaces, steady 15 m/s for 2 s, then a
##     hard-brake lock-up from 20 m/s: rolling emitters exist and emit on >= 2 wheels (surfaces
##     with roll_rate 0, i.e. tarmac, emit on slip only: rolling ratio sum stays near 0),
##     and lock-up intensity is strictly higher than rolling,
##  3. one autopilot lap: live particles <= MAX_LIVE_PARTICLES_PER_CAR, mark segments <=
##     MAX_MARK_SEGMENTS, lap time equals the lap without VehicleVfx (VFX must not touch the sim).
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/quarry_vfx_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const IDS: Array[StringName] = [&"tarmac", &"dirt", &"gravel", &"mud", &"grass"]
const GRASS_S := 10.0
const GRASS_OFFSET := 8.0
const MAX_LAP_TICKS := 120 * 120

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _spawn(remove := false) -> QuarryDrive:
	var d: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	d.get_node("Vehicle/VehicleAudio").free() # audio is not under test and holds streams at exit
	if remove:
		d.get_node("Vehicle/VehicleVfx").free()
	root.add_child(d)
	return d


func _vfx(d: QuarryDrive) -> VehicleVfx:
	return d.get_node("Vehicle/VehicleVfx")


func _lat(q: Quarry, id: StringName, s: float) -> float:
	return q.road_half(s) + GRASS_OFFSET if id == &"grass" else 0.0


func _pos(q: Quarry, s: float, lat: float) -> Vector3:
	var smp: Dictionary = q.track.sample(s)
	var fwd: Vector3 = smp["forward"]
	return (smp["position"] as Vector3) + fwd.cross(Vector3.UP) * lat


func _weight(q: Quarry, s: float, lat: float, id: StringName) -> float:
	var p := _pos(q, s, lat)
	return q.terrain.surface_map.sample(p.x, p.z).get(id, 0.0)


## Middle of the longest purest stretch of `id` on the main line.
func _mid_zone(q: Quarry, id: StringName) -> float:
	if id == &"grass":
		return GRASS_S
	var n := int(q.track.length() / 2.0)
	var run_lo := 0
	var best_lo := 0
	var best_len := 0
	for i in n + 1:
		var pure := false
		if i < n:
			pure = true
			for dd in range(-5, 6, 5):
				if _weight(q, i * 2.0 + dd, 0.0, id) < 0.99:
					pure = false
					break
		if pure:
			continue
		if i - run_lo > best_len:
			best_len = i - run_lo
			best_lo = run_lo
		run_lo = i + 1
	return (best_lo + best_lo + best_len - 1) * 1.0


func _teleport(d: QuarryDrive, s: float, lat: float, speed: float) -> void:
	var fwd: Vector3 = d.quarry.track.sample(s)["forward"]
	var pos := _pos(d.quarry, s, lat)
	pos.y = d.quarry.terrain.height_at(pos.x, pos.z) + d.spawn_lift
	d.vehicle.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), pos)
	d.vehicle.linear_velocity = fwd * speed
	d.vehicle.angular_velocity = Vector3.ZERO
	for w in d.vehicle.wheels:
		w.omega = speed / w.radius


func _speed(d: QuarryDrive) -> float:
	return d.vehicle.linear_velocity.dot(-d.vehicle.global_transform.basis.z)


func _hold(d: QuarryDrive, speed: float, ticks: int) -> void:
	for i in ticks:
		var err := speed - _speed(d)
		var st := d.driver_input.state
		st.steer = 0.0
		st.handbrake = false
		st.throttle = clampf(err * 0.5, 0.0, 1.0)
		st.brake = clampf(-err * 0.5, 0.0, 1.0)
		await physics_frame


## {wheels: wheels with an emitting emitter for `id`, exist: wheels having one, ratio: summed
## amount_ratio of emitting emitters for `id`}.
func _sample(v: VehicleVfx, id: StringName) -> Dictionary:
	var emitting := 0
	var exist := 0
	var ratio := 0.0
	for ems in v.emitters:
		if ems.has(id):
			exist += 1
			var em: GPUParticles3D = ems[id]
			if em.emitting:
				emitting += 1
				ratio += em.amount_ratio
	return {"wheels": emitting, "exist": exist, "ratio": ratio}


func _main() -> void:
	await physics_frame

	# 1. wiring
	var d := _spawn()
	await physics_frame
	var vf := _vfx(d)
	cu.check(vf.get_parent() == d.vehicle, "VehicleVfx is a child of the Vehicle")
	cu.check(d.vehicle.find_children("*", "VehicleVfx", true, false).size() == 1, "exactly one VehicleVfx on the car")
	await _hold(d, 10.0, 120)
	cu.check(vf.vehicle == d.vehicle, "VehicleVfx is bound to the Vehicle")
	cu.check(get_nodes_in_group(&"tyre_marks").size() == 1, "exactly one TyreMarks in the scene")
	cu.check(vf.tyre_marks != null and vf.tyre_marks.get_parent() != null, "VehicleVfx found/created the TyreMarks")
	d.queue_free()
	await physics_frame

	# 2. per-surface emitter proxy
	var probe := _spawn(true)
	await physics_frame
	var mids := {}
	for id in IDS:
		mids[id] = _mid_zone(probe.quarry, id)
		var s: float = mids[id]
		cu.check(_weight(probe.quarry, s, _lat(probe.quarry, id, s), id) > 0.99, "control: %s mid-zone s=%.0f is pure" % [id, s])
	probe.queue_free()
	await physics_frame
	for id in IDS:
		var dr := _spawn()
		await physics_frame
		var v := _vfx(dr)
		var s: float = mids[id]
		var eff := SurfaceRegistry.get_surface(id).particle_effect
		_teleport(dr, s - 30.0, _lat(dr.quarry, id, s), 15.0)
		await _hold(dr, 15.0, 120)
		var roll_wheels := 99
		var roll_exist := 99
		var roll_ratio := 0.0
		for i in 120:
			await _hold(dr, 15.0, 1)
			var r := _sample(v, id)
			roll_wheels = mini(roll_wheels, r.wheels)
			roll_exist = mini(roll_exist, r.exist)
			roll_ratio += r.ratio / 120.0
		print("INFO: %s rolling 15 m/s: emitting on >= %d wheels (min), exist on >= %d, mean ratio sum %.3f, roll_rate %.2f" % [
				id, roll_wheels, roll_exist, roll_ratio, eff.roll_rate])
		if eff.roll_rate > 0.0:
			cu.check(roll_wheels >= 2, "%s: rolling emitters emitting on >= 2 wheels (%d)" % [id, roll_wheels])
		else:
			cu.check(roll_ratio < 0.25, "%s: roll_rate 0, smoke only on slip: rolling ratio sum %.3f < 0.25 (residual slip only)" % [id, roll_ratio])
		_teleport(dr, s - 25.0, _lat(dr.quarry, id, s), 20.0)
		await _hold(dr, 20.0, 12)
		var lock_ratio := 0.0
		var lock_wheels := 0
		var lock_int := 0.0
		for i in 90:
			var st := dr.driver_input.state
			st.steer = 0.0
			st.throttle = 0.0
			st.brake = 1.0
			await physics_frame
			var r := _sample(v, id)
			lock_ratio = maxf(lock_ratio, r.ratio)
			lock_wheels = maxi(lock_wheels, r.wheels)
			for w in dr.vehicle.wheels:
				lock_int = maxf(lock_int, SurfaceVfxMath.intensity(w.is_grounded, w.kappa, w.alpha, dr.vehicle.linear_velocity.length(), eff.roll_rate))
		print("INFO: %s lock-up: peak ratio sum %.3f on %d wheels, peak intensity %.3f" % [id, lock_ratio, lock_wheels, lock_int])
		cu.check(lock_ratio > roll_ratio, "%s: lock-up amount_ratio %.3f > rolling %.3f" % [id, lock_ratio, roll_ratio])
		dr.queue_free()
		await physics_frame

	# 3. budget and determinism over one autopilot lap
	var bare := await _lap(false)
	var withv := await _lap(true)
	cu.check(bare.laps >= 1 and withv.laps >= 1, "both laps complete (%d / %d)" % [bare.laps, withv.laps])
	print("INFO: lap without VFX %.3f s, with %.3f s; peak live particles %.1f, peak mark segments %d" % [
			bare.time, withv.time, withv.particles, withv.marks])
	cu.check_range("peak live particles per car", withv.particles, 0.0, SurfaceVfxMath.MAX_LIVE_PARTICLES_PER_CAR)
	cu.check_range("peak tyre mark segments", float(withv.marks), 0.0, SurfaceVfxMath.MAX_MARK_SEGMENTS)
	cu.check(withv.particles > 0.0, "the lap produced particles (%.1f)" % withv.particles)
	cu.check_range("lap time with VFX minus without (s)", withv.time - bare.time, -0.0001, 0.0001)
	cu.finish(self)


func _lap(vfx: bool) -> Dictionary:
	var d := _spawn(not vfx)
	await physics_frame
	var pts := d.quarry.route_points(&"main", &"tarmac")
	var drv := QuarryDriver.new()
	drv.setup(pts, d.quarry.route_mu(pts))
	d.autopilot = drv
	var v: VehicleVfx = _vfx(d) if vfx else null
	var particles := 0.0
	var marks := 0
	var ticks := 0
	while d.lap_timer.laps.size() < 1 and ticks < MAX_LAP_TICKS:
		await physics_frame
		ticks += 1
		if vfx:
			particles = maxf(particles, v.live_particle_estimate())
			if v.tyre_marks != null:
				marks = maxi(marks, v.tyre_marks.live_count())
	var t: float = d.lap_timer.laps[0].get("raw_time", -1.0) if d.lap_timer.laps.size() > 0 else -1.0
	var out := {"time": t, "laps": d.lap_timer.laps.size(), "particles": particles, "marks": marks}
	d.queue_free()
	await physics_frame
	return out
