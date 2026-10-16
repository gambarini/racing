class_name ChaseCamera
extends Camera3D
## Chase camera (#14). Follows `target`; all maths lives in ChaseRig / ChaseMath.

@export var target: Node3D
@export var profile: CameraProfile = preload("res://camera/chase_near.tres")

var rig := ChaseRig.new()
var _last_target_pos: Vector3
var _have_last: bool = false


func _process(delta: float) -> void:
	advance(delta)


## Public so headless checks can step with their own dt.
func advance(dt: float) -> void:
	if target == null or profile == null or dt <= 0.0:
		return
	var tpos: Vector3 = target.global_position
	var tvel := Vector3.ZERO
	if target is RigidBody3D:
		tvel = (target as RigidBody3D).linear_velocity
	elif _have_last:
		tvel = (tpos - _last_target_pos) / dt
	_last_target_pos = tpos
	_have_last = true
	rig.step(tpos, tvel, -target.global_basis.z, profile, dt)
	global_position = rig.pos
	fov = rig.fov
	if rig.look_point.distance_squared_to(rig.pos) > 0.0001:
		look_at(rig.look_point, Vector3.UP)
