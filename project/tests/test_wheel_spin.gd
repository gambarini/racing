extends GutTest
## Wheel spin integration (#10). Quarter-car stub ground (TireModel + a point mass) for the pure
## tests; one integration test drives the real #8 Vehicle with the #9 tire model.

const R := 0.32
const I := 1.2
const DT := 1.0 / 120.0
const FZ := 3000.0
const QUARTER_MASS := 300.0


class Sim:
	extends RefCounted
	var omega := 0.0
	var vx := 0.0
	var kappa := 0.0
	var fx := 0.0
	var grounded := true
	var p := TireParams.new()
	var mass := 300.0
	var flips := 0

	func tick(t_drive: float, t_brake: float, dt: float) -> void:
		var prev := omega
		if grounded:
			var target := TireModel.slip_ratio(omega, 0.32, vx, p)
			kappa = TireModel.relax(kappa, target, vx, dt, p)
			var fx0 := TireModel.compute(kappa, 0.0, 3000.0, p).x
			var sl := WheelSpin.fx_slopes(kappa, omega, vx, 3000.0, 0.32, vx, dt, p)
			fx = WheelSpin.implicit_fx(fx0, sl.x, sl.y, t_drive, 0.32, 1.2, mass, dt)
			fx = TireModel.limit_to_stop(fx, vx, mass, dt)
			vx += fx / mass * dt
			omega = WheelSpin.step(omega, t_drive, t_brake, fx, 0.32, 1.2, dt)
		else:
			kappa = 0.0
			fx = 0.0
			omega = WheelSpin.step(omega, t_drive, t_brake, 0.0, 0.32, 1.2, dt)
		if prev != 0.0 and omega != 0.0 and signf(prev) != signf(omega):
			flips += 1


func test_step_pure_formula() -> void:
	assert_almost_eq(WheelSpin.step(0.0, 120.0, 0.0, 0.0, R, I, DT), 120.0 / I * DT, 1e-6)
	assert_almost_eq(WheelSpin.step(10.0, 0.0, 0.0, 100.0, R, I, 0.1), 10.0 - 100.0 * R / I * 0.1, 1e-6)


func test_free_spin_in_air() -> void:
	var s := Sim.new()
	s.grounded = false
	for i in 120:
		s.tick(100.0, 0.0, DT)
	assert_almost_eq(s.omega, 100.0 / I, 83.3 * 0.01, "omega = T*t/I")


func test_brake_does_not_reverse() -> void:
	var s := Sim.new()
	s.grounded = false
	s.omega = 50.0
	for i in 120:
		s.tick(0.0, 2000.0, DT)
	assert_eq(s.omega, 0.0, "stays at zero")
	assert_lte(s.flips, 1)
	var neg := Sim.new()
	neg.grounded = false
	neg.omega = -5.0
	for i in 120:
		neg.tick(0.0, 50.0, DT)
	assert_eq(neg.omega, 0.0)


func test_lockup_at_speed() -> void:
	var s := Sim.new()
	s.vx = 20.0
	s.omega = 20.0 / R
	var t_lock := -1.0
	for i in 60:
		s.tick(0.0, 2000.0, DT)
		if s.omega == 0.0 and t_lock < 0.0:
			t_lock = (i + 1) * DT
	assert_gt(t_lock, 0.0, "locked")
	assert_lt(t_lock, 0.5, "lock-up in < 0.5 s")
	assert_lte(s.flips, 1)


func test_rolling_kappa_stays_small() -> void:
	var s := Sim.new()
	s.vx = 20.0
	s.omega = 20.0 / R * 1.01 # start 1 % off; wheel speed must track ground speed
	for i in 360:
		s.tick(0.0, 0.0, DT)
		assert_lt(absf(s.kappa), 0.02, "tick %d" % i)
	assert_almost_eq(s.omega * R, s.vx, 0.05 * s.vx)


func test_wheelspin_low_mu() -> void:
	var s := Sim.new()
	s.p.mu_peak = 0.5
	s.p.mu_slide = 0.45
	var peak := 0.0
	for i in 60:
		s.tick(1500.0, 0.0, DT)
		peak = maxf(peak, absf(s.kappa))
	assert_gt(peak, 0.2, "low mu spins up")


func test_no_runaway_on_grip() -> void:
	var s := Sim.new()
	var peak := 0.0
	for i in 240:
		s.tick(750.0, 0.0, DT)
		peak = maxf(peak, absf(s.kappa))
	assert_lt(peak, 0.15, "half torque on mu 1.1 hooks up")


func test_reaction_torque_slows_wheel() -> void:
	var s := Sim.new()
	s.grounded = false
	s.vx = 10.0
	s.omega = 10.0 * 1.3 / R # kappa = +0.3
	for i in 20:
		s.tick(0.0, 0.0, DT)
	assert_almost_eq(s.omega * R, 13.0, 1e-3, "free wheel keeps speed")
	var w0 := s.omega
	s.grounded = true
	s.tick(0.0, 0.0, DT)
	assert_lt(s.omega, w0, "ground contact loses angular speed")
	assert_gt(s.fx, 0.0, "and pushes the car forward")


func test_handbrake_rear_only() -> void:
	var rear := Sim.new()
	var front := Sim.new()
	for s in [rear, front]:
		s.vx = 15.0
		s.omega = 15.0 / R
	var rolling := 15.0 / R
	for i in 48: # 0.4 s
		rear.tick(0.0, 3000.0, DT)
		front.tick(0.0, 0.0, DT)
	assert_lt(rear.omega, 0.1 * rolling, "rear drops under 10 %")
	assert_lt(absf(front.kappa), 0.05)
	for i in 120: # release
		rear.tick(0.0, 0.0, DT)
	assert_lt(absf(rear.kappa), 0.05, "recovers rolling within 1 s")


func _scripted(t: float) -> Vector2:
	return Vector2(1200.0 * sin(2.0 * t) + 400.0, 800.0 * maxf(0.0, sin(1.3 * t)))


func test_random_input_stable() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 10
	var s := Sim.new()
	s.vx = 10.0
	s.omega = 10.0 / R
	var td := 0.0
	var tb := 0.0
	for i in 1200:
		if i % 60 == 0: # random torques held 0.5 s, with occasional airborne gaps
			s.grounded = rng.randf() > 0.1
			td = rng.randf_range(-1500.0, 1500.0)
			tb = rng.randf_range(0.0, 2000.0)
		s.tick(td, tb, DT)
		assert_true(is_finite(s.omega) and is_finite(s.vx))
		assert_lt(absf(s.omega), 500.0)


func test_substep_consistency() -> void:
	var a := Sim.new()
	var b := Sim.new()
	for s in [a, b]:
		s.vx = 10.0
		s.omega = 10.0 / R
	for i in 1200:
		var u := _scripted(i * DT)
		a.tick(u.x, u.y, DT)
	for i in 2400:
		var u := _scripted(i * DT * 0.5)
		b.tick(u.x, u.y, DT * 0.5)
	assert_almost_eq(a.omega, b.omega, 0.05 * maxf(absf(b.omega), 1.0), "omega")
	assert_almost_eq(a.vx, b.vx, 0.05 * maxf(absf(b.vx), 1.0), "vx")

