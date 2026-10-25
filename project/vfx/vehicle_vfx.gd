## Per-wheel surface VFX (#20): add as a child of a Vehicle. Reads wheel slip, surface weights and
## speed (never writes sim state) and drives one GPUParticles3D per (wheel, surface) plus tyre marks.
class_name VehicleVfx
extends Node3D

const MARK_SPACING := 0.3 ## m between mark segments

@export var quality := 1.0 ## 0..1 scales particle amount (quality setting)
var vehicle: Vehicle
var tyre_marks: TyreMarks ## one per scene (group "tyre_marks"), found or created next to the car
var emitters: Array[Dictionary] = [] ## per wheel: surface id -> GPUParticles3D
var _touched: Array[Dictionary] = [] ## per wheel scratch: ids set this tick
var _last_mark: Array[Vector3] = []
var _marking: Array[bool] = []


func _ready() -> void:
	if vehicle == null and get_parent() is Vehicle:
		vehicle = get_parent()


func _physics_process(_delta: float) -> void:
	step()


## One update; also callable from tests. No per-tick allocation once emitters exist.
func step() -> void:
	if vehicle == null:
		return
	if tyre_marks == null or not is_instance_valid(tyre_marks):
		tyre_marks = _find_marks()
	var n := vehicle.wheels.size()
	if _last_mark.size() != n:
		_last_mark.resize(n)
		_marking.resize(n)
		while emitters.size() < n:
			emitters.append({})
			_touched.append({})
	var speed := vehicle.linear_velocity.length()
	var q := clampf(quality, 0.0, 1.0)
	for i in n:
		var w := vehicle.wheels[i]
		var ems := emitters[i]
		var touched := _touched[i]
		touched.clear()
		var total := 0.0
		for j in w.weight_count:
			total += w.weights[j]
		var live := 0.0 # live particles this wheel would have (per-wheel cap below)
		if total > 0.0:
			for j in w.weight_count:
				if w.weights[j] <= 0.0:
					continue
				var id := w.weight_ids[j]
				var eff := SurfaceRegistry.get_surface(id).particle_effect
				if eff == null:
					continue
				var s: float = SurfaceVfxMath.intensity(w.is_grounded, w.kappa, w.alpha, speed,
						eff.roll_rate) * (w.weights[j] / total) * q
				live += s * mini(eff.max_amount, SurfaceVfxMath.MAX_EFFECT_AMOUNT)
		var cap_f := 1.0
		if live > SurfaceVfxMath.MAX_PARTICLES_PER_WHEEL:
			cap_f = SurfaceVfxMath.MAX_PARTICLES_PER_WHEEL / live
		if total > 0.0:
			for j in w.weight_count:
				if w.weights[j] <= 0.0:
					continue
				var id := w.weight_ids[j]
				var eff := SurfaceRegistry.get_surface(id).particle_effect
				if eff == null:
					continue
				var s: float = SurfaceVfxMath.intensity(w.is_grounded, w.kappa, w.alpha, speed,
						eff.roll_rate) * (w.weights[j] / total) * q * cap_f
				var em: GPUParticles3D = ems.get(id)
				if em == null:
					if s <= 0.0:
						continue
					em = _make_emitter(id)
					ems[id] = em
				touched[id] = true
				em.global_position = w.contact_point
				em.amount_ratio = s
				var on: bool = s > 0.0
				if em.emitting != on:
					em.emitting = on
		for id in ems:
			if not touched.has(id) and ems[id].emitting:
				ems[id].emitting = false
		_step_marks(i, w, speed)


## Finds the scene's shared TyreMarks (group) or creates one next to the car.
func _find_marks() -> TyreMarks:
	var found := get_tree().get_first_node_in_group(&"tyre_marks") if is_inside_tree() else null
	if found is TyreMarks:
		return found
	var m := TyreMarks.new()
	vehicle.get_parent().add_child(m)
	return m


## Particles per second the (wheel, surface) emitter currently produces (0 if not emitting).
func emission_rate(wheel_index: int, id: StringName) -> float:
	if wheel_index >= emitters.size() or not emitters[wheel_index].has(id):
		return 0.0
	var em: GPUParticles3D = emitters[wheel_index][id]
	if not em.emitting:
		return 0.0
	return em.amount * em.amount_ratio / maxf(em.lifetime, 0.01)


## Particles that can be alive at once across all emitters of this car.
func live_particle_estimate() -> float:
	var n := 0.0
	for ems in emitters:
		for id in ems:
			var em: GPUParticles3D = ems[id]
			if em.emitting:
				n += em.amount * em.amount_ratio
	return n


func _step_marks(i: int, w: Wheel, speed: float) -> void:
	var style := SurfaceRegistry.get_surface(w.surface_id).tyre_mark
	if not SurfaceVfxMath.should_mark(w.is_grounded, w.kappa, w.alpha, speed, style):
		_marking[i] = false
		return
	if not _marking[i]:
		_marking[i] = true
		_last_mark[i] = w.contact_point
		return
	if w.contact_point.distance_to(_last_mark[i]) >= MARK_SPACING:
		tyre_marks.add_segment(_last_mark[i], w.contact_point, w.contact_normal, style)
		_last_mark[i] = w.contact_point


func _make_emitter(id: StringName) -> GPUParticles3D:
	var eff := SurfaceRegistry.get_surface(id).particle_effect
	var em := GPUParticles3D.new()
	em.top_level = true
	em.local_coords = false
	em.amount = mini(eff.max_amount, SurfaceVfxMath.MAX_EFFECT_AMOUNT)
	em.lifetime = eff.lifetime
	em.emitting = false
	em.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, eff.upward_bias, 1).normalized()
	pm.spread = 35.0
	pm.initial_velocity_min = eff.launch_speed * 0.5
	pm.initial_velocity_max = eff.launch_speed
	pm.gravity = Vector3(0, eff.gravity, 0)
	pm.scale_min = eff.size
	pm.scale_max = eff.size * 1.5
	pm.color = eff.color
	em.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	q.material = mat
	em.draw_pass_1 = q
	add_child(em)
	return em
