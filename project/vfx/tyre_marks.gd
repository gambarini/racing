## Pooled tyre-mark segments (#20): flat quads laid on the ground, ring-buffered at
## SurfaceVfxMath.MAX_MARK_SEGMENTS live segments (oldest is recycled). Presentation only.
class_name TyreMarks
extends Node3D

var max_segments := SurfaceVfxMath.MAX_MARK_SEGMENTS
var _pool: Array[MeshInstance3D] = []
var _next := 0
var _mesh := PlaneMesh.new()
var _materials := {} ## TyreMarkStyle -> StandardMaterial3D


func _enter_tree() -> void:
	add_to_group(&"tyre_marks")


func _init() -> void:
	_mesh.size = Vector2.ONE


## Live segments (never above max_segments).
func live_count() -> int:
	return _pool.size()


## Lays one segment from `a` to `b` on a surface with normal `n`. Returns false if degenerate.
func add_segment(a: Vector3, b: Vector3, n: Vector3, style: TyreMarkStyle) -> bool:
	var d := b - a
	var len := d.length()
	if len < 0.001 or style == null:
		return false
	var mi: MeshInstance3D
	if _pool.size() < max_segments:
		mi = MeshInstance3D.new()
		mi.mesh = _mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_pool.append(mi)
	else:
		mi = _pool[_next]
		_next = (_next + 1) % max_segments
	if not _materials.has(style):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = style.color
		_materials[style] = m
	mi.material_override = _materials[style]
	var up := n.normalized()
	var z := (d - up * d.dot(up)).normalized()
	var x := up.cross(z).normalized()
	var basis := Basis(x * style.width, up, z * len)
	mi.global_transform = Transform3D(basis, (a + b) * 0.5 + up * 0.01)
	return true
