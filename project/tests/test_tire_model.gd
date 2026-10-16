extends GutTest
## Tire model (#9) pure-function tests, ported from tire_model_check.gd (#70).

const FZ := 3000.0
var P := TireParams.new()


func fx(k: float) -> float:
	return TireModel.compute(k, 0.0, FZ, P).x


func fy(a: float) -> float:
	return TireModel.compute(0.0, a, FZ, P).y


func test_longitudinal() -> void:
	var best_k := 0.0
	var best_f := 0.0
	for i in range(1, 10001):
		var k := i / 10000.0
		if absf(fx(k)) > best_f:
			best_f = absf(fx(k))
			best_k = k
	assert_true(absf(best_k - 0.10) <= 0.01, "Fx peak at kappa %.4f" % best_k)
	assert_true(absf(best_f - P.mu_peak * FZ) <= 0.02 * P.mu_peak * FZ, "Fx peak value %.1f" % best_f)
	var mono := true
	var prev := INF
	for i in range(1000, 10001):
		var f := fx(i / 10000.0)
		if f > prev + 1e-9:
			mono = false
		prev = f
	assert_true(mono, "Fx falls monotonically after kappa 0.1")
	var f1 := fx(1.0)
	assert_true(absf(f1 - P.mu_slide * FZ) <= 0.05 * P.mu_slide * FZ, "Fx(1.0)=%.1f ~ mu_slide*Fz" % f1)
	var zero_fy := true
	for i in 101:
		if TireModel.compute(i / 100.0, 0.0, FZ, P).y != 0.0:
			zero_fy = false
	assert_true(zero_fy, "Fy == 0 at alpha 0")


func test_lateral() -> void:
	var best_a := 0.0
	var best_f := 0.0
	for i in range(1, 15001):
		var a := i / 10000.0
		if absf(fy(a)) > best_f:
			best_f = absf(fy(a))
			best_a = a
	assert_true(absf(best_a - deg_to_rad(8.0)) <= deg_to_rad(0.5), "Fy peak at %.2f deg" % rad_to_deg(best_a))
	assert_true(absf(best_f - P.mu_peak * FZ) <= 0.02 * P.mu_peak * FZ, "Fy peak value %.1f" % best_f)
	var mono := true
	var prev := INF
	for i in range(1400, 15001):
		var f := absf(fy(i / 10000.0))
		if f > prev + 1e-9:
			mono = false
		prev = f
	assert_true(mono, "Fy falls monotonically after the peak")
	var fe := absf(fy(1.4))
	assert_true(absf(fe - P.mu_slide * FZ) <= 0.05 * P.mu_slide * FZ, "Fy at 80 deg ~ mu_slide*Fz (%.1f)" % fe)
	var signs := true
	for a in [0.01, 0.1, 0.14, 0.5, 1.2]:
		var f := TireModel.compute(0.0, a, FZ, P)
		if not (f.y < 0.0 and f.x == 0.0):
			signs = false
		if not (TireModel.compute(0.0, -a, FZ, P).y > 0.0):
			signs = false
	assert_true(signs, "Fy opposes alpha, Fx == 0")


func test_antisymmetry_zero() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var worst := 0.0
	for i in 1000:
		var k := rng.randf_range(-1.5, 1.5)
		var a := rng.randf_range(-1.5, 1.5)
		var fz := rng.randf_range(500.0, 8000.0)
		var f := TireModel.compute(k, a, fz, P)
		var g := TireModel.compute(-k, -a, fz, P)
		worst = maxf(worst, (f + g).length())
	assert_true(worst < 1e-6, "antisymmetry worst " + str(worst))
	assert_true(TireModel.compute(0.0, 0.0, FZ, P) == Vector2.ZERO, "F(0,0) == 0")


func test_determinism() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var ok := true
	for i in 1000:
		var k := rng.randf_range(-2.0, 2.0)
		var a := rng.randf_range(-3.0, 3.0)
		var fz := rng.randf_range(-100.0, 9000.0)
		var f1 := TireModel.compute(k, a, fz, P)
		var f2 := TireModel.compute(k, a, fz, P)
		if f1 != f2 or is_nan(f1.x) or is_nan(f1.y):
			ok = false
	assert_true(ok, "determinism over 1000 random inputs, no NaN")


