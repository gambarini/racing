extends GutTest
## DriverInput node: InputMap bindings, injected actions, determinism (issue #13).

const DT := 1.0 / 120.0
const ACTIONS: Array[StringName] = [&"steer_left", &"steer_right", &"throttle", &"brake", &"handbrake"]

var di: DriverInput


func before_each() -> void:
	di = DriverInput.new()
	add_child_autofree(di)


func after_each() -> void:
	for a in ACTIONS:
		Input.action_release(a)


func test_actions_exist_with_keyboard_and_gamepad_bindings() -> void:
	for a in ACTIONS:
		assert_true(InputMap.has_action(a), "action %s" % a)
		var has_key := false
		var has_pad := false
		for e in InputMap.action_get_events(a):
			has_key = has_key or e is InputEventKey
			has_pad = has_pad or e is InputEventJoypadMotion or e is InputEventJoypadButton
		assert_true(has_key, "%s has key" % a)
		assert_true(has_pad, "%s has pad" % a)


func _run(ticks: int) -> void:
	for i in ticks:
		di.sample_and_step(DT)


func test_keyboard_steer_full_lock_time() -> void:
	Input.action_press(&"steer_right")
	var n := 0
	while di.state.steer < 1.0 and n < 200:
		di.sample_and_step(DT)
		n += 1
	assert_between(float(n) * DT, 0.17 - DT, 0.4)
	Input.action_release(&"steer_right")
	n = 0
	while di.state.steer > 0.0 and n < 200:
		di.sample_and_step(DT)
		n += 1
	assert_between(float(n) * DT, 0.15 - DT, 0.3)


func test_gamepad_stick_uses_deadzone_and_curve() -> void:
	Input.action_press(&"steer_right", 0.575)
	_run(60)
	assert_almost_eq(di.state.steer, pow(0.5, 1.5), 0.001)
	Input.action_release(&"steer_right")
	Input.action_press(&"steer_left", 0.1)
	_run(60)
	assert_eq(di.state.steer, 0.0)


func test_steer_left_is_negative() -> void:
	Input.action_press(&"steer_left")
	_run(60)
	assert_almost_eq(di.state.steer, -1.0, 0.0001)


func test_speed_limits_range() -> void:
	di.speed_kmh = 150.0
	Input.action_press(&"steer_right")
	_run(120)
	assert_almost_eq(di.state.steer, 0.35, 0.0001)


func test_triggers_and_both_pedals_allowed() -> void:
	Input.action_press(&"throttle", 0.03)
	Input.action_press(&"brake", 1.0)
	_run(60)
	assert_eq(di.state.throttle, 0.0)
	Input.action_press(&"throttle", 1.0)
	_run(60)
	assert_almost_eq(di.state.throttle, 1.0, 0.0001)
	assert_almost_eq(di.state.brake, 1.0, 0.0001)


func test_keyboard_throttle_ramp_time() -> void:
	Input.action_press(&"throttle")
	var n := 0
	while di.state.throttle < 1.0 and n < 200:
		di.sample_and_step(DT)
		n += 1
	assert_between(float(n) * DT, 0.1, 0.2)


func test_handbrake() -> void:
	Input.action_press(&"handbrake")
	di.sample_and_step(DT)
	assert_true(di.state.handbrake)
	Input.action_release(&"handbrake")
	di.sample_and_step(DT)
	assert_false(di.state.handbrake)


func test_assist_flag_and_off_equals_unassisted() -> void:
	var stream := []
	for i in 240:
		stream.append([sin(i * 0.05) * 1.2, 1.0 if i % 90 < 60 else 0.0, 0.0, false])
	var a := _replay(stream, false, 14.0)
	var b := _replay(stream, false, 0.0)
	assert_eq(a, b, "assist off ignores slip")
	var c := _replay(stream, true, 14.0)
	assert_ne(a, c, "assist on changes output when sliding")
	di.counter_steer_assist = true
	di.rear_slip_deg = 14.0
	di.reset()
	for i in 60:
		di.step_raw(1.0, 0.0, 0.0, false, DT)
	assert_true(di.assist_active)
	di.counter_steer_assist = false
	di.step_raw(1.0, 0.0, 0.0, false, DT)
	assert_false(di.assist_active)


func _replay(stream: Array, assist: bool, slip: float) -> Array:
	var node := DriverInput.new()
	add_child_autofree(node)
	node.counter_steer_assist = assist
	node.rear_slip_deg = slip
	var out := []
	for s in stream:
		var st := node.step_raw(s[0], s[1], s[2], s[3], DT)
		out.append([st.steer, st.throttle, st.brake, st.handbrake])
	return out


func test_replay_is_deterministic() -> void:
	var stream := []
	for i in 300:
		stream.append([cos(i * 0.03), 0.5 + 0.5 * sin(i * 0.02), 0.2, i % 50 == 0])
	assert_eq(_replay(stream, true, 10.0), _replay(stream, true, 10.0))
