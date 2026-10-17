## Powertrain facade (#11): engine -> auto clutch -> gearbox -> final drive -> differential.
## Node-free. Vehicle calls `step` once per physics tick before `step_wheels` and copies
## `torque_left/right` into Wheel.drive_torque (and `reflected_inertia` into Wheel.extra_inertia).
##
## Clutch model. Slipping: the clutch passes at most capacity*engagement, in the direction of the
## slip; the engine is integrated implicitly against it (stable at 120 Hz). Locked: the engine
## runs at the driveline speed and its inertia is reflected onto the driven wheels
## (`reflected_inertia`), so the wheels see ratio*T_engine and the engine inertia is not lost.
## Lock is entered when the clutch is nearly fully engaged, within clutch_lock_window_rpm of the
## driveline speed, and the torque it would have to carry fits its capacity; it is left when that torque no longer fits.
class_name Powertrain
extends RefCounted

const RPM_TO_RAD := EngineModel.RPM_TO_RAD

var def: PowertrainDefinition
var engine: EngineModel
var gearbox: Gearbox

var locked := false
var engagement := 0.0
var clutch_torque := 0.0 ## Nm through the clutch (engine side), last tick
var rpm_driveline := 0.0 ## rpm the wheels would turn the engine at (signed by gear direction)
var torque_left := 0.0 ## Nm to the left driven wheel
var torque_right := 0.0
var reflected_inertia := 0.0 ## kg m^2 to add to each driven wheel while locked
var shifts := 0
var _prev_w_drive := 0.0


func _init(definition: PowertrainDefinition) -> void:
	def = definition
	engine = EngineModel.new(def)
	gearbox = Gearbox.new(def)


func rpm() -> float:
	return engine.rpm()


func gear() -> int:
	return gearbox.gear


## Slip between engine and driveline in rpm (+ = engine faster).
func clutch_slip_rpm() -> float:
	return engine.rpm() - rpm_driveline


func engine_torque() -> float:
	return engine.torque


## One physics tick. `wl`, `wr` are the driven wheels' speeds (rad/s, + = forward).
func step(dt: float, throttle: float, wl: float, wr: float) -> void:
	var ratio := gearbox.total_ratio()
	var w_drive := ratio * 0.5 * (wl + wr)
	rpm_driveline = w_drive / RPM_TO_RAD
	# Upshift on engine speed (wheelspin must not trigger it); equal to driveline speed when locked.
	var dir := gearbox.update(dt, engine.rpm(), rpm_driveline, throttle)
	if dir != 0:
		locked = false
		shifts += 1
		ratio = gearbox.total_ratio()
		w_drive = ratio * 0.5 * (wl + wr)
		rpm_driveline = w_drive / RPM_TO_RAD
		_prev_w_drive = w_drive
	var cut := gearbox.torque_cut() or ratio == 0.0
	var ie := def.engine_inertia
	# Ignition cut during a shift: the engine falls back to closed-throttle torque (idle governed).
	var te := engine.compute_torque(0.0 if cut else throttle)
	engagement = 0.0 if cut else Clutch.engagement(def, maxf(engine.rpm(), absf(rpm_driveline)))
	var cap := Clutch.capacity(def, engagement)
	var tc := 0.0
	reflected_inertia = 0.0
	if locked:
		var ae := (w_drive - _prev_w_drive) / dt
		var needed := te - ie * ae
		if cut or absf(needed) > cap:
			locked = false
		else:
			engine.omega = maxf(w_drive, 0.0)
			tc = te # the inertia term is carried by the wheels via reflected_inertia
			reflected_inertia = ie * ratio * ratio * 0.5
	if not locked:
		var w_old := engine.omega
		# Slipping clutch = viscous coupling that saturates at the capacity. Its gain is bounded
		# so the explicit torque it hands the (light, stiffly tire-coupled) wheels cannot ring:
		# k <= assumed driveline inertia / (dt * ratio^2). The engine side is implicit.
		var k := ie * 4.0 / dt
		if ratio != 0.0:
			k = minf(k, def.clutch_driveline_inertia / (dt * ratio * ratio))
		var w_new := (w_old + dt / ie * (te + k * w_drive)) / (1.0 + k * dt / ie)
		tc = k * (w_new - w_drive)
		var saturated := absf(tc) >= cap
		if saturated:
			tc = signf(tc) * cap
			w_new = w_old + dt / ie * (te - tc)
		w_new = maxf(w_new, 0.0)
		# Lock once the clutch is (nearly) fully engaged, within the lock window and able to carry
		# the load it would have to.
		var slip := w_new - w_drive
		if not cut and engagement >= def.clutch_lock_engagement and not saturated \
				and absf(slip) < def.clutch_lock_window_rpm * RPM_TO_RAD:
			var ae2 := (w_drive - _prev_w_drive) / dt
			if absf(te - ie * ae2) <= cap:
				locked = true
				w_new = maxf(w_drive, 0.0)
				tc = te
				reflected_inertia = ie * ratio * ratio * 0.5
		# Numerical damping: while the clutch bites, keep part of the engine inertia on the wheels.
		# A bare 1.2 kg m^2 wheel handed a slipping-clutch torque outruns the tire's relaxation and
		# burns out; scaling by engagement keeps an open clutch (shifts, idle) free.
		if not locked:
			reflected_inertia = def.clutch_slip_inertia_share * ie * ratio * ratio * 0.5 * engagement
		engine.omega = w_new
	clutch_torque = tc
	_prev_w_drive = w_drive
	var split := Differential.split(def, tc * ratio, wl, wr)
	torque_left = split.x
	torque_right = split.y
