class_name TrackSpline
extends Node3D
## Track centre line, ordered timing gates (>= 8, 3 sectors), start grid and joker gate
## (issue #105). Gates are placed by distance along the closed `centre_line`; gate 0 is
## start/finish. World forward is -Z; the curve must be authored in driving direction.

@export var centre_line: Curve3D
## Distances (m) along the centre line, strictly ascending, first = start/finish.
@export var gate_offsets: PackedFloat32Array = PackedFloat32Array()
## Gate indices ending sector 1 and sector 2 (the last sector ends at the finish line).
@export var sector_end_gates: Array[int] = [3, 6]
@export var gate_half_width := 8.0
## Joker gate: local position and direction on the joker route; optional.
@export var has_joker := false
@export var joker_position := Vector3.ZERO
@export var joker_forward := Vector3(0, 0, -1)
@export var joker_half_width := 4.0
## Road edge for track limits (#174): half-width of the paved road about the centre line (m), 0 =
## no limits. `half_profile` (optional) gives the half-width per `half_profile_step` m along the
## closed line (linear, wrapped), for tracks with widened sections. `joker_curve` (optional) is the
## centre line of the joker detour, legal ground out to `joker_road_half`.
@export var road_half_width := 0.0
@export var half_profile: PackedFloat32Array = PackedFloat32Array()
@export var half_profile_step := 1.0
@export var joker_curve: Curve3D
@export var joker_road_half := 0.0
@export var grid_slots := 8
@export var grid_spacing := 8.0  ## along the line, behind the start line
@export var grid_lateral := 2.5  ## +/- from the centre line, alternating


func gate_count() -> int:
	return gate_offsets.size()


func sector_count() -> int:
	return sector_end_gates.size() + 1


func is_valid() -> bool:
	if centre_line == null or centre_line.point_count < 2 or gate_offsets.size() < 8 or sector_count() != 3:
		return false
	for i in range(1, gate_offsets.size()):
		if gate_offsets[i] <= gate_offsets[i - 1]:
			return false
	for g in sector_end_gates:
		if g < 1 or g >= gate_offsets.size():
			return false
	return true


func length() -> float:
	return centre_line.get_baked_length() if centre_line else 0.0


## World position and unit horizontal tangent at distance `d` along the (wrapped) closed line.
func sample(d: float) -> Dictionary:
	return {"position": position_at(d), "forward": forward_at(d)}


## World position of the centre line at distance `d` (wrapped). Allocation-free.
func position_at(d: float) -> Vector3:
	return global_transform * centre_line.sample_baked(fposmod(d, length()))


## World-space horizontal unit tangent at distance `d` (wrapped). Allocation-free, so per-tick
## callers use this instead of `sample()`, which builds a Dictionary.
func forward_at(d: float) -> Vector3:
	var l := length()
	var o := fposmod(d, l)
	var p := centre_line.sample_baked(o)
	var q := centre_line.sample_baked(fposmod(o + 0.5, l))
	var t := Vector3(q.x - p.x, 0.0, q.z - p.z).normalized()
	return (global_transform.basis * t).normalized()


## Road half-width (m) at distance `d` along the line. Allocation-free.
func road_half_at(d: float) -> float:
	var n := half_profile.size()
	if n < 2:
		return road_half_width
	var u := fposmod(d, length()) / half_profile_step
	var i := int(u)
	return lerpf(half_profile[i % n], half_profile[(i + 1) % n], u - floorf(u))


## True when world position `pos` (a wheel) lies beyond the road edge: horizontal distance to the
## centre line above the half-width there, and not on the joker detour. Always false when
## `road_half_width` is 0. Allocation-free.
func is_off_road(pos: Vector3) -> bool:
	if road_half_width <= 0.0:
		return false
	var s := nearest_offset(pos)
	var c := position_at(s)
	var dx := pos.x - c.x
	var dz := pos.z - c.z
	var h := road_half_at(s)
	if dx * dx + dz * dz <= h * h:
		return false
	if joker_curve != null:
		var local := global_transform.affine_inverse() * pos
		var jc := global_transform * joker_curve.sample_baked(joker_curve.get_closest_offset(local))
		dx = pos.x - jc.x
		dz = pos.z - jc.z
		if dx * dx + dz * dz <= joker_road_half * joker_road_half:
			return false
	return true


## Distance along the line of the point closest to world position `pos`.
func nearest_offset(pos: Vector3) -> float:
	return centre_line.get_closest_offset(global_transform.affine_inverse() * pos)


## World transform for a reset at gate `gate_index`: on the centre line at the gate, facing
## the track tangent, at the line's height (callers drop it onto the ground).
func reset_transform(gate_index: int) -> Transform3D:
	var s := sample(gate_offsets[clampi(gate_index, 0, gate_offsets.size() - 1)])
	return Transform3D(Basis.looking_at(s["forward"], Vector3.UP), s["position"])


func build_gates() -> Array[Gate]:
	var out: Array[Gate] = []
	for off in gate_offsets:
		var s := sample(off)
		out.append(Gate.new(s["position"], s["forward"], gate_half_width))
	return out


func build_joker_gate() -> Gate:
	if not has_joker:
		return null
	return Gate.new(global_transform * joker_position, global_transform.basis * joker_forward, joker_half_width)


func make_lap_timer(tick_dt := 1.0 / 120.0) -> LapTimer:
	return LapTimer.new(build_gates(), sector_end_gates.duplicate(), build_joker_gate(), tick_dt)


## World transform of grid slot `i` (0 = pole), facing along the track.
func grid_transform(i: int) -> Transform3D:
	var s := sample(gate_offsets[0] - grid_spacing * (i + 1))
	var fwd: Vector3 = s["forward"]
	var right := fwd.cross(Vector3.UP)
	var side := grid_lateral if i % 2 == 0 else -grid_lateral
	var pos: Vector3 = s["position"] + right * side
	return Transform3D(Basis.looking_at(fwd, Vector3.UP), pos)


## Test/dev helper: closed circular loop of radius `r`, start at (r,0,0) heading -Z.
static func make_circle(r: float, n_gates := 8) -> TrackSpline:
	var ts := TrackSpline.new()
	var c := Curve3D.new()
	var k := 48
	for i in k + 1:
		var a := TAU * float(i) / k
		c.add_point(Vector3(r * cos(a), 0.0, -r * sin(a)))
	c.bake_interval = 0.5
	ts.centre_line = c
	var offs := PackedFloat32Array()
	var l := c.get_baked_length()
	for i in n_gates:
		offs.append(l * float(i) / n_gates)
	ts.gate_offsets = offs
	return ts
