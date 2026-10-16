## Headless check for the Proving Ground drive scene (#79): overlay + recorder are instanced and
## wired, the car settles, rows are recorded, and panel edits do not touch the shared Resources.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/proving_ground_drive_check.gd
extends SceneTree

var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


func _initialize() -> void:
	var root: Node = load("res://tracks/proving_ground/proving_ground_drive.tscn").instantiate()
	get_root().add_child(root)
	run(root)


func run(root: Node) -> void:
	var v: Vehicle = root.get_node("Vehicle")
	var rec: TelemetryRecorder = root.get_node("TelemetryRecorder")
	var ov: TelemetryOverlay = root.get_node("TelemetryOverlay")
	check(rec.vehicle == v, "recorder.vehicle is the scene Vehicle")
	check(rec.driver_input == root.get_node("DriverInput"), "recorder.driver_input wired")
	check(ov.recorder == rec, "overlay.recorder wired")
	check(root.get_node("ChaseCamera").target == v, "chase camera targets the Vehicle")
	check(root.has_node("Vehicle/Visual"), "VehicleVisual present")
	var shared_spring: float = Vehicle.DEFAULT_DEFINITION.spring_rate
	for i in 240:
		await physics_frame
	check(v.wheels.size() == 4 and v.wheels[0].is_grounded, "car grounded on the Proving Ground")
	check(rec.buffer != null and rec.buffer.count > 200, "recorder buffered %d rows" % rec.buffer.count)
	ov.set_param("spring_rate", shared_spring * 2.0)
	check(v.definition.spring_rate == shared_spring * 2.0, "panel edit reaches the vehicle")
	check(Vehicle.DEFAULT_DEFINITION.spring_rate == shared_spring, "shared default definition untouched")
	check(v.definition != Vehicle.DEFAULT_DEFINITION, "vehicle owns a duplicated definition")
	print("RESULT: ", "OK" if failures == 0 else "FAILED (%d)" % failures)
	quit(1 if failures > 0 else 0)
