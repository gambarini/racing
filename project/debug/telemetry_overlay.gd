## F1 telemetry overlay (#15): per-wheel and chassis readouts, Fx/Fy vectors at the contact points,
## F2 dump, and a live parameter panel. Presentation only: reads the recorder; its only writes are
## to the vehicle's tuning Resources (panel), which are inputs to the next tick.
class_name TelemetryOverlay
extends CanvasLayer

const ACTION_TOGGLE := &"toggle_telemetry"
const ACTION_DUMP := &"dump_telemetry"
const VECTOR_SCALE := 0.0004 ## m of arrow per N

@export var recorder: TelemetryRecorder
@export var start_visible := false ## F1 toggles at runtime

var _label: Label
var _panel: PanelContainer
var _draw: Control
var _params: Array = [] ## {obj, prop, default, box}
var _status := ""
var _has_ui := false


func _ready() -> void:
	layer = 100
	visible = start_visible
	# Headless (CI/tests) has no fonts: building Controls there only spams engine errors.
	_has_ui = DisplayServer.get_name() != "headless"
	if _has_ui:
		_draw = Control.new()
		_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
		_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_draw.draw.connect(_on_draw)
		add_child(_draw)
		_label = Label.new()
		_label.position = Vector2(8, 8)
		_label.add_theme_font_size_override("font_size", 12)
		add_child(_label)
		_panel = PanelContainer.new()
		_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		_panel.position = Vector2(-8, 8)
		add_child(_panel) # CanvasLayer visibility hides the panel together with the overlay
	_build_panel()


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(ACTION_TOGGLE) and event.is_action_pressed(ACTION_TOGGLE):
		visible = not visible
	elif InputMap.has_action(ACTION_DUMP) and event.is_action_pressed(ACTION_DUMP):
		if recorder != null:
			var p := recorder.dump()
			_status = ("dumped: " + ProjectSettings.globalize_path(p)) if p != "" else "dump failed"


func _process(_dt: float) -> void:
	if not visible or recorder == null:
		return
	_label.text = format_text(recorder.row, recorder) + ("\n" + _status if _status != "" else "")
	_draw.queue_redraw()


static func fmt(v: float, digits := 1) -> String:
	return "n/a" if is_nan(v) else String.num(v, digits)


func format_text(r: PackedFloat64Array, rec: TelemetryRecorder) -> String:
	var s := "speed %s km/h  yaw %s rad/s  lat %s g  long %s g\n" % [fmt(r[1]), fmt(r[2], 2), fmt(r[3], 2), fmt(r[4], 2)]
	s += "steer %s thr %s brk %s hb %s   rec %.1f us/tick\n" % [fmt(r[5], 2), fmt(r[6], 2), fmt(r[7], 2), fmt(r[8], 0), rec.record_cost_us]
	for i in 4:
		var c := func(ch: int) -> float: return r[TelemetrySchema.wheel_col(i, ch)]
		var surf := rec.surface_name(c.call(7))
		var trv: float = c.call(5)
		s += "%s Fz %s k %s a %s Fx %s Fy %s trv %s mm rpm %s %s\n" % [
			TelemetrySchema.WHEELS[i].to_upper(), fmt(c.call(0), 0), fmt(c.call(1), 2),
			fmt(c.call(2), 2), fmt(c.call(3), 0), fmt(c.call(4), 0),
			fmt(trv * 1000.0, 0), fmt(c.call(6), 0), surf if surf != "" else "n/a"]
	return s


func _on_draw() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or recorder == null or recorder.vehicle == null:
		return
	var basis := recorder.vehicle.global_transform.basis
	for i in recorder.vehicle.wheels.size():
		var w: Wheel = recorder.vehicle.wheels[i]
		if not w.is_grounded or cam.is_position_behind(w.contact_point):
			continue
		var p0 := cam.unproject_position(w.contact_point)
		var fx_end := cam.unproject_position(w.contact_point - basis.z * w.fx * VECTOR_SCALE)
		_draw.draw_line(p0, fx_end, Color.RED, 2.0)
		var fy: float = recorder.row[TelemetrySchema.wheel_col(i, 4)]
		if not is_nan(fy): # Fy only once the lateral model lands
			_draw.draw_line(p0, cam.unproject_position(w.contact_point + basis.x * fy * VECTOR_SCALE), Color.CYAN, 2.0)


func _build_panel() -> void:
	var box: VBoxContainer = null
	if _has_ui:
		box = VBoxContainer.new()
		_panel.add_child(box)
		var title := Label.new()
		title.text = "Live tuning"
		box.add_child(title)
	_params.clear()
	var v: Vehicle = recorder.vehicle if recorder != null else null
	if v != null:
		if v.definition == null:
			v.definition = Vehicle.DEFAULT_DEFINITION
		# Panel edits must never mutate the shared preloaded/on-disk Resources: own a copy.
		if v.definition.resource_path != "":
			v.definition = v.definition.duplicate()
		if v.tire_params == null:
			v.tire_params = TireParams.new()
		elif v.tire_params.resource_path != "":
			v.tire_params = v.tire_params.duplicate()
		_add_param(box, v.definition, "spring_rate", 1000.0, 120000.0, 500.0)
		_add_param(box, v.definition, "damper_bump", 0.0, 8000.0, 50.0)
		_add_param(box, v.definition, "damper_rebound", 0.0, 8000.0, 50.0)
		_add_param(box, v.definition, "arb_front", 0.0, 60000.0, 250.0)
		_add_param(box, v.definition, "arb_rear", 0.0, 60000.0, 250.0)
		_add_param(box, v.tire_params, "mu_peak", 0.3, 2.5, 0.01)
	if _has_ui:
		var reset := Button.new()
		reset.text = "Reset to defaults"
		reset.pressed.connect(reset_params)
		box.add_child(reset)


func _add_param(parent: Control, obj: Object, prop: String, lo: float, hi: float, step: float) -> void:
	if not _has_ui:
		_params.append({"obj": obj, "prop": prop, "default": obj.get(prop), "box": null})
		return
	var hb := HBoxContainer.new()
	var l := Label.new()
	l.text = prop
	l.custom_minimum_size.x = 110
	var sb := SpinBox.new()
	sb.min_value = lo
	sb.max_value = hi
	sb.step = step
	sb.value = obj.get(prop)
	sb.value_changed.connect(func(val: float) -> void: obj.set(prop, val))
	hb.add_child(l)
	hb.add_child(sb)
	parent.add_child(hb)
	_params.append({"obj": obj, "prop": prop, "default": obj.get(prop), "box": sb})


func reset_params() -> void:
	for p in _params:
		p.obj.set(p.prop, p.default)
		if p.box != null:
			p.box.set_value_no_signal(p.default)


## Test hook: set a panel parameter as the UI would.
func set_param(prop: String, value: float) -> void:
	for p in _params:
		if p.prop == prop:
			if p.box != null:
				p.box.value = value
			else:
				p.obj.set(prop, value)
