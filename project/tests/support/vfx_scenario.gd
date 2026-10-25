## Shared scenario helpers for the Quarry surface VFX scripts (#128): tests/quarry_vfx_check.gd and
## tools/vfx/capture_surface_vfx.gd. Static; pass the SceneTree to `hold`.
class_name VfxScenario
extends RefCounted

const GRASS_S := 10.0
const GRASS_OFFSET := 8.0


static func vfx(d: QuarryDrive) -> VehicleVfx:
	return d.get_node("Vehicle/VehicleVfx")


static func lat(q: Quarry, id: StringName, s: float) -> float:
	return q.road_half(s) + GRASS_OFFSET if id == &"grass" else 0.0


static func pos(q: Quarry, s: float, lat: float) -> Vector3:
	var smp: Dictionary = q.track.sample(s)
	var fwd: Vector3 = smp["forward"]
	return (smp["position"] as Vector3) + fwd.cross(Vector3.UP) * lat


static func weight(q: Quarry, s: float, lat: float, id: StringName) -> float:
	var p := pos(q, s, lat)
	return q.terrain.surface_map.sample(p.x, p.z).get(id, 0.0)


## Middle of the longest purest stretch of `id` on the main line.
static func mid_zone(q: Quarry, id: StringName) -> float:
	if id == &"grass":
		return GRASS_S
	var n := int(q.track.length() / 2.0)
	var run_lo := 0
	var best_lo := 0
	var best_len := 0
	for i in n + 1:
		var pure := false
		if i < n:
			pure = true
			for dd in range(-5, 6, 5):
				if weight(q, i * 2.0 + dd, 0.0, id) < 0.99:
					pure = false
					break
		if pure:
			continue
		if i - run_lo > best_len:
			best_len = i - run_lo
			best_lo = run_lo
		run_lo = i + 1
	return (best_lo + best_lo + best_len - 1) * 1.0


static func teleport(d: QuarryDrive, s: float, lat: float, speed: float) -> void:
	var fwd: Vector3 = d.quarry.track.sample(s)["forward"]
	var pos := pos(d.quarry, s, lat)
	pos.y = d.quarry.terrain.height_at(pos.x, pos.z) + d.spawn_lift
	d.vehicle.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), pos)
	d.vehicle.linear_velocity = fwd * speed
	d.vehicle.angular_velocity = Vector3.ZERO
	for w in d.vehicle.wheels:
		w.omega = speed / w.radius


static func speed(d: QuarryDrive) -> float:
	return d.vehicle.linear_velocity.dot(-d.vehicle.global_transform.basis.z)


static func hold(tree: SceneTree, d: QuarryDrive, speed: float, ticks: int) -> void:
	for i in ticks:
		var err := speed - speed(d)
		var st := d.driver_input.state
		st.steer = 0.0
		st.handbrake = false
		st.throttle = clampf(err * 0.5, 0.0, 1.0)
		st.brake = clampf(-err * 0.5, 0.0, 1.0)
		await tree.physics_frame
