## GDScript reference of the per-wheel numeric core (#17): the unheld branch of Vehicle.step_wheels
## for 4 wheels (relaxed slip, combined-slip tire force, implicit Fx/Fy, stop limiter, spin step),
## expressed on a flat PackedFloat64Array so the same call shape can be ported to GDExtension.
## It calls the production TireModel / WheelSpin statics, so it measures the real code.
##
## in  layout: [0..10] tire/wheel params, then 4 x IN_STRIDE wheel inputs (see below)
## out layout: 4 x OUT_STRIDE = kappa, alpha, omega, fx, fy
extends RefCounted

const P_COUNT := 11 # mu_peak mu_slide kappa_peak alpha_peak falloff nominal_load load_sens relax_len low_floor min_relax radius
const IN_STRIDE := 12 # omega kappa alpha vx vy fz t_drive t_brake inertia wheel_mass push_x push_y
const OUT_STRIDE := 5

var _tp := TireParams.new()


func step4(buf: PackedFloat64Array, dt: float) -> PackedFloat64Array:
	var p := _tp
	p.mu_peak = buf[0]
	p.mu_slide = buf[1]
	p.kappa_peak = buf[2]
	p.alpha_peak = buf[3]
	p.falloff = buf[4]
	p.nominal_load = buf[5]
	p.load_sensitivity = buf[6]
	p.relaxation_length = buf[7]
	p.low_speed_floor = buf[8]
	p.min_relax_rate = buf[9]
	var radius := buf[10]
	var out := PackedFloat64Array()
	out.resize(4 * OUT_STRIDE)
	for i in 4:
		var b := P_COUNT + i * IN_STRIDE
		var omega := buf[b]
		var kappa := buf[b + 1]
		var alpha := buf[b + 2]
		var vx := buf[b + 3]
		var vy := buf[b + 4]
		var fz := buf[b + 5]
		var t_drive := buf[b + 6]
		var brake := buf[b + 7]
		var wi := buf[b + 8]
		var m := buf[b + 9]
		var push_x := buf[b + 10]
		var push_y := buf[b + 11]
		kappa = TireModel.relax(kappa, TireModel.slip_ratio(omega, radius, vx, p), vx, dt, p)
		alpha = TireModel.relax(alpha, TireModel.slip_angle(vx, vy, p), vx, dt, p)
		var f0 := TireModel.compute(kappa, alpha, fz, p)
		var sl := WheelSpin.fx_slopes(kappa, omega, vx, fz, radius, vx, dt, p, alpha)
		var fx := WheelSpin.implicit_fx(f0.x, sl.x, sl.y, t_drive, radius, wi, m, dt, push_x)
		if brake > 0.0 and WheelSpin.step(omega, t_drive, brake, fx, radius, wi, dt) == 0.0:
			fx = WheelSpin.implicit_fx(f0.x, 0.0, sl.y, t_drive, radius, wi, m, dt, push_x)
		var sy := WheelSpin.fy_slope(kappa, alpha, vx, vy, fz, dt, p)
		var fy := WheelSpin.implicit_fy(f0.y, sy, m, dt, push_y)
		if t_drive * fx <= 0.0:
			fx = TireModel.limit_to_stop(fx, vx, m, dt, push_x)
		fy = TireModel.limit_to_stop(fy, vy, m, dt, push_y)
		omega = WheelSpin.step(omega, t_drive, brake, fx, radius, wi, dt)
		var o := i * OUT_STRIDE
		out[o] = kappa
		out[o + 1] = alpha
		out[o + 2] = omega
		out[o + 3] = fx
		out[o + 4] = fy
	return out
