extends GutTest
## Pure lateral-force pieces (#74): implicit_fy, fy_slope, limit_to_stop with an external push.
## Quarter-car lateral stub: a point mass sliding sideways over the tire model.

const DT := 1.0 / 120.0
const FZ := 3000.0
const M := 300.0


func _slide(vy0: float, vx: float, steps: int, push := 0.0) -> Dictionary:
	var p := TireParams.new()
	var vy := vy0
	var alpha := 0.0
	var flips := 0
	var overshoot := 0.0
	var prev := vy
	for i in steps:
		alpha = TireModel.relax(alpha, TireModel.slip_angle(vx, vy, p), vx, DT, p)
		var f0 := TireModel.compute(0.0, alpha, FZ, p).y
		var k := WheelSpin.fy_slope(0.0, alpha, vx, vy, FZ, DT, p)
		var fy := WheelSpin.implicit_fy(f0, k, M, DT, push)
		fy = TireModel.limit_to_stop(fy, vy, M, DT, push)
		vy += (fy + push) / M * DT
		if prev != 0.0 and vy != 0.0 and signf(prev) != signf(vy):
			flips += 1
		if vy * vy0 < 0.0:
			overshoot = maxf(overshoot, absf(vy))
		prev = vy
	return {"vy": vy, "flips": flips, "overshoot": overshoot}


func test_fy_opposes_sideslip() -> void:
	var p := TireParams.new()
	assert_lt(TireModel.compute(0.0, 0.05, FZ, p).y, 0.0)
	assert_gt(TireModel.compute(0.0, -0.05, FZ, p).y, 0.0)


func test_fy_slope_is_non_positive() -> void:
	var p := TireParams.new()
	for vy in [-3.0, -0.3, 0.0, 0.3, 3.0]:
		assert_lte(WheelSpin.fy_slope(0.0, 0.0, 10.0, vy, FZ, DT, p), 0.0)


func test_implicit_fy_matches_explicit_when_soft() -> void:
	assert_almost_eq(WheelSpin.implicit_fy(-100.0, 0.0, M, DT), -100.0, 1e-9)


func test_implicit_fy_is_damped_for_stiff_slope() -> void:
	var fy := WheelSpin.implicit_fy(-1000.0, -90000.0, M, DT)
	assert_between(fy, -1000.0 / 3.0, -1000.0 / 3.5)


func test_sideways_slide_decays_without_ringing_at_speed_and_rest() -> void:
	for vx in [0.0, 0.2, 5.0, 30.0]:
		var r := _slide(2.0, vx, 600)
		if vx < 0.5: # below the low-speed floor slip tracks instantly: must not ring at all
			assert_eq(r.flips, 0, "no sign flips at vx=%.1f" % vx)
		else: # relaxation lag may overshoot slightly, never ring up
			assert_lt(r.overshoot, 0.25 * 2.0, "overshoot at vx=%.1f (%.3f)" % [vx, r.overshoot])
		assert_lt(absf(r.vy), 0.35 if vx > 0.4 else 0.05, "decayed at vx=%.1f (vy=%.3f)" % [vx, r.vy])


func test_lateral_equilibrium_on_side_slope() -> void:
	# 10 deg side slope: push = m g sin(10 deg) along the slide direction. Tire must balance it.
	var push := M * 9.81 * sin(deg_to_rad(10.0))
	var r := _slide(0.0, 0.0, 600, push)
	assert_lt(absf(r.vy), 0.02, "creep on side slope (vy=%.4f)" % r.vy)


func test_limit_to_stop_push() -> void:
	# Opposing force is allowed up to m*|v|/dt plus what the push adds along v.
	assert_almost_eq(TireModel.limit_to_stop(-1e9, 1.0, M, DT, 0.0), -M / DT, 1e-6)
	assert_almost_eq(TireModel.limit_to_stop(-1e9, 1.0, M, DT, 500.0), -(M / DT + 500.0), 1e-6)
	assert_almost_eq(TireModel.limit_to_stop(-1e9, 1.0, M, DT, -1e9), 0.0, 1e-6)
	assert_eq(TireModel.limit_to_stop(50.0, 1.0, M, DT, 10.0), 50.0, "same-direction untouched")
