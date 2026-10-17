extends GutTest
## Powertrain v1 (#11): engine curve, limiter, idle/clutch, gearbox, differentials. A lumped
## rigid-wheel car (no tire slip) closes the loop for the facade tests.

const DT := 1.0 / 120.0
const R := 0.32
const RPM := TAU / 60.0

var d: PowertrainDefinition


func before_each() -> void:
	d = PowertrainDefinition.new()


## Two driven wheels rolling without slip, car mass reflected, optional brake torque per wheel.
class Car:
	extends RefCounted
	var pt: Powertrain
	var omega := 0.0 ## rad/s, both wheels
	var speed := 0.0
	var brake := 0.0 ## Nm per wheel
	var mass := 1200.0
	var load_force := 0.0 ## N resisting motion

	func _init(p: Powertrain) -> void:
		pt = p

	func tick(throttle: float, dt: float) -> void:
		pt.step(dt, throttle, omega, omega)
		var t := pt.torque_left + pt.torque_right
		var i_eff := 2.0 * (1.2 + pt.reflected_inertia) + mass * 0.32 * 0.32
		var t_res := load_force * 0.32 + 2.0 * brake * signf(omega)
		var w_new := omega + (t - t_res) / i_eff * dt
		if brake > 0.0 and (omega > 0.0) != (w_new > 0.0):
			w_new = 0.0
		omega = w_new
		speed = omega * 0.32


func test_curve_reference_points() -> void:
	assert_almost_eq(EngineModel.curve_torque(d.torque_curve, 4500.0), 260.0, 0.5)
	assert_almost_eq(EngineModel.curve_torque(d.torque_curve, 1000.0), 120.0, 0.5)
	assert_almost_eq(EngineModel.curve_torque(d.torque_curve, 5250.0), 247.5, 0.5, "linear")
	assert_almost_eq(EngineModel.curve_torque(d.torque_curve, 500.0), 120.0, 0.5, "clamped low")
	assert_almost_eq(EngineModel.curve_torque(d.torque_curve, 9000.0), 190.0, 0.5, "clamped high")


func test_closed_throttle_and_blend() -> void:
	assert_almost_eq(EngineModel.torque_at(d, 4000.0, 0.0), -44.0, 0.5)
	var full := EngineModel.torque_at(d, 4000.0, 1.0)
	assert_almost_eq(EngineModel.torque_at(d, 4000.0, 0.5), (full - 44.0) * 0.5, 0.5)


func test_rev_limiter_cuts_torque_not_rpm() -> void:
	var e := EngineModel.new(d)
	var lo := 1e9
	var hi := 0.0
	var peak_rpm_seen := 0.0
	var cut_seen := false
	for i in 240:
		e.compute_torque(1.0)
		cut_seen = cut_seen or e.limiter_cut
		e.integrate(0.0, DT)
		peak_rpm_seen = maxf(peak_rpm_seen, e.rpm())
		if e.rpm() > 7000.0 or i > 200:
			lo = minf(lo, e.rpm())
		hi = maxf(hi, e.rpm())
	assert_true(cut_seen, "limiter engaged")
	assert_lt(hi, 7300.0, "never above 7300")
	assert_gt(lo, 7000.0, "stays in the 7000..7300 band once there")
	assert_gt(e.rpm(), 7000.0)


func test_idle_holds_without_stall() -> void:
	var pt := Powertrain.new(d)
	var car := Car.new(pt)
	car.brake = 1600.0
	var lo := 1e9
	var hi := 0.0
	for i in 600:
		car.tick(0.0, DT)
		lo = minf(lo, pt.rpm())
		hi = maxf(hi, pt.rpm())
	assert_gt(lo, 850.0, "no stall")
	assert_almost_eq(pt.rpm(), 1000.0, 150.0)
	assert_lt(hi, 1150.0)
	assert_almost_eq(car.speed, 0.0, 1e-6)


