## Differentials (#11, #26): the axle diff splits torque between the left and right wheel, the
## centre diff (AWD) between the front and rear axle. Pure functions; T_in == sum of outputs by
## construction for every type. Torque is at the wheels (post gear).
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


## Centre differential (#26). Returns Vector2(T_front, T_rear) for input torque t_in. With matched
## axle speeds the front gets `centre_split_front` of it; OPEN keeps that split regardless of grip,
## LOCKED and LSD shift torque toward the slower (gripping) axle. wf, wr are axle speeds (rad/s).
static func centre_split(d: PowertrainDefinition, t_in: float, wf: float, wr: float) -> Vector2:
	var front := t_in * d.centre_split_front
	var rear := t_in - front
	var diff := wf - wr
	var x := 0.0
	match d.centre_diff_type:
		PowertrainDefinition.DiffType.LOCKED:
			x = clampf(d.centre_lock_stiffness * diff, -d.centre_lock_max, d.centre_lock_max)
		PowertrainDefinition.DiffType.LSD:
			var ratio := d.centre_lsd_power_ratio if t_in >= 0.0 else d.centre_lsd_coast_ratio
			var cap := d.centre_lsd_preload + ratio * absf(t_in)
			x = signf(diff) * minf(minf(d.centre_lock_stiffness * absf(diff), cap), absf(t_in))
	return Vector2(front - x, rear + x)
