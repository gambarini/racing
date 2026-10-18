## Scenario launch entry (#168): with `initial_speed` set the car starts on its springs (both spawn
## paths: marker and forward_offset), with the powertrain synced to the rolling wheels. Checks Fz on
## every wheel from tick 1, the landing-load bound, gear/rpm at tick 1 and the drive torque and slip
## ratio during a throttle-0 straight at 18 m/s.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/scenario_entry_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")
const SPEED := 18.0
const GROUND_Y := 0.0 ## Proving Ground flat ground height
const LOAD_BOUND := 1.5 ## x static per-wheel load (estimate)
const TORQUE_BOUND := 200.0 ## Nm, first 0.5 s
const RIDE_TOL := 0.02 ## m

var cu := CheckUtil.new()
var _min_fz := 1e9
var _max_fz := 0.0
var _y1 := 0.0
var _gear1 := 0
var _rpm1 := 0.0
var _max_torque := 0.0
var _max_kappa := 0.0
var _kappa_peak := 0.1


func _initialize() -> void:
	_main()


func _sample(tick: int, v: Vehicle, _st: DriverInputState) -> void:
	if tick < 1:
		return
	if tick == 1:
		_y1 = v.global_position.y
		_gear1 = v.gear()
		_rpm1 = v.rpm()
	for w in v.wheels:
		_min_fz = minf(_min_fz, w.fz)
		if tick <= 120:
			_max_fz = maxf(_max_fz, w.fz)
		if tick <= 60:
			_max_torque = maxf(_max_torque, absf(w.drive_torque))
	for i in [2, 3]:
		_max_kappa = maxf(_max_kappa, absf(v.wheels[i].kappa))


func _run(label: String, spawn: String, offset: float, ticks: int) -> void:
	_min_fz = 1e9
	_max_fz = 0.0
	_max_torque = 0.0
	_max_kappa = 0.0
	var sc := Scenario.new(self, spawn, [], ticks)
	sc.initial_speed = SPEED
	sc.forward_offset = offset
	sc.controller = _sample
	var res: Dictionary = await sc.run()
	var def: VehicleDefinition = load("res://vehicle/definitions/reference_car.tres")
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.81))
	var static_max := maxf(def.static_wheel_load(true, g), def.static_wheel_load(false, g))
	print("%s: y(t1) %.4f m, min Fz %.0f N, max Fz(1 s) %.0f N (static max %.0f), gear@1 %d, rpm@1 %.0f, max |torque| 0.5 s %.1f Nm, max |kappa| rear %.4f"
			% [label, _y1, _min_fz, _max_fz, static_max, _gear1, _rpm1, _max_torque, _max_kappa])
	cu.check_range(label + " body height above ground at tick 1 (m)", _y1 - GROUND_Y, -RIDE_TOL, RIDE_TOL)
	cu.check(_min_fz > 0.0, label + ": every wheel Fz > 0 from tick 1 (min %.0f N)" % _min_fz)
	cu.check_range(label + " max wheel Fz over 1 s / static", _max_fz / static_max, 0.0, LOAD_BOUND)
	cu.check_range(label + " max |drive torque| 0.5 s (Nm)", _max_torque, 0.0, TORQUE_BOUND)
	cu.check_range(label + " max rear |kappa| / kappa_peak", _max_kappa / _kappa_peak, 0.0, 1.0)
	# Gear the auto box holds at this speed; rpm matches the driveline.
	var pt := Powertrain.new(load("res://vehicle/definitions/reference_powertrain.tres"))
	pt.sync_to_wheel_speed(SPEED / def.wheel_radius)
	cu.check(_gear1 == pt.gear() and _gear1 > 1, label + ": gear at tick 1 = %d (box holds %d)" % [_gear1, pt.gear()])
	cu.check_range(label + " rpm at tick 1 vs driveline (rpm)", absf(_rpm1 - pt.rpm_driveline), 0.0, 100.0)
	cu.check(res.speed[res.speed.size() - 1] > SPEED - 2.0, label + ": still rolling")


func _main() -> void:
	await physics_frame
	_kappa_peak = TireParams.new().kappa_peak
	await _run("marker", "Spawn_Flat", 0.0, 120)
	await _run("offset", "Spawn_Flat", 20.0, 120)
	cu.finish(self)
