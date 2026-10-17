## Car-in-track Quarry scene (#104, reusable by #128/#130/#132): the Quarry, a real Vehicle on grid
## slot `grid_slot` with the Quarry surface map wired in, DriverInput, telemetry recorder + overlay,
## chase camera, a LapTimer built from the track gates (flying-lap mode: a lap starts at the first
## line crossing) and a TimeTrial (priority 20, after this node's 10) wired to it for ghost laps.
## Set `$TimeTrial.ghost_path` before adding the scene to the tree to redirect the ghost file.
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
var time_trial: TimeTrial ## ghost recorder/replay (#132); observes the timer after this node steps it
var autopilot: QuarryDriver ## null = human driving through DriverInput
var ai_driver: AiDriver ## #28: racing-line AI; writes the same DriverInput state as a human (null = off)
var ai_debug: AiDriverDebug
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
	time_trial = $TimeTrial
	assert(time_trial.process_physics_priority > process_physics_priority) # observe() needs the timer stepped first
	time_trial.setup(vehicle, lap_timer, "quarry")
	place_on_grid(grid_slot)


## Switches the car to the racing-line AI (#28) and adds its debug draw (F4, hidden by default).
func start_ai(line: RacingLine, telemetry_capacity := 0) -> AiDriver:
	ai_driver = AiDriver.new()
	ai_driver.setup(line, telemetry_capacity)
	ai_debug = AiDriverDebug.new()
	ai_debug.driver = ai_driver
	ai_debug.vehicle = vehicle
	add_child(ai_debug)
	return ai_driver


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
	elif ai_driver != null:
		ai_driver.drive(vehicle, driver_input.state, delta)
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
