class_name ChaseMath
extends RefCounted
## Pure functions for the chase camera (#14). No nodes, unit-testable.


## Yaw (rad) of a world direction; 0 looks down -Z, positive turns towards -X (Godot Y rotation).
static func yaw_of(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)


## Camera target yaw: heading leaned towards the velocity direction. The lean fades in with speed
## (smoothstep) and fades out for velocity pointing backwards (90..135 deg off heading) so
## reversing keeps the camera behind the car without a snap.
static func target_yaw(heading_yaw: float, vel_yaw: float, speed: float, p: CameraProfile) -> float:
	var s: float = smoothstep(p.blend_speed_min, p.blend_speed_max, speed)
	var diff: float = angle_difference(heading_yaw, vel_yaw)
	var fwd: float = 1.0 - smoothstep(PI * 0.5, PI * 0.75, absf(diff))
	return heading_yaw + diff * p.velocity_blend * s * fwd


## Target FOV (deg) for a speed (m/s), before smoothing.
static func target_fov(speed: float, p: CameraProfile) -> float:
	return lerpf(p.fov_base, p.fov_max, smoothstep(p.fov_speed_min, p.fov_speed_max, speed))


## Exact step of a critically damped spring pulled towards a target moving at constant
## `target_vel` over dt. e = x - target; e(t) = (e0 + (ev0 + w e0) t) exp(-w t). Returns [x, v].
static func spring_step(x: float, v: float, target: float, target_vel: float, freq_hz: float, dt: float) -> PackedFloat64Array:
	var w: float = TAU * freq_hz
	var e0: float = x - target
	var ev0: float = v - target_vel
	var k: float = ev0 + w * e0
	var ex: float = exp(-w * dt)
	var e: float = (e0 + k * dt) * ex
	var ev: float = (ev0 - w * k * dt) * ex
	var out := PackedFloat64Array()
	out.append(target + target_vel * dt + e)
	out.append(target_vel + ev)
	return out


## Exact critically damped smoothing towards a fixed target (time constant ~ smooth_time / 2).
static func smooth_step(x: float, v: float, target: float, smooth_time: float, dt: float) -> PackedFloat64Array:
	return spring_step(x, v, target, 0.0, 2.0 / maxf(smooth_time, 0.0001) / TAU, dt)
