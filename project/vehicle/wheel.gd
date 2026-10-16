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
var surface_id: StringName = &"tarmac"
var hit_distance := INF ## mount-to-ground along the ray (>= radius means hub clear of chassis)

# Spin state (#10). omega is integrated only by Vehicle._physics_process via WheelSpin.
var omega := 0.0 ## rad/s, + = rolling forward
var kappa := 0.0 ## slip ratio fed to the tire model (relaxed)
var alpha := 0.0 ## rad, slip angle fed to the tire model (relaxed)
var steer_angle := 0.0 ## rad, + = right turn (written by #82, read by VehicleVisual)
var fy := 0.0 ## N, lateral tire force actually applied (after the stop limiter)
var fx := 0.0 ## N, longitudinal tire force actually applied (after the stop limiter)
var drive_torque := 0.0 ## Nm input from the powertrain (#11), + = forward
var brake_torque := 0.0 ## Nm input, magnitude >= 0
var handbrake_gain := 0.0 ## 1 on rear wheels, 0 on front
var anchored := false ## static-friction stage (#85) is holding this wheel at `anchor`
var anchor := Vector3.ZERO ## world contact point latched when the wheel came to rest

var radius := 0.32
var travel := 0.2


## Ray from the mount down the body's -Y axis; fills the contact fields except forces.
func probe(space: PhysicsDirectSpaceState3D, exclude: Array[RID], body_down: Vector3) -> void:
	var from := global_position
	var q := PhysicsRayQueryParameters3D.create(from, from + body_down * (travel + radius), 1, exclude)
	var hit := space.intersect_ray(q)
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
	surface_id = surface_id_of(hit.collider)


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
