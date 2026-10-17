## Automatic gearbox (#11): rpm thresholds that move with throttle, a minimum interval between
## shifts and a torque cut for the duration of a shift. Pure state machine, no node access.
## Auto mode only selects forward gears; reverse is a data ratio for a later manual/reverse input.
class_name Gearbox
extends RefCounted

var def: PowertrainDefinition
var gear := 1 ## 1..n forward, 0 neutral, -1 reverse
var since_shift := 1e9 ## s since the last shift started
var cut_left := 0.0 ## s of torque cut still to run


func _init(definition: PowertrainDefinition) -> void:
	def = definition


func upshift_rpm(throttle: float) -> float:
	return lerpf(def.upshift_rpm_closed, def.upshift_rpm_open, clampf(throttle, 0.0, 1.0))


func downshift_rpm(throttle: float) -> float:
	return lerpf(def.downshift_rpm_closed, def.downshift_rpm_open, clampf(throttle, 0.0, 1.0))


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
