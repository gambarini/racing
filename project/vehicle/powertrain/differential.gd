## Rear-axle differential (#11): splits input torque between the left and right wheel. Pure
## function; T_in == T_L + T_R by construction for every type. Torque is at the wheels (post gear).
class_name Differential
extends RefCounted


## Returns Vector2(T_left, T_right). wl, wr are wheel speeds (rad/s).
static func split(d: PowertrainDefinition, t_in: float, wl: float, wr: float) -> Vector2:
	var half := t_in * 0.5
	var diff := wl - wr
	match d.diff_type:
		PowertrainDefinition.DiffType.LOCKED:
			# Stiff coupling that drags the faster wheel down and the slower one up.
			var x := clampf(d.diff_lock_stiffness * diff, -d.diff_lock_max, d.diff_lock_max)
			return Vector2(half - x, half + x)
		PowertrainDefinition.DiffType.LSD:
			var ratio := d.lsd_power_ratio if t_in >= 0.0 else d.lsd_coast_ratio
			var cap := d.lsd_preload + ratio * absf(t_in)
			var bias := minf(minf(d.diff_lock_stiffness * absf(diff), cap), absf(t_in))
			# Torque bias moves toward the slower wheel; its share never exceeds the input.
			var x := signf(diff) * bias * 0.5
			return Vector2(half - x, half + x)
	return Vector2(half, half)
