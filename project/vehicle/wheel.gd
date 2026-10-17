## One raycast wheel: probes the ground and exposes per-wheel contact data (for #9, #10, #15).
## Sim only: no meshes, audio or camera. Probing uses the physics space directly (deterministic).
class_name Wheel
extends Node3D

var is_grounded := false
var contact_point := Vector3.ZERO ## world
var contact_normal := Vector3.UP
var compression := 0.0 ## m, 0 = full droop
var compression_rate := 0.0 ## m/s, + = compressing
var fz := 0.0 ## N, force along the suspension axis
var surface_id: StringName = &"tarmac" ## dominant surface (largest weight)
# Surface weights (#19, #158): weights[k] belongs to weight_ids[k] for k < weight_count; sums to 1.
# Caller-owned buffers rewritten in place every probe (SurfaceMap.sample_into): no per-tick allocation.
var weight_ids: Array[StringName] = [&"tarmac"] ## the SurfaceMap's ids, or _single_ids
var weights := PackedFloat32Array([1.0])
var weight_count := 1
var blend_def: SurfaceDefinition ## per-wheel scratch for SurfaceBlend.blend_into
var blend_tire: TireParams ## per-wheel scratch for blended tire params
var _single_ids: Array[StringName] = [&"tarmac"]
## Dictionary view {id: weight} of the positive weights, for tests/tools (allocates; not for ticks).
var surface_weights: Dictionary:
	get:
		var d := {}
		for k in weight_count:
			if weights[k] > 0.0:
				d[weight_ids[k]] = weights[k]
		return d
	set(v):
		var ids: Array[StringName] = []
		weights.resize(maxi(v.size(), 1))
		for k in v:
			weights[ids.size()] = v[k]
			ids.append(k)
		weight_ids = ids
		weight_count = ids.size()
var hit_distance := INF ## mount-to-ground along the ray (>= radius means hub clear of chassis)

# Spin state (#10). omega is integrated only by Vehicle._physics_process via WheelSpin.
var omega := 0.0 ## rad/s, + = rolling forward
var kappa := 0.0 ## slip ratio fed to the tire model (relaxed)
var alpha := 0.0 ## rad, slip angle fed to the tire model (relaxed)
var steer_angle := 0.0 ## rad, + = right turn (written by #82, read by VehicleVisual)
var fy := 0.0 ## N, lateral tire force actually applied (after the stop limiter)
var fx := 0.0 ## N, longitudinal tire force actually applied (after the stop limiter)
var drive_torque := 0.0 ## Nm input from the powertrain (#11), + = forward
var extra_inertia := 0.0 ## kg m^2 reflected onto this wheel by a locked clutch (#11)
var brake_torque := 0.0 ## Nm input, magnitude >= 0
var handbrake_gain := 0.0 ## 1 on rear wheels, 0 on front
var anchored := false ## static-friction stage (#85) is holding this wheel at `anchor`
var anchor := Vector3.ZERO ## world contact point latched when the wheel came to rest

var radius := 0.32
var travel := 0.2

var _query: PhysicsRayQueryParameters3D ## reused every tick (no per-tick allocation, #116)


## Ray from the mount down the body's -Y axis; fills the contact fields except forces.
func probe(space: PhysicsDirectSpaceState3D, exclude: Array[RID], body_down: Vector3,
		surface_map: SurfaceMap = null) -> void:
	var from := global_position
	if _query == null:
		_query = PhysicsRayQueryParameters3D.create(from, from, 1, exclude)
	_query.from = from
	_query.to = from + body_down * (travel + radius)
	_query.exclude = exclude
	var hit := space.intersect_ray(_query)
	if hit.is_empty():
		is_grounded = false
		compression = 0.0
		compression_rate = 0.0
		hit_distance = INF
		fz = 0.0
		return
	is_grounded = true
	contact_point = hit.position
	contact_normal = hit.normal
	hit_distance = from.distance_to(hit.position)
	compression = clampf(travel - (hit_distance - radius), 0.0, travel)
	var collider_id := surface_id_of(hit.collider)
	if surface_map != null and surface_map.sample_into(contact_point.x, contact_point.z, weights):
		weight_ids = surface_map.ids
		weight_count = surface_map.ids.size()
	else:
		_single_ids[0] = collider_id if collider_id != &"" else SurfaceBlend.FALLBACK_ID
		weight_ids = _single_ids
		weight_count = 1
		weights[0] = 1.0
	surface_id = SurfaceBlend.dominant_of(weight_ids, weights, weight_count)


## Weight of surface `id` on this wheel (0 if absent).
func weight_of(id: StringName) -> float:
	var t := 0.0
	for k in weight_count:
		if weight_ids[k] == id:
			t += weights[k]
	return t


## Surface id of a collider: metadata `surface_id` first, then a group `surface_<id>`, else tarmac.
static func surface_id_of(col: Object) -> StringName:
	if col == null:
		return &"tarmac"
	if col.has_meta(&"surface_id"):
		return StringName(str(col.get_meta(&"surface_id")))
	if col is Node:
		for g in (col as Node).get_groups():
			var s := String(g)
			if s.begins_with("surface_") and s.length() > 8:
				return StringName(s.substr(8))
	return &"tarmac"
