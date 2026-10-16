## Pure suspension functions (no node access) so they are unit-testable.
## Convention: compression c in [0, travel] m, 0 = full droop. Forces in N, positive = pushes body up.
class_name SuspensionMath
extends RefCounted


static func spring_force(c: float, k: float) -> float:
	return k * c


## rate = d(compression)/dt; positive (bump) uses the bump coefficient, negative the rebound one.
## Returns the force opposing the motion (positive when compressing).
static func damper_force(rate: float, c_bump: float, c_rebound: float) -> float:
	return (c_bump if rate > 0.0 else c_rebound) * rate


## Progressive stop: zero until (travel - zone), then stiff linear rise.
static func bump_stop_force(c: float, travel: float, zone: float, rate: float) -> float:
	return rate * maxf(c - (travel - zone), 0.0)


## Anti-roll bar: equal and opposite forces on the axle's wheels, proportional to the
## compression difference. Returns the force added to the LEFT wheel (negate for right).
static func arb_force(c_left: float, c_right: float, k_arb: float) -> float:
	return k_arb * (c_left - c_right)


## A strut can only push: total is clamped at zero.
static func total_force(c: float, rate: float, k: float, c_bump: float, c_rebound: float,
		travel: float, zone: float, stop_rate: float, arb: float) -> float:
	var f := spring_force(c, k) + damper_force(rate, c_bump, c_rebound) \
			+ bump_stop_force(c, travel, zone, stop_rate) + arb
	return maxf(f, 0.0)
