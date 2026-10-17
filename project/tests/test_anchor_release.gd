## Regression tests for the static-friction anchor release (#96, follow-up to #85): a parked car
## on a slope must let go cleanly (no snap, no backwards lurch) when the brake comes off or drive
## torque arrives, and the anchor must never engage past the friction limit. Scene-level: a real
## Vehicle on a pitched ground slab, stepped at the fixed physics tick.
extends GutTest

const TICK := 120.0
const SLOPE_DEG := 10.0
const MAX_DVDT := 2.0 ## m/s^2, acceptance limit for any single-tick longitudinal accel
const BRAKE := 4000.0 ## N*m per wheel, same as the lateral check's parked car
## N*m per wheel. Any nonzero drive torque drops the anchor (vehicle.gd: `drive_torque == 0.0`).
## Kept small so the car's own acceleration stays under MAX_DVDT: free-rolling down 10 deg is
## already 1.7 m/s^2, so a large torque would trip the "no snap" limit with honest acceleration.
const DRIVE := 20.0

var _root: Node3D


func after_each() -> void:
	if _root != null:
		_root.queue_free()
		_root = null


## Vehicle on a slab pitched so that the nose points `downhill_deg` downhill.
func _make_vehicle(downhill_deg: float) -> Vehicle:
	_root = Node3D.new()
	add_child(_root)
	var ground := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 2, 4000)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	ground.add_child(cs)
	ground.rotation = Vector3(-deg_to_rad(downhill_deg), 0.0, 0.0)
	_root.add_child(ground)
	var v: Vehicle = load("res://vehicle/vehicle.gd").new()
	v.transform = Transform3D(ground.basis, ground.basis.y * 0.05)
	_root.add_child(v)
	return v


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _set_brake(v: Vehicle, torque: float) -> void:
	for w in v.wheels:
		w.brake_torque = torque


func _set_drive(v: Vehicle, torque: float) -> void:
	for w in v.wheels:
		w.drive_torque = torque


func _anchored_count(v: Vehicle) -> int:
	var n := 0
	for w in v.wheels:
		if w.anchored:
			n += 1
	return n


## Speed along the car's forward axis (+ = downhill-forward, i.e. rolling nose first).
func _long_speed(v: Vehicle) -> float:
	return v.linear_velocity.dot(-v.global_transform.basis.z)


## Park a braked car on the slope until all four anchors have latched.
func _park(v: Vehicle) -> void:
	_set_brake(v, BRAKE)
	await _frames(150)


## Step `ticks` frames; returns max_dvdt, min/max speed, release_tick (first tick with no anchor),
## ever_anchored, anchored_ticks and last_anchored_tick.
func _watch(v: Vehicle, ticks: int) -> Dictionary:
	var prev := _long_speed(v)
	var out := {"max_dvdt": 0.0, "min_speed": prev, "max_speed": prev, "release_tick": -1,
			"ever_anchored": _anchored_count(v) > 0, "anchored_ticks": [], "last_anchored_tick": -1}
	for i in ticks:
		await _frames(1)
		var s := _long_speed(v)
		out.max_dvdt = maxf(out.max_dvdt, absf(s - prev) * TICK)
		out.min_speed = minf(out.min_speed, s)
		out.max_speed = maxf(out.max_speed, s)
		var n := _anchored_count(v)
		if n > 0:
			out.ever_anchored = true
			out.anchored_ticks.append(i)
			out.last_anchored_tick = i
		elif out.release_tick < 0:
			out.release_tick = i
		prev = s
	return out


func test_parked_car_is_anchored_on_slope() -> void:
	var v := _make_vehicle(SLOPE_DEG)
	await _park(v)
	assert_eq(_anchored_count(v), 4, "all four tires latch their anchor on a 10 deg slope")
	assert_lt(absf(_long_speed(v)), 0.01, "parked car is at rest")


func test_brake_release_is_smooth_and_frees_the_car() -> void:
	var v := _make_vehicle(SLOPE_DEG)
	await _park(v)
	assert_eq(_anchored_count(v), 4, "precondition: anchored")
	_set_brake(v, 0.0)
	var r := await _watch(v, int(3.0 * TICK))
	assert_lt(r.max_dvdt, MAX_DVDT, "no snap on brake release: max |dv/dt| %.2f m/s^2" % r.max_dvdt)
	assert_ne(r.release_tick, -1, "anchor releases after the brake comes off")
	assert_eq(_anchored_count(v), 0, "no tire is still anchored after 3 s")
	assert_gt(_long_speed(v), 1.0, "car free-rolls downhill (%.2f m/s)" % _long_speed(v))
	assert_gt(r.min_speed, -0.05, "no backwards lurch (min %.3f m/s)" % r.min_speed)


func test_drive_torque_releases_anchor_without_lurch() -> void:
	var v := _make_vehicle(SLOPE_DEG)
	await _park(v)
	assert_eq(_anchored_count(v), 4, "precondition: anchored")
	_set_brake(v, 0.0)
	_set_drive(v, DRIVE)
	var r := await _watch(v, int(3.0 * TICK))
	assert_lt(r.max_dvdt, MAX_DVDT, "smooth transition: max |dv/dt| %.2f m/s^2" % r.max_dvdt)
	assert_ne(r.release_tick, -1, "anchor releases under drive torque")
	assert_eq(_anchored_count(v), 0, "no tire is still anchored after 3 s")
	assert_gt(r.min_speed, -0.05, "no sign reversal / lurch backwards (min %.3f m/s)" % r.min_speed)
	assert_gt(_long_speed(v), 0.5, "car moves off downhill (%.2f m/s)" % _long_speed(v))


func test_slope_beyond_mu_peak_never_anchors() -> void:
	var mu_peak := TireParams.new().mu_peak # the tire the Vehicle builds when none is assigned
	var steep := rad_to_deg(atan(mu_peak)) + 2.0
	var v := _make_vehicle(steep)
	_set_brake(v, BRAKE)
	var r := await _watch(v, int(5.0 * TICK))
		# The car is dropped at rest, so the anchor can latch for the first 1-2 ticks before the demanded
	# hold force saturates and drops it; what matters is that it never holds after that.
	assert_lt(r.last_anchored_tick, 12, "no anchor after settling on %.1f deg (> atan(mu_peak))" % steep)
	assert_lt(r.anchored_ticks.size(), 6, "anchor only flickers at touchdown: %s" % [r.anchored_ticks])
	assert_gt(_long_speed(v), 1.0, "car accelerates downhill (%.2f m/s)" % _long_speed(v))
