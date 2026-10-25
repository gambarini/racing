## Test support (#30): drives a field of AiDriver cars each physics tick under a RaceManager that is
## stepped from the cars' own buffers (the manager's own process is disabled). Records the largest
## distance from the road centre per car and the number of car-car contacts.
extends Node

const HALF_W := 0.85 ## chassis_size.x / 2
const HALF_L := 1.7 ## chassis_size.z / 2

var vehicles: Array[Vehicle] = []
var drivers: Array[AiDriver] = []
var states: Array[DriverInputState] = []
var pos := PackedVector3Array()
var spd := PackedFloat32Array()
var mgr: RaceManager
var max_centre := PackedFloat32Array()
var contacts := 0
var _touching := PackedByteArray()


func _init() -> void:
	process_physics_priority = 20 # after the vehicles' own physics and the scene's driver


func _physics_process(delta: float) -> void:
	if max_centre.size() != vehicles.size():
		max_centre.resize(vehicles.size())
		_touching.resize(vehicles.size() * vehicles.size())
	for i in vehicles.size():
		pos[i] = vehicles[i].global_position
		spd[i] = vehicles[i].linear_velocity.length()
	mgr.step(pos, spd)
	for i in vehicles.size():
		drivers[i].drive(vehicles[i], states[i], delta)
		mgr.gate_input(states[i])
		vehicles[i].apply_input(states[i])
		max_centre[i] = maxf(max_centre[i], absf(mgr.lateral[i]))
	for i in vehicles.size():
		for j in range(i + 1, vehicles.size()):
			var k := i * vehicles.size() + j
			var hit := _clearance(vehicles[i], vehicles[j]) <= 0.0
			if hit and _touching[k] == 0:
				contacts += 1
			_touching[k] = 1 if hit else 0


static func _clearance(a: Vehicle, b: Vehicle) -> float:
	var rel := a.global_transform.affine_inverse() * b.global_position
	var rb := a.global_transform.basis.inverse() * b.global_transform.basis
	var ex := HALF_W * absf(rb.x.x) + HALF_L * absf(rb.z.x)
	var ez := HALF_W * absf(rb.x.z) + HALF_L * absf(rb.z.z)
	return maxf(absf(rel.x) - (HALF_W + ex), absf(rel.z) - (HALF_L + ez))
