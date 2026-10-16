## Pure combined-slip tire model (no node access, no state): same inputs -> same outputs.
## Conventions: kappa = (wheel surface speed - vx) / |vx| (negative = braking, Fx has its sign);
## alpha = slip angle in rad, Fy opposes alpha. Forces in N in the wheel frame.
## Method: one normalised slip s = hypot(kappa/kappa_peak, alpha/alpha_peak) drives a single
## friction curve; force direction follows the slip vector, so the friction ellipse (circle in
## normalised space) holds by construction and braking/lateral coupling is automatic.
class_name TireModel
extends RefCounted

const KAPPA_LIMIT := 2.0


## Normalised friction curve: 0 -> 0, rises to 1 at x = 1, falls monotonically to mu_slide/mu_peak.
static func shape(x: float, p: TireParams) -> float:
	x = absf(x)
	if x <= 1.0:
		return sin(0.5 * PI * x)
	var r := p.mu_slide / p.mu_peak
	var d := x - 1.0
	return r + (1.0 - r) / (1.0 + p.falloff * d * d)


## Peak friction coefficient scaled for load (mu drops as Fz rises above nominal).
static func effective_mu(fz: float, p: TireParams) -> float:
	var k := clampf(1.0 - p.load_sensitivity * (fz - p.nominal_load) / p.nominal_load, 0.3, 1.5)
	return p.mu_peak * k


## Returns Vector2(Fx, Fy) in N.
static func compute(kappa: float, alpha: float, fz: float, p: TireParams) -> Vector2:
	if fz <= 0.0:
		return Vector2.ZERO
	var sx := kappa / p.kappa_peak
	var sy := alpha / p.alpha_peak
	var s := sqrt(sx * sx + sy * sy)
	if s < 1e-9:
		return Vector2.ZERO
	var f := effective_mu(fz, p) * fz * shape(s, p)
	return Vector2(f * sx / s, -f * sy / s)


## Maximum force along one axis (the friction ellipse semi-axis) at this load.
static func peak_force(fz: float, p: TireParams) -> float:
	return 0.0 if fz <= 0.0 else effective_mu(fz, p) * fz


## Slip ratio from wheel spin; denominator floored so vx = 0 is finite.
static func slip_ratio(omega: float, radius: float, vx: float, p: TireParams) -> float:
	var k := (omega * radius - vx) / maxf(absf(vx), p.low_speed_floor)
	return clampf(k, -KAPPA_LIMIT, KAPPA_LIMIT)


## Slip angle from contact-patch velocities (vx forward, vy lateral); floored denominator.
static func slip_angle(vx: float, vy: float, p: TireParams) -> float:
	return atan2(vy, maxf(absf(vx), p.low_speed_floor))


## Relaxation-length lag: slip chases its target at rate |vx|/L (below low_speed_floor it tracks at min_relax_rate, i.e. effectively instantly, so a stopped wheel does not ring),
## solved exactly per step so it stays stable for any dt. Returns the new slip state.
static func relax(slip: float, target: float, vx: float, dt: float, p: TireParams) -> float:
	var rate := p.min_relax_rate if absf(vx) < p.low_speed_floor else absf(vx) / maxf(p.relaxation_length, 1e-4)
	return slip + (target - slip) * (1.0 - exp(-rate * dt))


## Integrator guard for the caller (#8/#10): a force that opposes velocity `v` must not reverse it
## within one step, otherwise explicit integration chatters near rest. `mass` is the effective
## mass the wheel force acts on; `push` is the signed other force on that mass along the same axis
## (e.g. gravity's slope component) which the tire must also cancel to stop the motion. Returns
## the force clamped to |F| <= max(0, mass*|v|/dt + push*sign(v)) when opposing v.
static func limit_to_stop(force: float, v: float, mass: float, dt: float, push := 0.0) -> float:
	if force * v >= 0.0:
		return force
	return signf(force) * minf(absf(force), maxf(mass * absf(v) / dt + push * signf(v), 0.0))