func test_combined() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var worst := 0.0
	var fmax := TireModel.peak_force(FZ, P)
	for i in 50:
		var f := TireModel.compute(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.2, 1.2), FZ, P)
		worst = maxf(worst, sqrt(pow(f.x / fmax, 2) + pow(f.y / fmax, 2)))
	assert_true(worst <= 1.0 + 1e-3, "friction ellipse worst %.5f" % worst)
	var lock := TireModel.compute(-1.0, deg_to_rad(8.0), FZ, P)
	assert_true(absf(lock.y) <= 0.4 * fmax, "locked-wheel Fy %.1f <= 40%% of %.1f" % [absf(lock.y), fmax])


func test_load() -> void:
	var m3 := TireModel.effective_mu(3000.0, P)
	var m6 := TireModel.effective_mu(6000.0, P)
	var drop := 1.0 - m6 / m3
	assert_true(drop >= 0.03 and drop <= 0.08, "mu drop at 6000 N: %.3f" % drop)
	var f3 := TireModel.compute(0.1, 0.0, 3000.0, P).x
	var f6 := TireModel.compute(0.1, 0.0, 6000.0, P).x
	assert_true(f6 > f3, "absolute peak force rises with Fz")
	assert_true(TireModel.compute(0.1, 0.1, 0.0, P) == Vector2.ZERO
			and TireModel.compute(0.1, 0.1, -50.0, P) == Vector2.ZERO, "Fz <= 0 -> zero")


func sgn(v: float) -> int:
	return 0 if v == 0.0 else (1 if v > 0.0 else -1)


func test_low_speed() -> void:
	var ok := true
	for vx in [0.0, 1e-9, -1e-9, 0.1, -0.3, 0.49]:
		for vy in [0.0, 0.1, -0.1, 5.0]:
			var k := TireModel.slip_ratio(0.0, 0.32, vx, P)
			var a := TireModel.slip_angle(vx, vy, P)
			var ks := TireModel.relax(0.0, k, vx, 1.0 / 120.0, P)
			var al := TireModel.relax(0.0, a, vx, 1.0 / 120.0, P)
			var f := TireModel.compute(ks, al, FZ, P)
			if not (is_finite(k) and is_finite(a) and is_finite(f.x) and is_finite(f.y)) \
					or f.length() > TireModel.peak_force(FZ, P) * 1.001:
				ok = false
	assert_true(ok, "finite and bounded for |vx| < 0.5 including 0")
	# Kinematic: wheel held at vx = 0 with a 0.1 m/s lateral push for 1 s at 120 Hz.
	var slip := 0.0
	var prev_sign := 0
	var flips := 0
	for i in 120:
		slip = TireModel.relax(slip, TireModel.slip_angle(0.0, 0.1, P), 0.0, 1.0 / 120.0, P)
		var s := sgn(TireModel.compute(0.0, slip, FZ, P).y)
		if s != 0 and prev_sign != 0 and s != prev_sign:
			flips += 1
		if s != 0:
			prev_sign = s
	assert_true(flips < 2, "kinematic push: %d sign changes" % flips)
	# Dynamic: a 300 kg wheel mass at vx = 0, 0.1 m/s lateral velocity, left to settle.
	var vy := 0.1
	slip = 0.0
	prev_sign = 0
	flips = 0
	for i in 120:
		slip = TireModel.relax(slip, TireModel.slip_angle(0.0, vy, P), 0.0, 1.0 / 120.0, P)
		var f_y := TireModel.compute(0.0, slip, FZ, P).y
		var s := sgn(f_y) if absf(f_y) > 1.0 else 0 # ignore sub-1 N noise
		if s != 0 and prev_sign != 0 and s != prev_sign:
			flips += 1
		if s != 0:
			prev_sign = s
		vy += TireModel.limit_to_stop(f_y, vy, 300.0, 1.0 / 120.0) / 300.0 / 120.0
	assert_true(flips < 2, "dynamic settle: %d sign changes (vy end %.4f)" % [flips, vy])


func test_write_csv() -> void:
	var f := FileAccess.open("user://tire_curves.csv", FileAccess.WRITE)
	assert_not_null(f, "csv open")
	if f == null:
		return
	f.store_line("slip,Fx_vs_kappa,Fy_vs_alpha_rad")
	for i in 201:
		var x := i / 200.0
		f.store_line("%f,%f,%f" % [x, fx(x), fy(x * 1.5)])
	f.close()
	assert_true(FileAccess.file_exists("user://tire_curves.csv"), "CSV written to user://tire_curves.csv")
