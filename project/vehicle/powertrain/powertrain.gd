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
var torque_left := 0.0 ## Nm to the left wheel of the driven axle (rear axle on AWD)
var torque_right := 0.0
var torque_front_left := 0.0 ## Nm to the front wheels; only non-zero on AWD
var torque_front_right := 0.0
var torque_front_axle := 0.0 ## Nm into the front axle (after the centre diff); AWD only
var torque_rear_axle := 0.0
var reflected_inertia := 0.0 ## kg m^2 to add to each driven wheel while locked
var shifts := 0
var driven := PackedInt32Array() ## wheel indices fed by the diffs, cached at construction (per-tick safe)
var _prev_w_drive := 0.0
var silence_misuse_error := false ## TEST ONLY: keeps the expected AWD-misuse error out of CI logs
var _misuse_reported := false
var _inertia_share := 0.5 ## engine inertia is reflected onto n driven wheels: 1/n each


func _init(definition: PowertrainDefinition) -> void:
	def = definition
	engine = EngineModel.new(def)
	gearbox = Gearbox.new(def)
	_inertia_share = 0.25 if def.layout == PowertrainDefinition.Layout.AWD else 0.5
	driven = def.driven_wheels()


func rpm() -> float:
	return engine.rpm()


func gear() -> int:
	return gearbox.gear


## Start from a rolling driveline (scenario harness, #168): pick the forward gear the auto box
## would hold at this driveline speed (upshift while the closed-throttle upshift rpm is reached),
## lock the clutch and put the engine on the driveline speed. `w_mean` = mean driven wheel speed
## (rad/s, > 0). Call before the first step; not for per-tick use.
func sync_to_wheel_speed(w_mean: float) -> void:
	var g := 1
	var n := def.gear_count()
	while g < n and def.total_ratio(g) * w_mean / RPM_TO_RAD >= gearbox.upshift_rpm(0.0):
		g += 1
	gearbox.gear = g
	gearbox.since_shift = 1e9
	gearbox.cut_left = 0.0
	var w_drive := def.total_ratio(g) * w_mean
	rpm_driveline = w_drive / RPM_TO_RAD
	_prev_w_drive = w_drive
	engine.omega = maxf(w_drive, def.idle_rpm * RPM_TO_RAD)
	locked = w_drive >= def.idle_rpm * RPM_TO_RAD


## Slip between engine and driveline in rpm (+ = engine faster).
func clutch_slip_rpm() -> float:
	return engine.rpm() - rpm_driveline


func engine_torque() -> float:
	return engine.torque


## One physics tick. `wl`, `wr` are the driven axle's wheel speeds (rad/s, + = forward): the
## rear axle for RWD, the front axle for FWD, the rear axle for AWD with `wfl`, `wfr` the front.
## `brake` (0..1) and `speed` (signed forward m/s) drive the R/N/1 selection (#108).
## Non-AWD layouts only; AWD cars must use `step_awd` (the front wheel speeds are required there).
## Misuse fallback: on an AWD layout this logs one error and drives the front wheels at the rear
## wheel speeds instead of failing.
func step(dt: float, throttle: float, wl: float, wr: float, brake := 0.0, speed := 0.0) -> void:
	if def.layout == PowertrainDefinition.Layout.AWD:
		# Release-safe guard (asserts are stripped): report once, then fall back to the AWD
		# path with the front wheels assumed to match the rear ones.
		_report_misuse()
		_step(dt, throttle, wl, wr, brake, speed, wl, wr)
		return
	_step(dt, throttle, wl, wr, brake, speed, 0.0, 0.0)


## AWD layout: `wl`, `wr` are the rear wheel speeds, `wfl`, `wfr` the front ones (all required).
func step_awd(dt: float, throttle: float, wl: float, wr: float, wfl: float, wfr: float,
		brake := 0.0, speed := 0.0) -> void:
	assert(def.layout == PowertrainDefinition.Layout.AWD, "step_awd() on a non-AWD powertrain")
	_step(dt, throttle, wl, wr, brake, speed, wfl, wfr)


func _report_misuse() -> void:
	if _misuse_reported:
		return
	_misuse_reported = true
	if not silence_misuse_error:
		push_error("Powertrain.step() called on an AWD layout; use step_awd(). Falling back to front wheels = rear wheels.")


func _step(dt: float, throttle: float, wl: float, wr: float, brake: float, speed: float,
		wfl: float, wfr: float) -> void:
	var awd := def.layout == PowertrainDefinition.Layout.AWD
	# Driveline speed: the mean of the driven wheels (all four on AWD).
	var w_mean := 0.25 * (wl + wr + wfl + wfr) if awd else 0.5 * (wl + wr)
	if gearbox.select(dt, throttle, brake, speed):
		locked = false
	var ratio := gearbox.total_ratio()
	var w_drive := ratio * w_mean
	rpm_driveline = w_drive / RPM_TO_RAD
	# Upshift on engine speed (wheelspin must not trigger it); equal to driveline speed when locked.
	var dir := gearbox.update(dt, engine.rpm(), rpm_driveline, throttle)
	if dir != 0:
		locked = false
		shifts += 1
		ratio = gearbox.total_ratio()
		w_drive = ratio * w_mean
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
			reflected_inertia = ie * ratio * ratio * _inertia_share
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
				reflected_inertia = ie * ratio * ratio * _inertia_share
		# Numerical damping: while the clutch bites, keep part of the engine inertia on the wheels.
		# A bare 1.2 kg m^2 wheel handed a slipping-clutch torque outruns the tire's relaxation and
		# burns out; scaling by engagement keeps an open clutch (shifts, idle) free.
		if not locked:
			reflected_inertia = def.clutch_slip_inertia_share * ie * ratio * ratio * _inertia_share * engagement
		engine.omega = w_new
	clutch_torque = tc
	_prev_w_drive = w_drive
	var t_axle := tc * ratio
	if awd:
		var c := Differential.centre_split(def, t_axle, 0.5 * (wfl + wfr), 0.5 * (wl + wr))
		torque_front_axle = c.x
		torque_rear_axle = c.y
		var sf := Differential.split(def, c.x, wfl, wfr)
		torque_front_left = sf.x
		torque_front_right = sf.y
		var sr := Differential.split(def, c.y, wl, wr)
		torque_left = sr.x
		torque_right = sr.y
	else:
		var split := Differential.split(def, t_axle, wl, wr)
		torque_left = split.x
		torque_right = split.y