func test_launch_rpm_window_and_lock() -> void:
	var pt := Powertrain.new(d)
	var car := Car.new(pt)
	car.load_force = 400.0
	var rpm_1s := 0.0
	var max_rpm_1s := 0.0
	var stalled := false
	var lock_slip := -1.0
	for i in 120 * 6:
		car.tick(1.0, DT)
		if i < 120:
			max_rpm_1s = maxf(max_rpm_1s, pt.rpm())
		if pt.rpm() < 800.0:
			stalled = true
		if pt.locked and lock_slip < 0.0:
			lock_slip = absf(pt.clutch_slip_rpm())
	rpm_1s = max_rpm_1s
	assert_false(stalled)
	assert_gt(rpm_1s, 3000.0, "rpm reaches 3000+ within 1 s")
	assert_lt(rpm_1s, 5500.0)
	assert_gt(lock_slip, -0.5, "clutch locks")
	assert_lt(lock_slip, 20.0, "locked slip < 20 rpm")


func test_gearbox_thresholds() -> void:
	var g := Gearbox.new(d)
	assert_almost_eq(g.upshift_rpm(0.0), 3500.0, 1e-6)
	assert_almost_eq(g.upshift_rpm(1.0), 6500.0, 1e-6)
	assert_almost_eq(g.upshift_rpm(0.5), 5000.0, 1e-6)
	assert_almost_eq(g.downshift_rpm(0.0), 1800.0, 1e-6)
	assert_almost_eq(g.downshift_rpm(1.0), 3000.0, 1e-6)


func test_gearbox_min_interval_and_cut() -> void:
	var g := Gearbox.new(d)
	assert_eq(g.update(DT, 6600.0, 6600.0, 1.0), 1, "upshift")
	assert_eq(g.gear, 2)
	assert_true(g.torque_cut())
	var t := 0.0
	var early := 0
	while t < 0.49:
		early += absi(g.update(DT, 9000.0, 9000.0, 1.0))
		t += DT
	assert_eq(early, 0, "no shift inside 0.5 s")
	var cut_ticks := 0
	var g2 := Gearbox.new(d)
	g2.update(DT, 6600.0, 6600.0, 1.0)
	for i in 60:
		if g2.torque_cut():
			cut_ticks += 1
		g2.update(DT, 0.0, 3000.0, 1.0)
	assert_almost_eq(cut_ticks * DT, 0.25, 2.0 * DT, "cut lasts the shift time")


func test_full_throttle_run_upshifts_in_order() -> void:
	var pt := Powertrain.new(d)
	var car := Car.new(pt)
	car.load_force = 300.0
	var seq: Array[int] = [1]
	for i in 120 * 8:
		car.tick(1.0, DT)
		if pt.gear() != seq[-1]:
			seq.append(pt.gear())
	assert_gt(seq.size(), 2, "shifted at least twice: %s" % [seq])
	assert_eq(seq[0], 1)
	assert_eq(seq[1], 2)
	assert_eq(seq[2], 3)
	for i in range(1, seq.size()):
		assert_eq(seq[i], seq[i - 1] + 1, "monotonic upshifts %s" % [seq])


func test_steady_60kmh_30pct_no_shifts() -> void:
	var g := Gearbox.new(d)
	g.gear = 4
	var w := 60.0 / 3.6 / R
	var shifts := 0
	for i in 600:
		var rpm_ := g.total_ratio() * w / RPM
		shifts += absi(g.update(DT, rpm_, rpm_, 0.3))
	assert_eq(shifts, 0)


func test_diff_torque_conservation() -> void:
	for type in [0, 1, 2]:
		d.diff_type = type
		for t_in in [-300.0, -10.0, 0.0, 50.0, 400.0, 2000.0]:
			for pair in [Vector2(10, 10), Vector2(100, 50), Vector2(50, 100), Vector2(0, 80)]:
				var s := Differential.split(d, t_in, pair.x, pair.y)
				assert_lt(absf(t_in - s.x - s.y), 1e-6, "type %d t_in %.0f" % [type, t_in])


