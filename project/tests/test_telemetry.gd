extends GutTest
## Telemetry recorder / CSV / overlay panel (#15). Drives the real #8 Vehicle on a flat ground.

const DT := 1.0 / 120.0


func _world() -> Dictionary: # not stepped: tests call rec.record() directly
	var root := Node3D.new()
	var ground := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 2, 200)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	ground.add_child(cs)
	root.add_child(ground)
	var v := Vehicle.new()
	v.definition = (load("res://vehicle/definitions/reference_car.tres") as VehicleDefinition).duplicate()
	v.position = Vector3(0, 0.05, 0)
	root.add_child(v)
	var rec := TelemetryRecorder.new()
	rec.vehicle = v
	var di := DriverInput.new()
	root.add_child(di)
	rec.driver_input = di
	root.add_child(rec)
	add_child_autofree(root)
	return {"vehicle": v, "rec": rec}


func test_schema_columns() -> void:
	var names := TelemetrySchema.column_names()
	assert_eq(names.size(), TelemetrySchema.N_COLS)
	assert_eq(names[0], "t")
	assert_eq(names[8], "handbrake")
	assert_eq(names[9], "fl_fz")
	assert_eq(names[TelemetrySchema.POWERTRAIN_COL - 1], "rr_surface")
	assert_eq(names[TelemetrySchema.POWERTRAIN_COL], "rpm") # powertrain channels (#11) follow the wheel block
	assert_eq(names[TelemetrySchema.POWERTRAIN_COL + 3], "engine_torque")
	assert_eq(names[names.size() - 1], "rr_w_" + String(SurfaceRegistry.ids()[-1])) # surface weights (#19) last


func test_buffer_ring_wraps_and_keeps_order() -> void:
	var b := TelemetryBuffer.new(5)
	var r := TelemetrySchema.new_row()
	for i in 8:
		r[0] = float(i)
		b.push(r)
	assert_eq(b.count, 5)
	assert_eq(b.value(0, 0), 3.0)
	assert_eq(b.value(4, 0), 7.0)
	assert_eq(TelemetryBuffer.new().capacity, 7200)


func test_dump_three_second_run() -> void:
	var w := _world()
	var rec: TelemetryRecorder = w.rec
	for i in 360: # manual ticks: awaiting frames makes GUT's own UI spam font errors headless
		rec.record(DT)
	var path := rec.dump("user://telemetry_test.csv")
	assert_ne(path, "")
	var f := FileAccess.open(path, FileAccess.READ)
	var lines: Array[String] = []
	while not f.eof_reached():
		var l := f.get_line()
		if l != "":
			lines.append(l)
	f.close()
	var header := lines[0].split(",")
	assert_eq(header.size(), TelemetrySchema.N_COLS)
	assert_eq(lines[0], ",".join(TelemetrySchema.column_names()))
	assert_almost_eq(float(lines.size() - 1), 360.0, 2.0, "row count")
	var prev_t := -1.0
	for i in range(1, lines.size()):
		var cells := lines[i].split(",")
		assert_eq(cells.size(), TelemetrySchema.N_COLS)
		var t := float(cells[0])
		if prev_t >= 0.0:
			assert_almost_eq(t - prev_t, DT, 1e-5)
		prev_t = t
		for c in cells.size():
			var name := header[c]
			if name.ends_with("_surface"):
				assert_ne(cells[c], "NaN")
			else:
				assert_true(cells[c].is_valid_float(), "%s row %d = '%s'" % [name, i, cells[c]])
	DirAccess.remove_absolute(path)


func test_record_cost_and_no_growth() -> void:
	var w := _world()
	var rec: TelemetryRecorder = w.rec
	var t0 := Time.get_ticks_usec()
	for i in 2000:
		rec.record(DT)
	var us := float(Time.get_ticks_usec() - t0) / 2000.0
	gut.p("telemetry record cost: %.2f us/tick (budget 50)" % us)
	assert_lt(us, 50.0)
	assert_lte(rec.buffer.count, rec.buffer.capacity)


func test_panel_edit_and_reset() -> void:
	var w := _world()
	var v: Vehicle = w.vehicle
	var rec: TelemetryRecorder = w.rec
	var ov := TelemetryOverlay.new()
	ov.recorder = rec
	add_child_autofree(ov)
	assert_false(ov.visible, "hidden by default")
	var k0 := v.definition.spring_rate
	ov.set_param("spring_rate", k0 * 2.0)
	assert_eq(v.definition.spring_rate, k0 * 2.0)
	ov.set_param("mu_peak", 1.5)
	assert_eq(v.tire_params.mu_peak, 1.5)
	ov.reset_params()
	assert_eq(v.definition.spring_rate, k0)
	assert_eq(v.tire_params.mu_peak, TireParams.new().mu_peak)
	assert_eq(ov._params.size(), 6)
	var txt := ov.format_text(rec.row, rec)
	assert_true(txt.contains("n/a"), "missing channels show n/a")
