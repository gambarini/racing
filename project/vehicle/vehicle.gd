## Vehicle rigid body with four raycast-suspension wheels (#8). Sim only (CONTRIBUTING sec. 2):
## no meshes, audio or camera. Suspension runs in _physics_process at the fixed 120 Hz tick.
## Tire forces (#9 combined slip, #10 wheel spin, #74 lateral Fy) act on the body at the contact
## patches; the old `static_hold` stub is gone. A parked car holds on a slope via brake torque.
## Axis convention: sim forward is -Z; model nose is +Z; VehicleVisual rotates 180 deg.
class_name Vehicle
extends RigidBody3D

const WheelScript := preload("res://vehicle/wheel.gd")
const SuspensionMathScript := preload("res://vehicle/suspension_math.gd")
const DEFAULT_DEFINITION := preload("res://vehicle/definitions/reference_car.tres")

@export var definition: VehicleDefinition
@export var arb_enabled := true
## Apply tire forces (Fx and Fy) to the body. Tests that emulate their own ground reaction turn
## this off; omega still integrates (reaction torque uses the same Fx).
@export var tire_forces_enabled := true
@export var handbrake := false
## Driver commands (set by apply_input; #11 powertrain reads `throttle`).
var steer := 0.0 ## -1..1, + = right
var throttle := 0.0 ## 0..1
var brake := 0.0 ## 0..1
@export var tire_params: TireParams
var wheels: Array[Wheel] = []
var _exclude: Array[RID] = []
var _g := 9.81
var _surface_tires := {} ## surface id -> TireParams derived from _surface_base
var _surface_base: TireParams


func _ready() -> void:
	if definition == null:
		definition = DEFAULT_DEFINITION
	_g = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.81))
	_apply_definition()
	_build_wheels()
	_exclude = [get_rid()]


## Copies a DriverInputState into the vehicle (clamped) and sets steer angles and brake torques.
func apply_input(input: DriverInputState) -> void:
	steer = clampf(input.steer, -1.0, 1.0)
	throttle = clampf(input.throttle, 0.0, 1.0)
	brake = clampf(input.brake, 0.0, 1.0)
	handbrake = input.handbrake
	var d := definition if definition != null else DEFAULT_DEFINITION
	if wheels.size() < 4:
		return
	var angles := SteeringMath.wheel_angles(steer, deg_to_rad(d.max_steer_angle), d.ackermann_factor,
			d.wheelbase, d.track)
	wheels[0].steer_angle = angles.x
	wheels[1].steer_angle = angles.y
	wheels[2].steer_angle = 0.0
	wheels[3].steer_angle = 0.0
	for i in 4:
		wheels[i].brake_torque = brake * (d.brake_torque_front if i < 2 else d.brake_torque_rear)


func _apply_definition() -> void:
	mass = definition.mass
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = definition.com_position()
	inertia = definition.inertia # explicit tensor, never auto
	# No engine-side linear damping: the default 0.1 /s is a hidden ~2 m/s^2 drag at 20 m/s that
	# swamps rolling resistance (#12). All speed-dependent drag lives in the sim (surfaces, aero).
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	can_sleep = false # the suspension keeps feeding forces; sleeping would freeze the ride
	if find_child("Chassis", false, false) == null:
		var box := BoxShape3D.new()
		box.size = definition.chassis_size
		var cs := CollisionShape3D.new()
		cs.name = "Chassis"
		cs.shape = box
		cs.position = Vector3(0.0, definition.chassis_bottom + box.size.y * 0.5, 0.0)
		add_child(cs)


func _build_wheels() -> void:
	var names := ["FL", "FR", "RL", "RR"]
	for i in 4:
		var w: Wheel = WheelScript.new()
		w.name = "Wheel" + names[i]
		w.position = definition.mount_position(i, _g)
		w.radius = definition.wheel_radius
		w.travel = definition.travel
		w.handbrake_gain = 1.0 if i >= 2 else 0.0
		add_child(w)
		wheels.append(w)


func _physics_process(delta: float) -> void:
	step_suspension(delta)
	step_wheels(delta)


