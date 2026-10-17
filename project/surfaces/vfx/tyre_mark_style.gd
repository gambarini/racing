## Per-surface tyre mark style (#20). A mark is laid only while the wheel slip exceeds one of
## the thresholds. Data only.
class_name TyreMarkStyle
extends Resource

@export var slip_ratio_threshold := 0.15 ## |kappa| above this lays a mark
@export var slip_angle_threshold := 0.15 ## |alpha| (rad) above this lays a mark
@export var width := 0.22 ## m
@export var color := Color(0.05, 0.05, 0.05, 0.6)
