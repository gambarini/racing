## Coast-down and off-road speed-loss check (#224, playtest #18: "the speed is not reducing when
## leaving the track on the green surface").
## Flat strips added to the Proving Ground (tarmac, gravel, grass, mud), launched at 25 m/s, no input.
##  A. tarmac, 4 s, powertrain in gear (lift-off): mean deceleration in COAST_DECEL range (a rally car
##     coasting in gear, aero + engine braking + rolling; issue #224 target 0.7..1.0 m/s^2).
##  B. same run with the powertrain disconnected: lift-off engine braking adds at least
##     ENGINE_BRAKE_MIN of deceleration.
##  C. 3 s coast per surface: speed lost on grass >= GRASS_VS_ROAD x tarmac, more than gravel and
##     less than mud (leaving the road clearly costs speed, grass is above gravel, below mud).
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/coast_down_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")
const SPEED := 25.0
const COAST_TICKS := 480
const SURFACE_TICKS := 360
const COAST_DECEL := Vector2(0.7, 1.0) ## m/s^2, 25 m/s flat tarmac in gear (#224)
const ENGINE_BRAKE_MIN := 0.1 ## m/s^2 of lift-off engine braking at 25 m/s (estimate)
const GRASS_VS_ROAD := 1.75 ## grass speed loss at least this multiple of tarmac's (estimate)
const SURFACES: Array[String] = ["tarmac", "gravel", "grass", "mud"]

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _add_strips(world: Node3D) -> void:
	for i in SURFACES.size():
		var id := SURFACES[i]
		var x := -250.0 - 50.0 * i
		var body := StaticBody3D.new()
		body.name = "Strip_" + id
		body.add_to_group("surface_" + id)
		body.set_meta("surface_id", id)
		body.position = Vector3(x, -0.03, -150.0)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(20.0, 0.1, 500.0)
		cs.shape = box
		body.add_child(cs)
		world.add_child(body)
		var m := Marker3D.new()
		m.name = "Spawn_" + id
		m.position = Vector3(x, 0.4, 80.0)
		world.add_child(m)


func _coast(id: String, ticks: int, engine: bool) -> float:
	var sc := Scenario.new(self, "Spawn_" + id, [], ticks)
	sc.initial_speed = SPEED
	sc.world_setup = _add_strips
	if not engine:
		sc.controller = func(_i: int, v: Vehicle, _st: DriverInputState) -> void:
			v.powertrain_enabled = false
			for w in v.wheels:
				w.drive_torque = 0.0
				w.extra_inertia = 0.0
	var r: Dictionary = await sc.run()
	var loss: float = SPEED - r.end_speed
	print("INFO: %s coast %.1f s from %.0f m/s (%s): end %.2f m/s, loss %.2f m/s, mean %.3f m/s^2" % [
			id, ticks / 120.0, SPEED, "in gear" if engine else "no powertrain", r.end_speed, loss, loss / (ticks / 120.0)])
	return loss


func _main() -> void:
	await physics_frame
	var t := COAST_TICKS / 120.0
	var in_gear := await _coast("tarmac", COAST_TICKS, true) / t
	var free := await _coast("tarmac", COAST_TICKS, false) / t
	cu.check_range("A tarmac coast-down 25 m/s in gear, mean decel m/s^2", in_gear, COAST_DECEL.x, COAST_DECEL.y)
	cu.check_range("B lift-off engine braking, m/s^2", in_gear - free, ENGINE_BRAKE_MIN, 10.0)
	var loss := {}
	for id in SURFACES:
		loss[id] = await _coast(id, SURFACE_TICKS, true)
	cu.check_range("C grass / tarmac speed loss ratio", loss.grass / loss.tarmac, GRASS_VS_ROAD, 100.0)
	cu.check(loss.grass > loss.gravel, "C grass loses more than gravel (%.2f > %.2f m/s)" % [loss.grass, loss.gravel])
	cu.check(loss.grass < loss.mud, "C grass loses less than mud (%.2f < %.2f m/s)" % [loss.grass, loss.mud])
	cu.finish(self)
