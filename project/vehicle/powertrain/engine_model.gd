## Engine torque and rev limiter (#11). The torque lookup is static; the instance only holds the
## crank speed and the limiter latch. The limiter cuts torque (never clamps rpm), so the inertia
## still shows in the rpm trace.
class_name EngineModel
extends RefCounted

const RPM_TO_RAD := TAU / 60.0

var def: PowertrainDefinition
var omega := 0.0 ## crank speed, rad/s
var torque := 0.0 ## Nm at the crank, last computed
var limiter_cut := false


func _init(definition: PowertrainDefinition) -> void:
	def = definition
	omega = def.idle_rpm * RPM_TO_RAD


func rpm() -> float:
	return omega / RPM_TO_RAD


## Full-throttle torque: linear interpolation of the table, clamped outside it.
static func curve_torque(curve: PackedVector2Array, rpm_: float) -> float:
	var n := curve.size()
	if n == 0:
		return 0.0
	if rpm_ <= curve[0].x:
		return curve[0].y
	if rpm_ >= curve[n - 1].x:
		return curve[n - 1].y
	for i in range(1, n):
		if rpm_ <= curve[i].x:
			var a := curve[i - 1]
			var b := curve[i]
			return lerpf(a.y, b.y, (rpm_ - a.x) / (b.x - a.x))
	return curve[n - 1].y


static func closed_torque(d: PowertrainDefinition, rpm_: float) -> float:
	return -(d.closed_torque_base + d.closed_torque_per_rpm * rpm_)


## Torque for a throttle position: linear blend closed-throttle -> curve. No limiter, no idle.
static func torque_at(d: PowertrainDefinition, rpm_: float, throttle: float) -> float:
	return lerpf(closed_torque(d, rpm_), curve_torque(d.torque_curve, rpm_), clampf(throttle, 0.0, 1.0))


## The throttle the idle governor asks for: the driver's, or more when rpm sags below idle.
static func governed_throttle(d: PowertrainDefinition, rpm_: float, throttle: float) -> float:
	var idle := clampf(d.idle_base_throttle + (d.idle_rpm - rpm_) * d.idle_gain, 0.0, 0.8)
	return maxf(throttle, idle)


## Torque at the current crank speed including the idle governor and the rev limiter latch.
func compute_torque(throttle: float) -> float:
	var r := rpm()
	var on := def.limiter_rpm - def.limiter_lead_rpm
	if r >= on:
		limiter_cut = true
	elif r < on - def.limiter_hysteresis_rpm:
		limiter_cut = false
	var thr := 0.0 if limiter_cut else governed_throttle(def, r, throttle)
	torque = torque_at(def, r, thr)
	return torque


## Advance a free (or externally loaded) crank: load_torque opposes the engine.
func integrate(load_torque: float, dt: float) -> void:
	omega = maxf(omega + (torque - load_torque) / def.engine_inertia * dt, 0.0)
