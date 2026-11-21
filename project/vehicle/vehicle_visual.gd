## Binds the blockout car glb to a Vehicle by node name (#57). Visual only: it reads Wheel state
## (omega, steer_angle, contact) and never writes to the sim. Add as a child of the Vehicle.
## Axis convention: sim forward is -Z; model nose is +Z; VehicleVisual rotates 180 deg.
## This is the single adapter: only `model_root` is turned (rotation.y = PI). All wheel maths
## below is in the model frame (nose +Z).
class_name VehicleVisual
extends Node3D

const DEFAULT_MODEL := preload("res://vehicle/blockout_car/blockout_car.glb")
const TAGS := ["FL", "FR", "RL", "RR"]

@export var model: PackedScene = DEFAULT_MODEL

var vehicle: Vehicle
var model_root: Node3D
var _wheel_nodes := {} ## tag -> Node3D (spins and, at the front, steers)
var _caliper_nodes := {} ## tag -> Node3D (steers, never spins)
var _spin := {} ## tag -> accumulated angle, rad in [0, TAU)

## Front/back cues (#216), primitives built in model frame (nose +Z). Visual only.
const HEAD_COLOR := Color(1.0, 0.96, 0.78)
const TAIL_COLOR := Color(1.0, 0.05, 0.03)
const STRIPE_COLOR := Color(0.0, 0.85, 1.0)
const HEAD_ENERGY := 3.0
const TAIL_IDLE_ENERGY := 0.8
const TAIL_BRAKE_ENERGY := 4.0 ## 5x idle
const BRAKE_ON := 0.5

var tail_material: StandardMaterial3D
var _braking := false


func _ready() -> void:
	vehicle = get_parent() as Vehicle
	assert(vehicle != null, "VehicleVisual must be a child of a Vehicle")
	model_root = model.instantiate() as Node3D
	model_root.rotation.y = PI
	_strip_hull(model_root)
	add_child(model_root)
	_build_cues()
	for tag in TAGS:
		_wheel_nodes[tag] = model_root.find_child("wheel_" + tag, true, false)
		_caliper_nodes[tag] = model_root.find_child("caliper_" + tag, true, false)
		_spin[tag] = 0.0
		assert(_wheel_nodes[tag] != null and _caliper_nodes[tag] != null, "rig node missing for " + tag)


func _emissive(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


func _cue(node_name: String, size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	model_root.add_child(mi)


## Headlights (white/yellow) at the nose, tail lights (red) at the tail, cyan roof/nose stripe.
func _build_cues() -> void:
	var head := _emissive(HEAD_COLOR, HEAD_ENERGY)
	tail_material = _emissive(TAIL_COLOR, TAIL_IDLE_ENERGY)
	var stripe := _emissive(STRIPE_COLOR, 2.0)
	for sx in [-1.0, 1.0]:
		_cue("Headlight_" + ("L" if sx > 0.0 else "R"), Vector3(0.34, 0.12, 0.06), Vector3(0.55 * sx, 0.65, 2.04), head)
		_cue("Taillight_" + ("L" if sx > 0.0 else "R"), Vector3(0.42, 0.12, 0.06), Vector3(0.55 * sx, 0.7, -2.04), tail_material)
	_cue("NoseStripe", Vector3(0.3, 0.04, 1.2), Vector3(0.0, 1.51, 0.6), stripe)
	_cue("NoseStripeFront", Vector3(0.3, 0.1, 0.06), Vector3(0.0, 0.5, 2.04), stripe)


func _set_brake_lights(on: bool) -> void:
	_braking = on
	tail_material.emission_energy_multiplier = TAIL_BRAKE_ENERGY if on else TAIL_IDLE_ENERGY


## The imported body-convcolonly StaticBody3D is dropped: the Vehicle keeps its own box chassis.
func _strip_hull(root: Node) -> void:
	for n in root.find_children("*", "StaticBody3D", true, false):
		n.get_parent().remove_child(n)
		n.free()


func _process(delta: float) -> void:
	advance(delta)


## Accumulate spin and place every wheel/caliper. Public so tests can drive it deterministically.
func advance(delta: float) -> void:
	var on: bool = vehicle.brake > BRAKE_ON
	if on != _braking:
		_set_brake_lights(on)
	for w in vehicle.wheels:
		var tag := String(w.name).trim_prefix("Wheel")
		if not _wheel_nodes.has(tag):
			continue
		_spin[tag] = fposmod(_spin[tag] + w.omega * delta, TAU)
		var yaw := -w.steer_angle if tag.begins_with("F") else 0.0
		var hub := model_root.to_local(hub_world(w))
		var wn := _wheel_nodes[tag] as Node3D
		wn.transform = Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, _spin[tag]), hub)
		var cn := _caliper_nodes[tag] as Node3D
		cn.transform = Transform3D(Basis(Vector3.UP, yaw), hub)


## World hub centre: contact point + up * radius when grounded, full droop otherwise.
func hub_world(w: Wheel) -> Vector3:
	var up := vehicle.global_transform.basis.y
	if w.is_grounded:
		return w.contact_point + up * w.radius
	return w.global_position - up * w.travel


func spin_angle(tag: String) -> float:
	return _spin[tag]