func test_open_diff_equal_split() -> void:
	d.diff_type = PowertrainDefinition.DiffType.OPEN
	var s := Differential.split(d, 600.0, 120.0, 20.0)
	assert_lt(absf(s.x - s.y), 1.0)


func test_locked_diff_converges() -> void:
	d.diff_type = PowertrainDefinition.DiffType.LOCKED
	var wl := 100.0
	var wr := 50.0
	var t := 0.0
	while t < 0.5:
		var s := Differential.split(d, 200.0, wl, wr)
		wl += s.x / 1.2 * DT
		wr += s.y / 1.2 * DT
		t += DT
	assert_lt(absf(wl - wr) / maxf(wl, wr), 0.01, "speed difference < 1 %% (%.3f)" % absf(wl - wr))


func test_lsd_biases_to_slower_wheel() -> void:
	d.diff_type = PowertrainDefinition.DiffType.LSD
	for t_in in [100.0, 200.0, 600.0]:
		var s := Differential.split(d, t_in, 100.0, 50.0) # right wheel is slower
		assert_gte(s.y - s.x, 100.0 - 1e-6, "slower gets >= 100 Nm more (t_in %.0f)" % t_in)
		assert_lte(s.y, t_in + 1e-6, "at most T_in")
		assert_gte(s.x, -1e-6)
	var mirrored := Differential.split(d, 200.0, 50.0, 100.0)
	assert_gt(mirrored.x, mirrored.y)


func test_deterministic() -> void:
	var a := Powertrain.new(d)
	var b := Powertrain.new(d)
	var ca := Car.new(a)
	var cb := Car.new(b)
	for i in 600:
		ca.tick(1.0, DT)
		cb.tick(1.0, DT)
	assert_eq(a.rpm(), b.rpm())
	assert_eq(ca.speed, cb.speed)


## Direction selection (#108).
func test_gearbox_select_reverse_neutral_forward() -> void:
	var gb := Gearbox.new(d)
	for i in 30: # 0.25 s braking at rest: not yet
		gb.select(DT, 0.0, 1.0, 0.0)
	assert_eq(gb.gear, 1)
	for i in 10:
		gb.select(DT, 0.0, 1.0, 0.0)
	assert_eq(gb.gear, -1, "0.3 s brake held at rest selects reverse")
	for i in 240:
		gb.select(DT, 0.0, 1.0, 0.0)
	assert_eq(gb.gear, -1, "holding the brake does not toggle back")
	gb.select(DT, 0.0, 0.0, 0.0)
	for i in 40:
		gb.select(DT, 0.0, 1.0, 0.0)
	assert_eq(gb.gear, 1, "a fresh 0.3 s brake hold in reverse selects forward")
	for i in 61:
		gb.select(DT, 0.0, 0.0, 0.0)
	assert_eq(gb.gear, 0, "0.5 s with no pedals at rest: neutral")
	gb.select(DT, 0.5, 0.0, 0.0)
	assert_eq(gb.gear, 1, "throttle re-selects 1st at once")


func test_gearbox_never_reverses_while_moving() -> void:
	var gb := Gearbox.new(d)
	for i in 600:
		gb.select(DT, 0.0, 1.0, 10.0)
	assert_eq(gb.gear, 1)
	for i in 600:
		gb.select(DT, 0.0, 0.0, 0.6)
	assert_eq(gb.gear, 1, "no neutral while moving either")


func test_step_on_awd_falls_back_safely() -> void:
	d.layout = PowertrainDefinition.Layout.AWD
	var pt := Powertrain.new(d)
	pt.silence_misuse_error = true
	for i in 120:
		pt.step(DT, 1.0, 20.0, 20.0)
	assert_true(is_finite(pt.torque_left) and is_finite(pt.torque_right), "rear finite")
	assert_true(is_finite(pt.torque_front_left) and is_finite(pt.torque_front_right), "front finite")
	assert_ne(pt.torque_front_left, 0.0, "front axle driven by the AWD split")
	assert_ne(pt.torque_left, 0.0, "rear axle driven")
