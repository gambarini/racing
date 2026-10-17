## Handbrake turn (#83): enter at 18 m/s, throttle off, steer +0.6, handbrake on from 0.3 s to
## 1.3 s, steer held. Identical input script on gravel (Spawn_Gravel) and tarmac (Spawn_Flat).
## INFORMATIONAL (design ruling on #83, option b): the gate below is unchanged but a miss prints
## "KNOWN-FAIL #112" and exits 0 until #112 (staged tuning plan) makes it a hard gate again.
## Gate: heading change at t = 3.0 s is >= 90 deg on gravel and tarmac <= 0.6 x gravel.
## CSV on failure: user://handbrake_gravel.csv / user://handbrake_tarmac.csv
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/handbrake_turn_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")

const SPEED := 18.0
const T_MEASURE := 3.0
## The one input script, used unchanged on both surfaces.
const INPUTS := [
	{"t": 0.0, "steer": 0.6},
	{"t": 0.3, "steer": 0.6, "handbrake": true},
	{"t": 1.3, "steer": 0.6},
]

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


## Heading change (deg, + = turned right) at t = T_MEASURE, with the heading unwrapped per tick.
func _run(spawn: String, forward_offset: float, csv: String) -> Dictionary:
	var ticks := int(T_MEASURE / Scenario.DT)
	var sc := Scenario.new(self, spawn, INPUTS, ticks)
	sc.initial_speed = SPEED
	sc.forward_offset = forward_offset
	sc.csv_path = csv
	var r: Dictionary = await sc.run()
	var total := 0.0
	var prev: Vector3 = r.fwd[0]
	for i in range(1, r.ticks):
		var cur: Vector3 = r.fwd[i]
		# Yaw about +Y is counter-clockwise from above; a right turn is negative.
		total += atan2(prev.cross(cur).y, prev.dot(cur))
		prev = cur
	return {"yaw_deg": -rad_to_deg(total), "end_speed": r.end_speed, "csv": r.csv}


func _main() -> void:
	await physics_frame
	# Gravel patch spans z -45..5; start 22 m ahead of the marker so the whole slide stays on it.
	var gravel: Dictionary = await _run("Spawn_Gravel", 22.0, "user://handbrake_gravel.csv")
	var tarmac: Dictionary = await _run("Spawn_Flat", 0.0, "user://handbrake_tarmac.csv")
	print("handbrake turn heading change at 3.0 s: gravel %.1f deg (end speed %.1f), tarmac %.1f deg (end speed %.1f)"
			% [gravel.yaw_deg, gravel.end_speed, tarmac.yaw_deg, tarmac.end_speed])
	var g_ok: bool = gravel.yaw_deg >= 90.0
	var t_ok: bool = tarmac.yaw_deg <= 0.6 * gravel.yaw_deg
	print("gate gravel >= 90 deg: ", "PASS" if g_ok else "FAIL", "; tarmac <= 0.6 x gravel (%.1f deg): " % (0.6 * gravel.yaw_deg),
			"PASS" if t_ok else "FAIL")
	if g_ok and t_ok:
		print("RESULT: OK (gates met; #112 can promote this check to a hard gate)")
	else:
		print("KNOWN-FAIL #112: handbrake turn does not separate gravel from tarmac; csv: ",
				ProjectSettings.globalize_path(tarmac.csv))
		print("RESULT: OK (informational)")
	quit(0)
