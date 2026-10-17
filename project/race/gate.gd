class_name Gate
extends RefCounted
## One timing gate: a vertical plane through `position` facing `forward`, `half_width` wide
## (lateral) and unbounded in height. Pure data plus a segment-crossing query (issue #105).

var position := Vector3.ZERO
var forward := Vector3(0, 0, -1)  ## unit, horizontal; the required crossing direction
var half_width := 8.0


func _init(p_position := Vector3.ZERO, p_forward := Vector3(0, 0, -1), p_half_width := 8.0) -> void:
	position = p_position
	forward = Vector3(p_forward.x, 0.0, p_forward.z).normalized()
	half_width = p_half_width


## True when the segment a->b crosses the gate plane in the forward direction within the width.
func crossed_by(a: Vector3, b: Vector3) -> bool:
	var da := (a - position).dot(forward)
	var db := (b - position).dot(forward)
	if not (da < 0.0 and db >= 0.0):
		return false
	var t := da / (da - db)
	var hit := a.lerp(b, t) - position
	var right := forward.cross(Vector3.UP)
	return absf(hit.dot(right)) <= half_width
