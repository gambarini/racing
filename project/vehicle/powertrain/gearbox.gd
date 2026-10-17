## Automatic gearbox (#11): rpm thresholds that move with throttle, a minimum interval between
## shifts and a torque cut for the duration of a shift. Pure state machine, no node access.
## Up/down shifts use forward gears only. Direction (R / N / 1st) is selected by `select` (#108): only
## when stopped (|v| < STOP_SPEED): brake held with no throttle for REVERSE_HOLD s toggles between
## forward and reverse, no throttle and no brake for NEUTRAL_HOLD s selects neutral, throttle
## re-selects 1st from neutral.
class_name Gearbox
extends RefCounted

var def: PowertrainDefinition
var gear := 1 ## 1..n forward, 0 neutral, -1 reverse
var since_shift := 1e9 ## s since the last shift started
var cut_left := 0.0 ## s of torque cut still to run
var _brake_hold := 0.0
var _idle_hold := 0.0
var _toggle_latched := false

const STOP_SPEED := 0.5 ## m/s
const REVERSE_HOLD := 0.3 ## s
const NEUTRAL_HOLD := 0.5 ## s
const PEDAL_MIN := 0.01


func _init(definition: PowertrainDefinition) -> void:
	def = definition


func upshift_rpm(throttle: float) -> float:
	return lerpf(def.upshift_rpm_closed, def.upshift_rpm_open, clampf(throttle, 0.0, 1.0))


func downshift_rpm(throttle: float) -> float:
	return lerpf(def.downshift_rpm_closed, def.downshift_rpm_open, clampf(throttle, 0.0, 1.0))


## Direction selection. `speed` is the signed forward speed (m/s). Returns true if the gear changed.
func select(dt: float, throttle: float, brake: float, speed: float) -> bool:
	var on_throttle := throttle > PEDAL_MIN
	var on_brake := brake > PEDAL_MIN
	if absf(speed) >= STOP_SPEED:
		_brake_hold = 0.0
		_idle_hold = 0.0
		_toggle_latched = false
		return false
	if gear == 0 and on_throttle:
		return _set_gear(1)
	_brake_hold = _brake_hold + dt if on_brake and not on_throttle else 0.0
	_idle_hold = _idle_hold + dt if not on_brake and not on_throttle else 0.0
	if not on_brake:
		_toggle_latched = false
	if _brake_hold >= REVERSE_HOLD and not _toggle_latched:
		_toggle_latched = true
		return _set_gear(1 if gear == -1 else -1)
	if _idle_hold >= NEUTRAL_HOLD and gear != 0:
		return _set_gear(0)
	return false


func _set_gear(g: int) -> bool:
	gear = g
	cut_left = 0.0
	return true


func total_ratio() -> float:
	return def.total_ratio(gear)


func torque_cut() -> bool:
	return cut_left > 0.0


## Advance one tick. `rpm_up` is what the upshift test sees (engine or driveline, whichever is
## higher), `rpm_down` the driveline speed. Returns +1 / -1 on the tick a shift starts, else 0.
func update(dt: float, rpm_up: float, rpm_down: float, throttle: float) -> int:
	since_shift += dt
	cut_left = maxf(cut_left - dt, 0.0)
	if gear < 1 or since_shift < def.min_shift_interval:
		return 0
	var dir := 0
	if gear < def.gear_count() and rpm_up >= upshift_rpm(throttle):
		dir = 1
	elif gear > 1 and rpm_down < downshift_rpm(throttle):
		dir = -1
	if dir != 0:
		gear += dir
		since_shift = 0.0
		cut_left = def.shift_time
	return dir