## Integrate wheel spin and (optionally) apply tire forces Fx, Fy. Fixed tick only.
func step_wheels(delta: float) -> void:
	if tire_params == null:
		tire_params = TireParams.new()
	var d := definition
	var wheel_mass := mass * 0.25 # a quarter of the mass per wheel
	if _surface_base != tire_params:
		_surface_base = tire_params
		_surface_tires.clear()
	for w in wheels:
		var surf := SurfaceRegistry.get_surface(w.surface_id)
		var tp := _tire_for(w.surface_id, surf)
		var fx_body := 0.0
		var fy_body := 0.0
		var fwd := Vector3.ZERO
		var vel := Vector3.ZERO
		var right := Vector3.ZERO
		var brake := w.brake_torque + (d.handbrake_torque * w.handbrake_gain if handbrake else 0.0)
		if w.is_grounded:
			var n := w.contact_normal
			fwd = -global_transform.basis.z
			fwd = (fwd - n * fwd.dot(n)).normalized()
			# Steered wheel: rotate the forward axis about the normal (+ steer_angle = right turn,
			# which is a negative rotation about +Y).
			fwd = fwd.rotated(n, -w.steer_angle)
			right = fwd.cross(n).normalized()
			vel = _point_velocity(w.contact_point)
			var vx := vel.dot(fwd)
			var vy := vel.dot(right)
			var target := TireModel.slip_ratio(w.omega, w.radius, vx, tp)
			w.kappa = TireModel.relax(w.kappa, target, vx, delta, tp)
			var target_a := TireModel.slip_angle(vx, vy, tp)
			w.alpha = TireModel.relax(w.alpha, target_a, vx, delta, tp)
			# Gravity's slope components: part of what the tire must cancel to hold/stop the car.
			var gv := Vector3.DOWN * _g * wheel_mass
			var push_x := gv.dot(fwd)
			var push_y := gv.dot(right)
			var f0 := TireModel.compute(w.kappa, w.alpha, w.fz, tp)
			var sl := WheelSpin.fx_slopes(w.kappa, w.omega, vx, w.fz, w.radius, vx, delta,
					tp, w.alpha)
			fx_body = WheelSpin.implicit_fx(f0.x, sl.x, sl.y, w.drive_torque, w.radius,
					d.wheel_inertia, wheel_mass, delta, push_x)
			# A braked wheel that stays locked cannot spin up, so its slope must not soften the
			# force (otherwise a parked car creeps); re-solve with a rigid wheel.
			if brake > 0.0 and WheelSpin.step(w.omega, w.drive_torque, brake, fx_body, w.radius,
					d.wheel_inertia, delta) == 0.0:
				fx_body = WheelSpin.implicit_fx(f0.x, 0.0, sl.y, w.drive_torque, w.radius,
						d.wheel_inertia, wheel_mass, delta, push_x)
			var sy := WheelSpin.fy_slope(w.kappa, w.alpha, vx, vy, w.fz, delta, tp)
			fy_body = WheelSpin.implicit_fy(f0.y, sy, wheel_mass, delta, push_y)
			# Grip must not reverse the car within a tick.
			fx_body = TireModel.limit_to_stop(fx_body, vx, wheel_mass, delta, push_x)
			fy_body = TireModel.limit_to_stop(fy_body, vy, wheel_mass, delta, push_y)
			w.omega = WheelSpin.step(w.omega, w.drive_torque, brake, fx_body, w.radius,
					d.wheel_inertia, delta)
		else:
			w.kappa = 0.0
			w.alpha = 0.0
			w.omega = WheelSpin.step(w.omega, w.drive_torque, brake, 0.0, w.radius,
					d.wheel_inertia, delta)
		w.fx = fx_body
		w.fy = fy_body
		if tire_forces_enabled and w.is_grounded:
			apply_force(fwd * fx_body + right * fy_body, w.contact_point - global_position)
			_apply_resistance(w, surf, vel, wheel_mass, delta)


## Tire parameters for a surface id, derived once per (base tire, surface) and cached.
func _tire_for(id: StringName, surf: SurfaceDefinition) -> TireParams:
	if not _surface_tires.has(id):
		_surface_tires[id] = TireParams.for_surface(tire_params, surf)
	return _surface_tires[id]


## Rolling resistance and deformation drag (#12): a force against the contact-point velocity in
## the ground plane, F = Fz * (Crr + k v^2), capped so it cannot reverse the motion in one tick.
func _apply_resistance(w: Wheel, surf: SurfaceDefinition, vel: Vector3, wheel_mass: float, delta: float) -> void:
	var vt := vel - w.contact_normal * vel.dot(w.contact_normal)
	var speed := vt.length()
	if speed < 1e-4:
		return
	var f := minf(surf.resistance_force(w.fz, speed), wheel_mass * speed / delta)
	apply_force(-vt / speed * f, w.contact_point - global_position)


## Probe, compute and apply all suspension forces for one tick.
func step_suspension(_delta: float) -> void:
	var space := get_world_3d().direct_space_state
	var up := global_transform.basis.y
	for w in wheels:
		w.probe(space, _exclude, -up)
		if w.is_grounded:
			# Ground is static: compression rate = mount velocity toward the ground.
			w.compression_rate = _point_velocity(w.global_position).dot(-up)
	_compute_forces()
	for w in wheels:
		if not w.is_grounded:
			continue
		var r := w.contact_point - global_position
		# Fz is the contact-patch normal load, so it acts along the surface normal (no spurious
		# lateral force when the body pitches or rolls on flat ground).
		apply_force(w.contact_normal * w.fz, r)


func _compute_forces() -> void:
	var d := definition
	for axle in 2:
		var l: Wheel = wheels[axle * 2]
		var r: Wheel = wheels[axle * 2 + 1]
		var k_arb := (d.arb_front if axle == 0 else d.arb_rear) if arb_enabled else 0.0
		var arb := SuspensionMathScript.arb_force(l.compression, r.compression, k_arb)
		for pair in [[l, arb], [r, -arb]]:
			var w: Wheel = pair[0]
			if not w.is_grounded:
				continue
			w.fz = SuspensionMathScript.total_force(w.compression, w.compression_rate,
					d.spring_rate, d.damper_bump, d.damper_rebound, d.travel,
					d.bump_stop_zone, d.bump_stop_rate, pair[1])


## Velocity of the body at a world point (linear_velocity is the CoM velocity).
func _point_velocity(world_point: Vector3) -> Vector3:
	var com_world := global_position + global_transform.basis * center_of_mass
	return linear_velocity + angular_velocity.cross(world_point - com_world)
