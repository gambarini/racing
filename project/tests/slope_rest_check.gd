## Rest on slope (#81): Spawn_Slope (10 deg), handbrake on, zero throttle. After a 3 s settle, over
## the next 10 s the car moves < 2 cm and max speed < 0.02 m/s. CSV: user://slope_rest.csv
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/slope_rest_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _main() -> void:
	await physics_frame # let the root finish entering the tree before the first spawn
	var sc := Scenario.new(self, "Spawn_Slope", [{"t": 0.0, "handbrake": true}], 120 * 13)
	sc.csv_path = "user://slope_rest.csv"
	var r: Dictionary = await sc.run()
	var p0: Vector3 = r.pos[120 * 3 - 1]
	var moved := 0.0
	var vmax := 0.0
	for i in range(120 * 3, r.ticks):
		moved = maxf(moved, (r.pos[i] as Vector3).distance_to(p0))
		vmax = maxf(vmax, r.speed[i])
	var pitch := rad_to_deg(asin(clampf(absf((r.end_basis as Basis).z.y), 0.0, 1.0)))
	cu.check_range("car pitch on the slope (deg, sanity)", pitch, 8.0, 12.0, r.csv)
	cu.check_range("displacement over 10 s after 3 s settle (m)", moved, 0.0, 0.02, r.csv)
	cu.check_range("max speed after settle (m/s)", vmax, 0.0, 0.02, r.csv)
	cu.finish(self)
