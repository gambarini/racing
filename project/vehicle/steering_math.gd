## Pure steering geometry (#82). Angles in rad, + = right turn.
class_name SteeringMath
extends RefCounted


## Returns Vector2(left_wheel, right_wheel) steer angles. The inner wheel (right wheel for
## steer > 0) turns steer * max_angle; the outer follows the ideal Ackermann angle
## atan(L / (L / tan(inner) + T)), blended with the inner angle by `ackermann` (0 = parallel).
static func wheel_angles(steer: float, max_angle: float, ackermann: float, wheelbase: float,
		track: float) -> Vector2:
	var s := clampf(steer, -1.0, 1.0)
	var inner := absf(s) * max_angle
	var outer := inner
	if inner > 1e-6:
		var ideal := atan(wheelbase / (wheelbase / tan(inner) + track))
		outer = lerpf(inner, ideal, clampf(ackermann, 0.0, 1.0))
	if s >= 0.0:
		return Vector2(outer, inner)
	return Vector2(-inner, -outer)
