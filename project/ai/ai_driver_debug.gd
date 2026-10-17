## Debug draw for the AI driver (#28): a marker at the pure-pursuit look-ahead point and a label with
## the current / target speed. Presentation only; hidden by default. Toggle with `toggle_ai_debug`
## (F4, InputMap) or set `shown`. Add as a child of the scene and set `driver`.
class_name AiDriverDebug
extends Node3D

const ACTION_TOGGLE := &"toggle_ai_debug"

var driver: AiDriver
var vehicle: Vehicle
var shown := false:
	set(v):
		shown = v
		visible = v
var _marker: MeshInstance3D
var _label: Label3D
var _last_text_key := -1


func _ready() -> void:
	top_level = true
	visible = shown
	_marker = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.6
	sphere.height = 1.2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.2, 0.9)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere.material = mat
	_marker.mesh = sphere
	add_child(_marker)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.pixel_size = 0.02
	add_child(_label)


func toggle() -> void:
	shown = not shown


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION_TOGGLE):
		toggle()


func _process(_delta: float) -> void:
	if not shown or driver == null:
		return
	_marker.global_position = driver.look_point + Vector3(0.0, 1.0, 0.0)
	if vehicle != null:
		_label.global_position = vehicle.global_position + Vector3(0.0, 2.5, 0.0)
	# text only changes with the rounded km/h pair, so a steady state allocates nothing
	var key := int(driver.target_speed * 3.6) * 1000 + int(driver.speed_now * 3.6)
	if key != _last_text_key:
		_last_text_key = key
		_label.text = "target %d km/h\nspeed %d km/h" % [int(driver.target_speed * 3.6), int(driver.speed_now * 3.6)]
