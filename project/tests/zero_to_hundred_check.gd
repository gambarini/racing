## 0-100 km/h (#81): full throttle from rest on flat tarmac, auto gearbox. Target 6.5 s +/-10 %
## (wiki Vehicle Physics Design, reference car). CSV: user://zero_to_100.csv
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/zero_to_hundred_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _main() -> void:
	await physics_frame # let the root finish entering the tree before the first spawn
	var sc := Scenario.new(self, "Spawn_Flat", [{"t": 0.0, "throttle": 1.0}], 120 * 14)
	sc.csv_path = "user://zero_to_100.csv"
	var r: Dictionary = await sc.run()
	var t100 := 99.0 # never reached
	for i in r.ticks:
		if r.speed[i] >= 100.0 / 3.6:
			t100 = r.t[i]
			break
	var gears: Array = []
	for g in r.gear:
		if gears.is_empty() or gears[-1] != g:
			gears.append(g)
	print("gear sequence: ", gears)
	cu.check_range("0-100 km/h time (s)", t100, 5.85, 7.15, r.csv)
	cu.finish(self)
