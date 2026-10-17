## AWD vs RWD (#26): identical full-throttle input on a long gravel strip; the AWD car must reach
## 20 m/s at least 15 % faster than the RWD reference car. Also checks the AWD telemetry carries
## drive torque on all four wheels and the RWD car on the rear wheels only.
## The Proving Ground gravel patch is only 50 m long, so the check adds its own 240 m gravel strip.
## CSV: user://awd_gravel_awd.csv / user://awd_gravel_rwd.csv
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/awd_gravel_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")

const TARGET := 20.0 ## m/s
const MIN_GAIN := 1.15
const INPUTS := [{"t": 0.0, "throttle": 1.0}]

var cu := CheckUtil.new()


func _add_strip(world: Node3D) -> void:
	var body := StaticBody3D.new()
	body.name = "Strip_Gravel"
	body.add_to_group("surface_gravel")
	body.set_meta("surface_id", "gravel")
	body.position = Vector3(-170.0, -0.03, -100.0)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 0.1, 240.0)
	cs.shape = box
	body.add_child(cs)
	world.add_child(body)
	var m := Marker3D.new()
	m.name = "Spawn_GravelLong"
	m.position = Vector3(-170.0, 0.4, 15.0)
	world.add_child(m)


## Returns {t20, csv, drive_tq (Array of 4 max |Nm| per wheel), end_speed}
func _run(car: VehicleDefinition, csv: String) -> Dictionary:
	var sc := Scenario.new(self, "Spawn_GravelLong", INPUTS, 120 * 14)
	sc.car = car
	sc.world_setup = _add_strip
	sc.csv_path = csv
	var r: Dictionary = await sc.run()
	var t20 := -1.0
	for i in r.ticks:
		if r.speed[i] >= TARGET:
			t20 = r.t[i]
			break
	var f := FileAccess.open(csv, FileAccess.READ)
	var header := f.get_line().split(",")
	var col := []
	for n in ["fl_drive_tq", "fr_drive_tq", "rl_drive_tq", "rr_drive_tq"]:
		col.append(header.find(n))
	var peak := [0.0, 0.0, 0.0, 0.0]
	while not f.eof_reached():
		var cells := f.get_line().split(",")
		if cells.size() != header.size():
			continue
		for k in 4:
			peak[k] = maxf(peak[k], absf(float(cells[col[k]])))
	return {"t20": t20, "csv": csv, "drive_tq": peak, "end_speed": r.end_speed, "cols": col}


func _initialize() -> void:
	_main()


func _main() -> void:
	await physics_frame
	var rwd_car := load("res://vehicle/definitions/reference_car.tres") as VehicleDefinition
	var awd_car := load("res://vehicle/definitions/awd_car.tres") as VehicleDefinition
	await _run(rwd_car, "user://awd_gravel_warm.csv") # warm-up (first run in a process differs slightly)
	var rwd: Dictionary = await _run(rwd_car, "user://awd_gravel_rwd.csv")
	var awd: Dictionary = await _run(awd_car, "user://awd_gravel_awd.csv")
	print("0-%.0f m/s on gravel: RWD %.2f s, AWD %.2f s, speed gain %.1f %%" % [
			TARGET, rwd.t20, awd.t20, (rwd.t20 / maxf(awd.t20, 1e-6) - 1.0) * 100.0])
	print("peak |drive torque| RWD %s  AWD %s" % [rwd.drive_tq, awd.drive_tq])
	cu.check(rwd.t20 > 0.0 and awd.t20 > 0.0, "both cars reach %.0f m/s within 14 s" % TARGET)
	if rwd.t20 > 0.0 and awd.t20 > 0.0:
		cu.check_range("RWD time / AWD time", rwd.t20 / awd.t20, MIN_GAIN, 10.0, awd.csv)
	cu.check(not (rwd.cols.has(-1) or awd.cols.has(-1)), "telemetry CSV has per-wheel drive torque columns")
	cu.check(rwd.drive_tq[0] == 0.0 and rwd.drive_tq[1] == 0.0 and rwd.drive_tq[2] > 0.0 and rwd.drive_tq[3] > 0.0,
			"RWD drives the rear wheels only")
	var all4 := true
	for k in 4:
		all4 = all4 and awd.drive_tq[k] > 0.0
	cu.check(all4, "AWD telemetry shows drive torque on all four wheels")
	cu.finish(self)
