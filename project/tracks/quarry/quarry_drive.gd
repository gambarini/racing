## Car-in-track Quarry scene (#104, reusable by #128/#130/#132): the Quarry, a real Vehicle on grid
## slot `grid_slot` with the Quarry surface map wired in, DriverInput, telemetry recorder + overlay,
## chase camera and a LapTimer built from the track gates.
## Driving: a human via DriverInput (default) or `autopilot` (a QuarryDriver), which writes the
## DriverInput state each tick. The timer is stepped every tick from the car position.
## Headless tests set `autopilot` and `$DriverInput.process_mode = DISABLED` is not needed: the
## autopilot overwrites the state after DriverInput samples (this node runs later).
class_name QuarryDrive
extends Node3D

@export var grid_slot := 0
@export var spawn_lift := 0.35 ## m above the terrain so the car drops onto its springs

var quarry: Quarry
var vehicle: Vehicle
var driver_input: DriverInput
var recorder: TelemetryRecorder
var lap_timer: LapTimer
var autopilot: QuarryDriver ## null = human driving through DriverInput
var offmap_ticks := 0 ## ticks with the car outside the surface map
var grass_ticks := 0 ## ticks with a grounded wheel whose dominant surface is grass


func _ready() -> void:
	process_physics_priority = 10 # after DriverInput (0), before the recorder (100)
	quarry = $Quarry
	vehicle = $Vehicle
	driver_input = $DriverInput
	recorder = $TelemetryRecorder
	vehicle.surface_map = quarry.terrain.surface_map
	lap_timer = quarry.track.make_lap_timer()
	place_on_grid(grid_slot)


## Puts the car on grid slot `slot` (0 = pole), at rest.
func place_on_grid(slot: int) -> void:
	var xf := quarry.track.grid_transform(slot)
	xf.origin.y = quarry.terrain.height_at(xf.origin.x, xf.origin.z) + spawn_lift
	vehicle.global_transform = xf
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	if autopilot != null:
		autopilot.drive(vehicle, driver_input.state, delta)
	vehicle.apply_input(driver_input.state)
	lap_timer.step(vehicle.global_position)
	var p := vehicle.global_position
	var sm := quarry.terrain.surface_map
	if p.x < sm.origin.x or p.z < sm.origin.y or p.x > sm.origin.x + sm.size.x or p.z > sm.origin.y + sm.size.y:
		offmap_ticks += 1
	for w in vehicle.wheels:
		if w.is_grounded and w.surface_id == &"grass":
			grass_ticks += 1
			break
