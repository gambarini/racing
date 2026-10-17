extends GutTest
## AWD drivetrain (#26): centre differential split and the four-wheel Powertrain facade.

const DT := 1.0 / 120.0

var d: PowertrainDefinition


func before_each() -> void:
	d = PowertrainDefinition.new()
	d.layout = PowertrainDefinition.Layout.AWD


func _launch(pt: Powertrain, w_front: float, w_rear: float, ticks := 240) -> void:
	for i in ticks:
		if pt.def.layout == PowertrainDefinition.Layout.AWD:
			pt.step_awd(DT, 1.0, w_rear, w_rear, w_front, w_front, 0.0, 5.0)
		else:
			pt.step(DT, 1.0, w_rear, w_rear, 0.0, 5.0)


func test_equal_grip_split_matches_data_for_all_types() -> void:
	for type in [0, 1, 2]:
		d.centre_diff_type = type
		for split in [0.4, 0.5, 0.25]:
			d.centre_split_front = split
			for t_in in [-200.0, 150.0, 900.0]:
				var s := Differential.centre_split(d, t_in, 40.0, 40.0)
				assert_almost_eq(s.x / t_in, split, 0.02, "type %d split %.2f t %.0f" % [type, split, t_in])


func test_centre_torque_conservation() -> void:
	for type in [0, 1, 2]:
		d.centre_diff_type = type
		for t_in in [-300.0, 0.0, 80.0, 2500.0]:
			for p in [Vector2(10, 10), Vector2(90, 30), Vector2(30, 90), Vector2(0, 70)]:
				var s := Differential.centre_split(d, t_in, p.x, p.y)
				assert_lt(absf(t_in - s.x - s.y), 1e-6)


func test_default_is_40_60_open() -> void:
	assert_eq(d.centre_split_front, 0.4)
	assert_eq(d.centre_diff_type, PowertrainDefinition.DiffType.OPEN)
	var s := Differential.centre_split(d, 1000.0, 200.0, 20.0) # front on mud, spinning
	assert_almost_eq(s.x, 400.0, 1e-6, "open keeps the split whatever the grip")


func test_locked_sends_more_to_gripping_axle_than_open() -> void:
	var open_s := Differential.centre_split(d, 800.0, 90.0, 30.0) # front spinning on mud
	d.centre_diff_type = PowertrainDefinition.DiffType.LOCKED
	var locked_s := Differential.centre_split(d, 800.0, 90.0, 30.0)
	assert_gt(locked_s.y, open_s.y, "rear (gripping) gets more when locked")
	assert_lt(locked_s.x, open_s.x)
	# Mirror: rear on mud.
	d.centre_diff_type = PowertrainDefinition.DiffType.OPEN
	var open_m := Differential.centre_split(d, 800.0, 30.0, 90.0)
	d.centre_diff_type = PowertrainDefinition.DiffType.LOCKED
	var locked_m := Differential.centre_split(d, 800.0, 30.0, 90.0)
	assert_gt(locked_m.x, open_m.x, "front (gripping) gets more when locked")


func test_lsd_biases_to_slower_axle() -> void:
	d.centre_diff_type = PowertrainDefinition.DiffType.LSD
	var s := Differential.centre_split(d, 800.0, 90.0, 30.0)
	assert_gt(s.y, 800.0 * 0.6, "rear gets more than its 60 %")


func test_facade_awd_drives_all_four_wheels() -> void:
	var pt := Powertrain.new(d)
	_launch(pt, 20.0, 20.0)
	assert_gt(pt.torque_front_left, 0.0)
	assert_gt(pt.torque_front_right, 0.0)
	assert_gt(pt.torque_left, 0.0)
	assert_gt(pt.torque_right, 0.0)
	var front := pt.torque_front_left + pt.torque_front_right
	var rear := pt.torque_left + pt.torque_right
	assert_almost_eq(front / (front + rear), 0.4, 0.02, "front share of wheel torque")
	assert_almost_eq(pt.torque_front_left, pt.torque_front_right, 1e-6, "open axle diff splits evenly")


func test_facade_rwd_leaves_front_undriven() -> void:
	d.layout = PowertrainDefinition.Layout.RWD
	var pt := Powertrain.new(d)
	_launch(pt, 20.0, 20.0)
	assert_eq(pt.torque_front_left, 0.0)
	assert_gt(pt.torque_left, 0.0)


func test_facade_awd_inertia_shared_over_four_wheels() -> void:
	var a := Powertrain.new(d)
	var rd := PowertrainDefinition.new()
	var r := Powertrain.new(rd)
	for i in 600:
		a.step_awd(DT, 1.0, 30.0, 30.0, 30.0, 30.0, 0.0, 10.0)
		r.step(DT, 1.0, 30.0, 30.0, 0.0, 10.0)
	assert_gt(r.reflected_inertia, 0.0)
	assert_almost_eq(a.reflected_inertia, r.reflected_inertia * 0.5, 1e-6)


func test_driven_wheels_by_layout() -> void:
	assert_eq(d.driven_wheels(), PackedInt32Array([0, 1, 2, 3]))
	d.layout = PowertrainDefinition.Layout.FWD
	assert_eq(d.driven_wheels(), PackedInt32Array([0, 1]))
	d.layout = PowertrainDefinition.Layout.RWD
	assert_eq(d.driven_wheels(), PackedInt32Array([2, 3]))


func test_awd_resource_loads_as_data() -> void:
	var car := load("res://vehicle/definitions/awd_car.tres") as VehicleDefinition
	assert_not_null(car)
	assert_not_null(car.powertrain)
	assert_eq(car.powertrain.layout, PowertrainDefinition.Layout.AWD)
	assert_eq(car.powertrain.centre_split_front, 0.4)
