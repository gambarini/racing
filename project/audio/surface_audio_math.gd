## Pure parameter maths for tire/surface audio and rumble (#21). No nodes, deterministic.
class_name SurfaceAudioMath
extends RefCounted

const FLOOR := 0.01 ## amplitude below which gain is allowed to snap (-40 dB)
const MAX_STEP_DB_PER_50MS := 5.5 ## crossfade slew limit (acceptance: < 6 dB per 50 ms)


## Rolling loop level 0..1 at wheel surface speed (m/s): rises with speed.
static func roll_gain(p: SurfaceAudioProfile, speed: float) -> float:
	var t := clampf(absf(speed) / p.roll_speed_ref, 0.0, 1.0)
	return p.roll_gain * sqrt(t)


static func roll_pitch(p: SurfaceAudioProfile, speed: float) -> float:
	return lerpf(p.pitch_min, p.pitch_max, clampf(absf(speed) / p.roll_speed_ref, 0.0, 1.0))


## Combined slip magnitude of one wheel.
static func slip_amount(kappa: float, alpha: float) -> float:
	return sqrt(kappa * kappa + alpha * alpha)


## Slip loop level: exactly 0 at or below the threshold, rising smoothly to slip_gain.
static func slip_gain(p: SurfaceAudioProfile, slip: float) -> float:
	if slip <= p.slip_threshold:
		return 0.0
	var t := clampf((slip - p.slip_threshold) / maxf(p.slip_full - p.slip_threshold, 1e-6), 0.0, 1.0)
	return p.slip_gain * t * t * (3.0 - 2.0 * t)


## Gamepad motor amplitudes (x = weak/high-frequency, y = strong/low-frequency) for one wheel's
## surface at wheel speed and slip. Zero when the wheel is not on the ground (caller).
static func rumble(p: SurfaceAudioProfile, speed: float, slip: float) -> Vector2:
	var t := clampf(absf(speed) / p.roll_speed_ref, 0.0, 1.0)
	var s := 0.0
	if slip > p.slip_threshold:
		s = clampf((slip - p.slip_threshold) / maxf(p.slip_full - p.slip_threshold, 1e-6), 0.0, 1.0)
	var k := t * (1.0 + p.rumble_slip_boost * s)
	return Vector2(clampf(p.rumble_weak * k, 0.0, 1.0), clampf(p.rumble_strong * k, 0.0, 1.0))


## Move a linear gain toward `target` without exceeding MAX_STEP_DB_PER_50MS above FLOOR, so
## surface crossfades do not click. Below FLOOR rises jump to FLOOR and falls snap to the target.
static func slew(cur: float, target: float, dt: float) -> float:
	var ratio := pow(10.0, MAX_STEP_DB_PER_50MS / 20.0 * dt / 0.05)
	if target > cur:
		return minf(target, maxf(cur * ratio, minf(target, FLOOR)))
	var down := cur / ratio
	if down < FLOOR:
		return target
	return maxf(target, down)
