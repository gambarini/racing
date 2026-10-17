## Per-surface tire audio + rumble data (#21). Data only; swap the streams for final samples.
class_name SurfaceAudioProfile
extends Resource

@export var surface_id: StringName = &"tarmac"
@export var roll_stream: AudioStream ## loop, level/pitch follow wheel speed
@export var slip_stream: AudioStream ## loop, level follows slip above the threshold
@export var impact_stream: AudioStream ## one-shot on landing
@export var roll_gain := 0.5 ## 0..1 level at roll_speed_ref
@export var roll_speed_ref := 40.0 ## wheel surface speed (m/s) at which pitch/level peak
@export var pitch_min := 0.8 ## pitch scale at standstill
@export var pitch_max := 1.8 ## pitch scale at roll_speed_ref
@export var slip_threshold := 0.08 ## hypot(kappa, alpha): slip loop silent below this
@export var slip_full := 0.25 ## slip at which the loop reaches slip_gain
@export var slip_gain := 0.9
@export var rumble_strong := 0.05 ## low-frequency motor amplitude 0..1 at roll_speed_ref
@export var rumble_weak := 0.03 ## high-frequency motor amplitude 0..1 at roll_speed_ref
@export var rumble_slip_boost := 0.3 ## extra amplitude fraction at full slip
@export var impact_gain := 0.8
