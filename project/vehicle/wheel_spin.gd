## Pure wheel-spin integration (#10): no node access, same inputs -> same outputs.
## omega' = (T_drive - T_brake*sign(omega) - Fx*r) / I. Brake torque is dissipative: it can bring
## the wheel to rest but never reverses it (omega is clamped at 0 and stays there).
##
## The grip reaction is very stiff at low speed (dFx/dv ~ 1e5 N/(m/s) against a ~10 kg reduced
## mass at 120 Hz), so explicit integration of wheel + body rings. `implicit_fx` linearises the
## tire force in both wheel speed and ground speed and solves the coupled wheel/body step in
## closed form; the resulting Fx is used for BOTH the wheel torque and the body force, so
## action/reaction stays consistent. Slopes are clamped (post-peak softening stays explicit).
class_name WheelSpin
extends RefCounted


## One explicit step with a given tire force. `fx` is the longitudinal ground force on the tire
## (+ accelerates the car); its reaction torque on the wheel is -fx*r. `t_brake` is a magnitude.
static func step(omega: float, t_drive: float, t_brake: float, fx: float, radius: float,
		inertia: float, dt: float) -> float:
	var free := omega + (t_drive - fx * radius) / inertia * dt
	var dw := maxf(t_brake, 0.0) / inertia * dt
	if absf(free) <= dw:
		return 0.0
	return free - signf(free) * dw


## Tire force that is consistent with the end-of-step wheel and ground speeds (backward Euler on
## the linearised force). `slope_w` = dFx/domega >= 0, `slope_v` = dFx/dvx <= 0 (per-step relax
## gain already included), `body_mass` = mass the force accelerates along the wheel axis,
## `push` = other signed force on that mass along the axis (gravity slope component), so a parked
## car on a slope reaches force equilibrium instead of a velocity-proportional creep.
static func implicit_fx(fx0: float, slope_w: float, slope_v: float, t_drive: float, radius: float,
		inertia: float, body_mass: float, dt: float, push := 0.0) -> float:
	var kw := maxf(slope_w, 0.0)
	var kv := minf(slope_v, 0.0)
	var denom := 1.0 + kw * dt * radius / inertia - kv * dt / body_mass
	return (fx0 + kw * dt * t_drive / inertia + kv * dt * push / body_mass) / denom


## Numerical slopes of the relaxed-slip tire force: x = dFx/domega, y = dFx/dvx.
static func fx_slopes(kappa: float, omega: float, vx: float, fz: float, radius: float,
		vx_for_relax: float, dt: float, p: TireParams, alpha := 0.0) -> Vector2:
	var gain := relax_gain(vx_for_relax, dt, p)
	var dk := 0.01
	var dfdk := (TireModel.compute(kappa + dk, alpha, fz, p).x - TireModel.compute(kappa - dk, alpha, fz, p).x) / (2.0 * dk)
	var dw := 0.05
	var dkdw := (TireModel.slip_ratio(omega + dw, radius, vx, p) - TireModel.slip_ratio(omega - dw, radius, vx, p)) / (2.0 * dw)
	var dv := 0.05
	var dkdv := (TireModel.slip_ratio(omega, radius, vx + dv, p) - TireModel.slip_ratio(omega, radius, vx - dv, p)) / (2.0 * dv)
	return Vector2(maxf(dfdk * dkdw * gain, 0.0), minf(dfdk * dkdv * gain, 0.0))


## Lateral counterpart of implicit_fx: backward Euler on Fy(vy) linearised with `slope_v` =
## dFy/dvy <= 0 (relax gain included). Stable for any stiffness: fy = fy0 / (1 + |k| dt / m).
static func implicit_fy(fy0: float, slope_v: float, body_mass: float, dt: float, push := 0.0) -> float:
	var kv := minf(slope_v, 0.0)
	return (fy0 + kv * dt * push / body_mass) / (1.0 - kv * dt / body_mass)


## Numerical dFy/dvy of the relaxed-slip tire force (<= 0).
static func fy_slope(kappa: float, alpha: float, vx: float, vy: float, fz: float, dt: float,
		p: TireParams) -> float:
	var da := 0.01
	var dfda := (TireModel.compute(kappa, alpha + da, fz, p).y - TireModel.compute(kappa, alpha - da, fz, p).y) / (2.0 * da)
	var dv := 0.05
	var dadv := (TireModel.slip_angle(vx, vy + dv, p) - TireModel.slip_angle(vx, vy - dv, p)) / (2.0 * dv)
	return minf(dfda * dadv * relax_gain(vx, dt, p), 0.0)


## Relaxation gain TireModel.relax applies per step at this speed and dt.
static func relax_gain(vx: float, dt: float, p: TireParams) -> float:
	var rate := p.min_relax_rate if absf(vx) < p.low_speed_floor else absf(vx) / maxf(p.relaxation_length, 1e-4)
	return 1.0 - exp(-rate * dt)
