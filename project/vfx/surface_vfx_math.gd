## Pure math for per-surface VFX (#20): emission intensity from slip and speed, blend scaling and
## the tyre-mark slip gate. No nodes, no state.
class_name SurfaceVfxMath
extends RefCounted

const MIN_SPEED := 2.0 ## m/s: no particles at or below this speed
const FULL_SPEED := 12.0 ## m/s: speed factor reaches 1 here
const KAPPA_REF := 0.3 ## slip ratio giving full slip intensity
const ALPHA_REF := 0.3 ## rad, slip angle giving full slip intensity

## Performance budget (wiki "Performance Budgets": "dust budget capped", no number given, so
## chosen here): live particles per car, and tyre-mark segments alive in the whole scene.
const MAX_LIVE_PARTICLES_PER_CAR := 300
const MAX_EFFECT_AMOUNT := 75 ## per wheel emitter, so 4 wheels at most reach the per-car cap
const MAX_PARTICLES_PER_WHEEL := 75.0 ## across all of a wheel's emitters (blends)
const MAX_MARK_SEGMENTS := 400


## 0..1 intensity for one wheel on one surface: 0 when airborne or at/below MIN_SPEED, otherwise
## a speed ramp times (roll_rate + (1 - roll_rate) * slip), monotonic in |kappa| and |alpha|.
static func intensity(grounded: bool, kappa: float, alpha: float, speed: float,
		roll_rate: float) -> float:
	if not grounded or speed <= MIN_SPEED:
		return 0.0
	var speed_f := clampf((speed - MIN_SPEED) / (FULL_SPEED - MIN_SPEED), 0.0, 1.0)
	var k := kappa / KAPPA_REF
	var a := alpha / ALPHA_REF
	var slip := clampf(sqrt(k * k + a * a), 0.0, 1.0)
	var r := clampf(roll_rate, 0.0, 1.0)
	return speed_f * (r + (1.0 - r) * slip)


## True when the wheel slip exceeds the surface's mark threshold. The slip-angle test is ignored
## at or below MIN_SPEED where alpha is noise.
static func should_mark(grounded: bool, kappa: float, alpha: float, speed: float,
		style: TyreMarkStyle) -> bool:
	if not grounded or style == null:
		return false
	if absf(kappa) > style.slip_ratio_threshold:
		return true
	return speed > MIN_SPEED and absf(alpha) > style.slip_angle_threshold
