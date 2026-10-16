## Vehicle rigid body with four raycast-suspension wheels (#8). Sim only (CONTRIBUTING sec. 2):
## no meshes, audio or camera. Suspension runs in _physics_process at the fixed 120 Hz tick.
## No tire or drive forces here; `static_hold` is a test stub that pins the car on a slope.
class_name Vehicle
extends RigidBody3D

const WheelScript := preload("res://vehicle/wheel.gd")
const SuspensionMathScript := preload("res://vehicle/suspension_math.gd")
const DEFAULT_DEFINITION := preload("res://vehicle/definitions/reference_car.tres")

@export var definition: VehicleDefinition
@export var arb_enabled := true
## Stub brake: anchors each grounded wheel in the ground plane (friction-capped). See #9/#10.
@export var static_hold := false

var wheels: Array[Wheel] = []
var _exclude: Array[RID] = []
var _g := 9.81


func _ready() -> void:
	if definition == null:
		definition = DEFAULT_DEFINITION
	_g = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.81))
	_apply_definition()
	_build_wheels()
	_exclude = [get_rid()]


func _apply_definition() -> void:
	mass = definition.mass
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = definition.com_position()
	inertia = definition.inertia # explicit tensor, never auto
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
		add_child(w)
		wheels.append(w)


func _physics_process(delta: float) -> void:
	step_suspension(delta)


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
		if static_hold:
			_apply_hold(w, r)


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


## Anchor spring-damper in the ground plane, capped by mu*Fz (static friction stub).
func _apply_hold(w: Wheel, r: Vector3) -> void:
	var n := w.contact_normal
	if not w.hold_valid:
		w.hold_anchor = w.contact_point
		w.hold_valid = true
	var d := w.contact_point - w.hold_anchor
	d -= n * d.dot(n)
	var v := _point_velocity(w.contact_point)
	v -= n * v.dot(n)
	var f := -(definition.hold_stiffness * d + definition.hold_damping * v)
	var cap := definition.hold_friction_mu * w.fz
	if f.length() > cap:
		f = f.normalized() * cap
		w.hold_anchor = w.contact_point + f / definition.hold_stiffness # drag the anchor when slipping
	apply_force(f, r)
