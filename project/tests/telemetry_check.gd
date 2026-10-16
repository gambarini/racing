## Headless check for the telemetry recorder on the real #8 Vehicle (#15): 3 s run, dump, parse.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/telemetry_check.gd
extends SceneTree

const DT := 1.0 / 120.0
var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


func _initialize() -> void:
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
	v.position = Vector3(0, 0.05, 0)
	root.add_child(v)
	var di := DriverInput.new()
	root.add_child(di)
	var rec := TelemetryRecorder.new()
	rec.vehicle = v
	rec.driver_input = di
	root.add_child(rec)
	get_root().add_child(root)
	run(rec)


func run(rec: TelemetryRecorder) -> void:
	for i in 360:
		await physics_frame
	var path := rec.dump("user://telemetry_check.csv")
	check(path != "", "dump wrote a file")
	var f := FileAccess.open(path, FileAccess.READ)
	var lines: Array[String] = []
	while not f.eof_reached():
		var l := f.get_line()
		if l != "":
			lines.append(l)
	f.close()
	DirAccess.remove_absolute(path)
	var header := lines[0].split(",")
	check(lines[0] == ",".join(TelemetrySchema.column_names()), "header matches schema")
	check(header.size() == 41, "41 columns")
	check(absi(lines.size() - 1 - 360) <= 1, "row count %d ~ 360" % (lines.size() - 1))
	var bad := 0
	var prev_t := -1.0
	var t_ok := true
	var surf_ok := true
	for i in range(1, lines.size()):
		var cells := lines[i].split(",")
		if cells.size() != header.size():
			bad += 1
			continue
		var t := float(cells[0])
		if prev_t >= 0.0 and absf(t - prev_t - DT) > 1e-6:
			t_ok = false
		prev_t = t
		for c in cells.size():
			var n := header[c]
			if n.ends_with("_surface"):
				if cells[c] != "default":
					surf_ok = false
			elif not cells[c].is_valid_float():
				bad += 1
	check(bad == 0, "all provided channels parse as floats; n/a channels empty (bad=%d)" % bad)
	check(t_ok, "t strictly increasing by 1/120")
	check(surf_ok, "surface column holds the surface id")
	print("record cost avg: %.2f us/tick" % rec.record_cost_us)
	check(rec.record_cost_us < 50.0, "record cost <= 0.05 ms")
	print("RESULT: ", "FAIL (%d)" % failures if failures > 0 else "OK")
	quit(1 if failures > 0 else 0)
