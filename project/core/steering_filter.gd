## Pure input-filter math (no nodes, no state): same inputs -> same outputs.
## Used by DriverInput; unit-tested in tests/test_steering_filter.gd.
class_name SteeringFilter
extends RefCounted

const DEADZONE_DEFAULT := 0.15
const DEADZONE_MIN := 0.0
const DEADZONE_MAX := 0.4
const GAMMA_DEFAULT := 1.5
const GAMMA_MIN := 1.0
const GAMMA_MAX := 3.0
const TRIGGER_DEADZONE := 0.05
## Speed at which the speed-sensitive range/rate reach their high-speed values.
const SPEED_REF_KMH := 150.0
const RANGE_MIN_SCALE := 0.35
const RATE_LOW_SPEED := 6.0  # 1/s at 0 km/h
const RATE_HIGH_SPEED := 2.5  # 1/s at SPEED_REF_KMH
const ASSIST_SLIP_THRESHOLD_DEG := 8.0
const ASSIST_MAX_STEER_RAD := 0.5934  # = 34 deg, VehicleDefinition.max_steer_angle (inner wheel at steer == 1; #82)


## Deadzone rescaled so output is 0 at the edge and 1 at full deflection.
static func deadzone(x: float, dz: float = DEADZONE_DEFAULT) -> float:
	dz = clampf(dz, DEADZONE_MIN, DEADZONE_MAX)
	var a := absf(x)
	if a <= dz:
		return 0.0
	return signf(x) * minf((a - dz) / (1.0 - dz), 1.0)


## out = sign(x) * |x|^g
static func curve(x: float, g: float = GAMMA_DEFAULT) -> float:
	g = clampf(g, GAMMA_MIN, GAMMA_MAX)
	return signf(x) * pow(absf(x), g)


## Raw stick -> shaped command in [-1, 1] (deadzone then curve).
static func shape_stick(x: float, dz: float = DEADZONE_DEFAULT, g: float = GAMMA_DEFAULT) -> float:
	return curve(deadzone(x, dz), g)


## Trigger/pedal 0..1 with its own small deadzone (rescaled).
static func shape_trigger(x: float, dz: float = TRIGGER_DEADZONE) -> float:
	return clampf(maxf(x - dz, 0.0) / (1.0 - dz), 0.0, 1.0)


## Max steer scale: 1.0 at 0 km/h, linear down to min_scale at ref_kmh and beyond.
static func range_scale(speed_kmh: float, min_scale: float = RANGE_MIN_SCALE, ref_kmh: float = SPEED_REF_KMH) -> float:
	var t := clampf(speed_kmh / ref_kmh, 0.0, 1.0)
	return lerpf(1.0, min_scale, t)


## Steer rate limit in 1/s (full lock = 1.0).
static func rate_limit(speed_kmh: float, low: float = RATE_LOW_SPEED, high: float = RATE_HIGH_SPEED, ref_kmh: float = SPEED_REF_KMH) -> float:
	var t := clampf(speed_kmh / ref_kmh, 0.0, 1.0)
	return lerpf(low, high, t)


## One filter tick: scales the target by the speed range, then rate-limits toward it.
static func step_steer(current: float, target: float, dt: float, speed_kmh: float) -> float:
	var goal := clampf(target, -1.0, 1.0) * range_scale(speed_kmh)
	return move_toward(current, goal, rate_limit(speed_kmh) * dt)


## Move a 0..1 pedal value toward target at rate_up / rate_down (1/s).
static func ramp(current: float, target: float, dt: float, rate_up: float, rate_down: float) -> float:
	var rate := rate_up if target > current else rate_down
	return move_toward(current, target, rate * dt)


## Counter-steer assist. Convention: rear_slip_deg > 0 means the car travels toward the positive
## steer side relative to its heading, so positive steer is "toward the slide" (counter-steer).
## Steer toward the slide is clamped to the slip-angle-equivalent steer. Returns
## {"steer": float, "active": bool}. When disabled or below threshold the steer is unchanged.
static func counter_steer_assist(steer: float, rear_slip_deg: float, enabled: bool, threshold_deg: float = ASSIST_SLIP_THRESHOLD_DEG, max_steer_rad: float = ASSIST_MAX_STEER_RAD) -> Dictionary:
	if not enabled or absf(rear_slip_deg) <= threshold_deg:
		return {"steer": steer, "active": false}
	var limit := deg_to_rad(absf(rear_slip_deg)) / max_steer_rad
	var toward := signf(rear_slip_deg)
	var along := steer * toward
	if along > limit:
		return {"steer": toward * limit, "active": true}
	return {"steer": steer, "active": false}
