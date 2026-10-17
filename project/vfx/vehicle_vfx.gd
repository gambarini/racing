## Per-wheel surface VFX (#20): add as a child of a Vehicle. Reads wheel slip, surface weights and
## speed (never writes sim state) and drives one CPUParticles3D per (wheel, surface) plus tyre marks.
class_name VehicleVfx
extends Node3D

const MARK_SPACING := 0.3 ## m between mark segments

@export var quality := 1.0 ## 0..1 scales particle amount (quality setting)
var vehicle: Vehicle
var tyre_marks: TyreMarks ## shared by all cars; created next to the vehicle if left null
var emitters := {} ## "wheel_index:surface_id" -> CPUParticles3D
var _last_mark: Array[Vector3] = []
var _marking: Array[bool] = []


func _ready() -> void:
	if vehicle == null and get_parent() is Vehicle:
		vehicle = get_parent()


func _physics_process(_delta: float) -> void:
	step()


## One update; also callable from tests.
func step() -> void:
	if vehicle == null:
		return
	if tyre_marks == null:
		tyre_marks = TyreMarks.new()
		vehicle.get_parent().add_child.call_deferred(tyre_marks)
	var speed := vehicle.linear_velocity.length()
	while _last_mark.size() < vehicle.wheels.size():
		_last_mark.append(Vector3.ZERO)
		_marking.append(false)
	for i in vehicle.wheels.size():
		var w := vehicle.wheels[i]
		var scales := SurfaceVfxMath.emission_scales(w.surface_weights, w.is_grounded, w.kappa,
				w.alpha, speed)
		for id in scales:
			var em := _emitter(i, id)
			em.global_position = w.contact_point
			var s: float = scales[id] * clampf(quality, 0.0, 1.0)
			em.amount_ratio = s
			em.emitting = s > 0.0
		for key in emitters:
			if key.begins_with("%d:" % i) and not scales.has(StringName(key.substr(key.find(":") + 1))):
				emitters[key].emitting = false
		_step_marks(i, w, speed)


## Particles per second the (wheel, surface) emitter currently produces (0 if not emitting).
func emission_rate(wheel_index: int, id: StringName) -> float:
	var key := "%d:%s" % [wheel_index, id]
	if not emitters.has(key):
		return 0.0
	var em: GPUParticles3D = emitters[key]
	if not em.emitting:
		return 0.0
	return em.amount * em.amount_ratio / maxf(em.lifetime, 0.01)


## Particles that can be alive at once across all emitters of this car.
func live_particle_estimate() -> float:
	var n := 0.0
	for em: GPUParticles3D in emitters.values():
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


func _emitter(i: int, id: StringName) -> GPUParticles3D:
	var key := "%d:%s" % [i, id]
	if emitters.has(key):
		return emitters[key]
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
	emitters[key] = em
	return em
