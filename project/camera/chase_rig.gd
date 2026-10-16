class_name ChaseRig
extends RefCounted
## Stateful, node-free chase camera solver (#14). ChaseCamera wraps it; tests drive it directly.

var pos: Vector3
var vel: Vector3
var yaw: float
var yaw_err_vel: float
var fov: float
var fov_vel: float
var look_point: Vector3
var _prev_desired: Vector3
var _primed: bool = false


## Advance by dt. `tvel` is the target velocity (world), `heading` its forward direction.
func step(tpos: Vector3, tvel: Vector3, heading: Vector3, p: CameraProfile, dt: float) -> void:
	var flat := Vector3(tvel.x, 0.0, tvel.z)
	var speed: float = flat.length()
	var h_yaw: float = ChaseMath.yaw_of(Vector3(heading.x, 0.0, heading.z))
	var v_yaw: float = h_yaw if speed < 0.001 else ChaseMath.yaw_of(flat)
	var want: float = ChaseMath.target_yaw(h_yaw, v_yaw, speed, p)
	var fov_want: float = ChaseMath.target_fov(tvel.length(), p)
	if not _primed:
		yaw = want
		fov = fov_want
	else:
		# Smooth the wrapped error towards zero, so +/-PI crossings never step.
		var err: float = -angle_difference(yaw, want)
		var s := ChaseMath.smooth_step(err, yaw_err_vel, 0.0, p.yaw_smooth_time, dt)
		yaw = wrapf(want + s[0], -PI, PI)
		yaw_err_vel = s[1]
		var f := ChaseMath.smooth_step(fov, fov_vel, fov_want, p.fov_smooth_time, dt)
		fov = f[0]
		fov_vel = f[1]
	var behind := Vector3(sin(yaw), 0.0, cos(yaw))
	var desired: Vector3 = tpos + behind * p.distance + Vector3.UP * p.height
	if not _primed:
		pos = desired
		vel = Vector3.ZERO
		_primed = true
	else:
		# Spring goal is where the desired point was at the start of the step, moving at the
		# velocity that carries it to `desired` by the end of the step (velocity feed-forward).
		var dvel: Vector3 = (desired - _prev_desired) / dt
		for i in 3:
			var r := ChaseMath.spring_step(pos[i], vel[i], _prev_desired[i], dvel[i], p.follow_freq, dt)
			pos[i] = r[0]
			vel[i] = r[1]
	_prev_desired = desired
	look_point = tpos + Vector3.UP * p.look_height
