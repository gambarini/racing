## Quarry runs are independent inside one process (#179): the same AI laps (Quarry, AWD, fresh
## QuarryDrive each run) must give bit-identical lap ticks on every run.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/quarry_independence_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const Runner := preload("res://tests/support/ai_lap_runner.gd")
const RUNS := 5

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _main() -> void:
	await physics_frame
	var runner := Runner.new(self)
	var laps := int(OS.get_environment("IND_LAPS")) if OS.get_environment("IND_LAPS") != "" else 2
	var car := OS.get_environment("IND_CAR") if OS.get_environment("IND_CAR") != "" else "awd"
	var first: Dictionary = {}
	for i in RUNS:
		var r: Dictionary = await runner.run("quarry", car, laps)
		print("RUN %d lap ticks %s total %d" % [i, r.lap_ticks, r.ticks])
		if i == 0:
			first = r
		else:
			cu.check(r.lap_ticks == first.lap_ticks and r.ticks == first.ticks,
					"run %d identical to run 0 (%s vs %s)" % [i, r.lap_ticks, first.lap_ticks])
	for i in 5:
		await process_frame
	cu.finish(self)
