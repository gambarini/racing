## Debug draw of a RacingLine (#27): a ribbon along the line coloured by target speed, red (slowest
## sample) to green (fastest). Toggled with the `toggle_racing_line` action (F3). Presentation
## only; the mesh is built once in rebuild(), toggling just flips visibility.
class_name RacingLineDebug
extends Node3D

const ACTION_TOGGLE := &"toggle_racing_line"

@export var line: RacingLine
@export var variant := RacingLine.Variant.MAIN
@export var half_width := 0.6 ## m, ribbon half width
@export var lift := 0.4 ## m above the road
@export var start_visible := false

var _mesh_instance: MeshInstance3D


func _ready() -> void:
	visible = start_visible
	rebuild()


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(ACTION_TOGGLE) and event.is_action_pressed(ACTION_TOGGLE):
		visible = not visible


## Colour for a speed within [lo, hi]: red (slow) to green (fast).
static func speed_colour(v: float, lo: float, hi: float) -> Color:
	var t := clampf((v - lo) / maxf(hi - lo, 1e-3), 0.0, 1.0)
	return Color.from_hsv(t * 0.33, 1.0, 1.0)


func rebuild() -> void:
	if _mesh_instance != null:
		_mesh_instance.queue_free()
		_mesh_instance = null
	if line == null:
		return
	var src: RacingLine = line.joker if variant == RacingLine.Variant.JOKER and line.has_joker() else line
	var n := src.pos.size()
	if n < 3:
		return
	var lo := INF
	var hi := -INF
	for v in src.target_speed:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for i in n:
		var a := src.pos[(i + n - 1) % n]
		var b := src.pos[(i + 1) % n]
		var right := Vector3(b.z - a.z, 0.0, -(b.x - a.x)).normalized() * half_width
		var c := speed_colour(src.target_speed[i], lo, hi)
		var up := Vector3(0.0, lift, 0.0)
		verts.append(src.pos[i] - right + up)
		verts.append(src.pos[i] + right + up)
		cols.append(c)
		cols.append(c)
		var j := (i + 1) % n
		idx.append_array([2 * i, 2 * i + 1, 2 * j, 2 * i + 1, 2 * j + 1, 2 * j])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Ribbon"
	_mesh_instance.mesh = mesh
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
