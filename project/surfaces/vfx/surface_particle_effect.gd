## Per-surface particle effect parameters (#20). Data only; the emitter is built from this by
## VehicleVfx. Rate at full intensity is max_amount / lifetime particles per second.
class_name SurfaceParticleEffect
extends Resource

@export var kind: StringName = &"dust" ## dust | roost | mud | splash | smoke
@export var max_amount := 40 ## particles alive at full intensity, per wheel
@export var lifetime := 1.0 ## s
@export var roll_rate := 0.0 ## 0..1 share of full intensity emitted just by rolling (no slip)
@export var color := Color(0.7, 0.6, 0.45, 0.5)
@export var size := 0.3 ## m, start scale
@export var launch_speed := 1.5 ## m/s initial velocity magnitude
@export var upward_bias := 0.4 ## 0..1 how much of the launch is vertical
@export var gravity := -2.0 ## m/s^2 along Y (negative = falls)
