class_name CameraProfile
extends Resource
## Tunables for the chase camera (#14). Read every frame, so edits at runtime apply next frame.
## SI units; FOV in degrees.

## Horizontal distance behind the target (m).
@export_range(1.0, 30.0, 0.1) var distance: float = 6.0
## Camera height above the target origin (m).
@export_range(0.0, 15.0, 0.1) var height: float = 2.2
## Height above the target origin that the camera looks at (m).
@export_range(0.0, 5.0, 0.1) var look_height: float = 1.2
## Position spring natural frequency (Hz); critically damped.
@export_range(0.5, 30.0, 0.1) var follow_freq: float = 5.0
## Smoothing time of the camera yaw towards its target yaw (s).
@export_range(0.01, 2.0, 0.01) var yaw_smooth_time: float = 0.25
## Max share (0..1) of the way the camera yaw leans from heading to velocity direction.
@export_range(0.0, 1.0, 0.01) var velocity_blend: float = 0.6
## Below this speed the camera follows heading only (m/s).
@export_range(0.0, 50.0, 0.1) var blend_speed_min: float = 3.0
## At and above this speed the full velocity_blend applies (m/s).
@export_range(0.0, 100.0, 0.1) var blend_speed_max: float = 10.0
## FOV at standstill (deg).
@export_range(20.0, 120.0, 0.5) var fov_base: float = 70.0
## FOV at high speed (deg).
@export_range(20.0, 120.0, 0.5) var fov_max: float = 85.0
## Speed where FOV starts to widen (m/s).
@export_range(0.0, 100.0, 0.5) var fov_speed_min: float = 10.0
## Speed where FOV reaches fov_max (m/s).
@export_range(0.0, 200.0, 0.5) var fov_speed_max: float = 60.0
## Smoothing time of the FOV (s).
@export_range(0.01, 2.0, 0.01) var fov_smooth_time: float = 0.3
