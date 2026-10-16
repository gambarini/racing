## Samples InputMap actions each physics tick (120 Hz), filters them and exposes `state`.
## Add as a child node (or autoload); the vehicle reads `state` and pushes `speed_kmh` /
## `rear_slip_deg` into it. No sim state is written back. Deterministic: output depends only on
## the raw input stream, dt and the pushed speed/slip values. Action names only; no hardcoded keys.
## All actions have InputMap deadzone 0; deadzones are applied here (SteeringFilter).
class_name DriverInput
extends Node

const ACTION_LEFT := &"steer_left"
const ACTION_RIGHT := &"steer_right"
const ACTION_THROTTLE := &"throttle"
const ACTION_BRAKE := &"brake"
const ACTION_HANDBRAKE := &"handbrake"

@export_range(0.0, 0.4) var stick_deadzone := SteeringFilter.DEADZONE_DEFAULT
@export_range(1.0, 3.0) var response_gamma := SteeringFilter.GAMMA_DEFAULT
@export var counter_steer_assist := false
## Pedal ramp (1/s) so keyboard W/S feel analog: ~0.14 s up, ~0.1 s down.
@export var pedal_rate_up := 7.0
@export var pedal_rate_down := 10.0

## Pushed by the vehicle each tick.
var speed_kmh := 0.0
var rear_slip_deg := 0.0

var state := DriverInputState.new()
## HUD: true while the assist is limiting the steer command.
var assist_active := false

var _filtered_steer := 0.0


func _physics_process(delta: float) -> void:
	sample_and_step(delta)


## Reads the InputMap and advances the filter one tick.
func sample_and_step(dt: float) -> DriverInputState:
	var raw_steer := Input.get_action_strength(ACTION_RIGHT) - Input.get_action_strength(ACTION_LEFT)
	return step_raw(
		raw_steer,
		Input.get_action_strength(ACTION_THROTTLE),
		Input.get_action_strength(ACTION_BRAKE),
		Input.is_action_pressed(ACTION_HANDBRAKE),
		dt
	)


## Filter one tick from raw values (replay / tests feed this directly).
func step_raw(raw_steer: float, raw_throttle: float, raw_brake: float, raw_handbrake: bool, dt: float) -> DriverInputState:
	var target := SteeringFilter.shape_stick(raw_steer, stick_deadzone, response_gamma)
	_filtered_steer = SteeringFilter.step_steer(_filtered_steer, target, dt, speed_kmh)
	var out := SteeringFilter.counter_steer_assist(_filtered_steer, rear_slip_deg, counter_steer_assist)
	assist_active = out["active"]
	state.steer = out["steer"]
	state.throttle = SteeringFilter.ramp(state.throttle, SteeringFilter.shape_trigger(raw_throttle), dt, pedal_rate_up, pedal_rate_down)
	state.brake = SteeringFilter.ramp(state.brake, SteeringFilter.shape_trigger(raw_brake), dt, pedal_rate_up, pedal_rate_down)
	state.handbrake = raw_handbrake
	return state


func reset() -> void:
	_filtered_steer = 0.0
	state = DriverInputState.new()
	assist_active = false
