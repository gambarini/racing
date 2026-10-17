## Determinism (#81): the same scenario twice in one process gives bit-identical final position
## and speed.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/scenario_determinism_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _main() -> void:
	await physics_frame # let the root finish entering the tree before the first spawn
	var inputs := [{"t": 0.0, "throttle": 1.0}]
	# The first run in a process differs by ~1e-3 m (engine start-up, see powertrain_launch_check),
	# so it is a warm-up; the two runs after it must be bit-identical.
	var warm: Dictionary = await Scenario.new(self, "Spawn_Flat", inputs, 240).run()
	var a: Dictionary = await Scenario.new(self, "Spawn_Flat", inputs, 240).run()
	var b: Dictionary = await Scenario.new(self, "Spawn_Flat", inputs, 240).run()
	print("warm-up vs run 2 position delta %.6f m (informational)" % warm.end_pos.distance_to(a.end_pos))
	cu.check(a.end_pos == b.end_pos and a.end_speed == b.end_speed,
			"identical final position %s / %s and speed %.9f / %.9f" % [a.end_pos, b.end_pos, a.end_speed, b.end_speed])
	cu.finish(self)
