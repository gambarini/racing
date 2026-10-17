## Reverse / neutral selection and full-vehicle steady-state checks (#108), real Vehicle on the flat lane.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/reverse_neutral_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _fwd(v: Vehicle) -> float:
	return -v.linear_velocity.dot(v.global_transform.basis.z)


func _main() -> void:
	await physics_frame
	await _reverse()
	await _no_reverse_while_moving()
	await _neutral()
	await _steady_state()
	await _idle_brake()
	cu.finish(self)


func _reverse() -> void:
	# Settle 1 s, brake 1.0 from t=1 for 0.5 s, then throttle 1.0 with the brake released at t=1.5.
	var sc := Scenario.new(self, "Spawn_Flat", [{"t": 1.0, "brake": 1.0}, {"t": 1.5, "throttle": 1.0}], 120 * 6)
	sc.csv_path = "user://reverse.csv"
	var r: Dictionary = await sc.run()
	cu.check(r.gear[int(1.2 * 120)] != -1, "brake held 0.2 s: not yet reverse")
	cu.check(r.gear[int(1.45 * 120)] == -1, "brake held 0.3 s: gear = reverse")
	var t3 := int(4.5 * 120) - 1
	var dz := (r.pos[t3] as Vector3).z - (r.pos[int(1.5 * 120)] as Vector3).z
	cu.check(dz > 0.0, "car moves backwards (+z, heading is -z): dz %.2f" % dz)
	cu.check_range("reverse speed 3 s after throttle (m/s)", absf(float(r.speed[t3])), 3.0, 40.0, r.csv)
	cu.check(r.gear[t3] == -1, "stays in reverse under throttle")


func _no_reverse_while_moving() -> void:
	var sc := Scenario.new(self, "Spawn_Flat", [{"t": 0.0, "brake": 1.0}], 120 * 5)
	sc.initial_speed = 10.0
	sc.csv_path = "user://reverse_moving.csv"
	var fwd_speeds: Array[float] = []
	sc.controller = func(_i: int, v: Vehicle, _st: DriverInputState) -> void:
		fwd_speeds.append(_fwd(v))
	var r: Dictionary = await sc.run()
	var bad := false
	var first_rev := -1
	for i in r.ticks:
		if r.gear[i] == -1:
			first_rev = i
			# fwd_speeds[i] is the speed before tick i's step.
			bad = fwd_speeds[maxi(i - 1, 0)] >= 0.5
			break
	cu.check(first_rev >= 0, "braking to rest then selects reverse (tick %d)" % first_rev)
	cu.check(not bad, "reverse never selected while moving forward > 0.5 m/s")


func _neutral() -> void:
	var sc := Scenario.new(self, "Spawn_Flat", [{"t": 2.0, "throttle": 0.5}], 120 * 3)
	var r: Dictionary = await sc.run()
	cu.check(r.gear[int(1.9 * 120)] == 0, "stopped, no pedals 0.5 s: neutral")
	cu.check(r.gear[int(0.4 * 120)] != 0, "not neutral before 0.5 s")
	cu.check(r.gear[int(2.0 * 120) + 12] == 1, "throttle re-selects 1st within 0.1 s")
	cu.check(r.speed[int(1.9 * 120)] < 0.05, "stays put in neutral")


func _steady_state() -> void:
	var target := 60.0 / 3.6
	var settle := 4.0
	var window := 5.0
	var integ := [0.12]
	var sc := Scenario.new(self, "Spawn_Flat", [], int((settle + window) / Scenario.DT))
	sc.initial_speed = target
	sc.csv_path = "user://steady_state.csv"
	var thr_sum := [0.0, 0]
	var shifts0 := [0, 0]
	var rpm_ok := [true]
	var rpm_mm := [1e9, 0.0]
	var gears := {}
	var vmm := [1e9, 0.0]
	sc.controller = func(i: int, v: Vehicle, st: DriverInputState) -> void:
		var e := target - _fwd(v)
		integ[0] = clampf(integ[0] + 0.04 * e * Scenario.DT, 0.0, 1.0)
		st.throttle = clampf(integ[0] + 0.05 * e, 0.0, 1.0)
		var t := float(i) * Scenario.DT
		shifts0[1] = v.powertrain.shifts
		if t < settle:
			shifts0[0] = v.powertrain.shifts
			return
		var th: float = st.throttle
		thr_sum[0] += th
		thr_sum[1] += 1
		var rpm := v.rpm()
		rpm_mm[0] = minf(rpm_mm[0], rpm)
		rpm_mm[1] = maxf(rpm_mm[1], rpm)
		if rpm <= lerpf(1800.0, 3000.0, th) or rpm >= lerpf(3500.0, 6500.0, th):
			rpm_ok[0] = false
		gears[v.gear()] = true
		vmm[0] = minf(vmm[0], _fwd(v))
		vmm[1] = maxf(vmm[1], _fwd(v))
	var r: Dictionary = await sc.run()
	var thr_mean: float = thr_sum[0] / maxf(thr_sum[1], 1)
	print("BASELINE 60 km/h: throttle %.3f  gear %s  rpm %.0f..%.0f  speed %.2f..%.2f m/s" % [
			thr_mean, gears.keys(), rpm_mm[0], rpm_mm[1], vmm[0], vmm[1]])
	cu.check_range("mean throttle to hold 60 km/h", thr_mean, 0.1, 0.4, r.csv)
	cu.check(shifts0[1] == shifts0[0], "zero shifts in the 5 s window (%d)" % (shifts0[1] - shifts0[0]))
	cu.check(rpm_ok[0], "rpm inside the auto-shift band (%.0f..%.0f)" % [rpm_mm[0], rpm_mm[1]])
	cu.check_range("speed held, min (m/s)", vmm[0], target - 1.0, target + 1.0, r.csv)
	cu.check_range("speed held, max (m/s)", vmm[1], target - 1.0, target + 1.0, r.csv)


func _idle_brake() -> void:
	var sc := Scenario.new(self, "Spawn_Flat", [{"t": 0.0, "brake": 1.0}], 120 * 5)
	sc.csv_path = "user://idle_brake.csv"
	var info := [0, 1e9]
	sc.controller = func(_i: int, v: Vehicle, _st: DriverInputState) -> void:
		info[0] = v.powertrain.shifts
		info[1] = minf(info[1], v.rpm())
	var r: Dictionary = await sc.run()
	var vmax := 0.0
	for i in range(120 * 2, r.ticks): # 3 s of braking after a 2 s drop-and-settle
		vmax = maxf(vmax, r.speed[i])
	cu.check_range("max speed with brake 1.0, throttle 0 (m/s)", vmax, 0.0, 0.05, r.csv)
	cu.check(info[0] == 0, "no shift (%d)" % info[0])
	cu.check(info[1] > 500.0, "no stall (min rpm %.0f)" % info[1])
