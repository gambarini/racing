class_name RaceMonitor
extends Node
## Per-tick race supervision for one car (issue #106): steps the LapTimer and the wrong-way
## detector from the vehicle's state, and handles the reset-to-track input. Sim side only; the
## HUD reads `wrong_way` / `resets`. Place it AFTER the vehicle in the tree. When this node
## is present nothing else may step the same LapTimer.
## Reset: car goes to the last valid gate (grid slot 0 area if none), on the centre line,
## facing the tangent, upright, zero linear/angular velocity and wheel spin; the running
## lap gets `reset_penalty` seconds. Works in any attitude (flipped, on its roof).

const ACTION_RESET := &"reset_to_track"
const DROP_HEIGHT := 5.0
const SPAWN_LIFT := 0.3  ## m above the ground so the car settles onto its springs

signal reset_done(gate_index: int)

@export var reset_penalty := 5.0
var vehicle: Vehicle
var track: TrackSpline
var timer: LapTimer
var detector := WrongWayDetector.new()
var resets := 0
var wrong_way: bool:
	get:
		return detector.wrong_way


func setup(p_vehicle: Vehicle, p_track: TrackSpline, p_timer: LapTimer) -> void:
	vehicle = p_vehicle
	track = p_track
	timer = p_timer


func _physics_process(_delta: float) -> void:
	if vehicle == null or track == null:
		return
	step_state()
	if Input.is_action_just_pressed(ACTION_RESET):
		reset_to_track()


func step_state() -> void:
	var pos := vehicle.global_position
	if timer != null:
		timer.step(pos)
	detector.step(vehicle.linear_velocity, track.forward_at(track.nearest_offset(pos)))


func reset_to_track() -> void:
	var gate := 0
	if timer != null:
		gate = maxi(timer.last_gate_crossed, 0)
	var xf := track.reset_transform(gate)
	var q := PhysicsRayQueryParameters3D.create(xf.origin + Vector3.UP * DROP_HEIGHT,
			xf.origin - Vector3.UP * DROP_HEIGHT * 2.0, 0xFFFFFFFF, [vehicle.get_rid()])
	var hit := vehicle.get_world_3d().direct_space_state.intersect_ray(q)
	xf.origin = (hit.position as Vector3 + Vector3.UP * SPAWN_LIFT) if not hit.is_empty() \
			else xf.origin + Vector3.UP * 0.5
	vehicle.global_transform = xf
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	vehicle.reset_dynamics()
	if timer != null:
		timer.add_penalty(reset_penalty)
		timer.teleported()
	detector.reset()
	resets += 1
	reset_done.emit(gate)
