## Reusable physics scenario harness (#81). Loads the Proving Ground, spawns a Vehicle with the
## reference car at a named spawn, steps fixed 120 Hz ticks with a scripted input list and returns
## a result dict. Used by the *_check.gd validation scripts (run with --fixed-fps 120).
##
## inputs: [{t, throttle, brake, handbrake}] sorted by t (seconds). An entry applies from its t until
## the next entry; missing keys default to 0/false. Before the first entry all inputs are zero.
##
## Optional "steer" key (-1..1, + = right). `initial_speed` (m/s) launches the car along its heading
## with rolling wheels. `controller` is an optional Callable(tick: int, v: Vehicle, st: DriverInputState)
## called every tick after the scripted inputs, for closed-loop drivers (e.g. speed hold).
##
## forward_offset: see the var; used for Spawn_Slope.
##
## result also has fwd (Array of Vector3, unit forward) and steer_angle (PackedFloat64Array, rad, mean of
## the two front wheels).
## result: {spawn, ticks, dt, t, pos (Array[Vector3]), speed, rpm, gear, omega (Array of 4-float
## PackedFloat64Array, rad/s), start_pos, end_pos, end_basis, end_speed, csv (path or "")}
extends RefCounted

const PROVING_GROUND := "res://tracks/proving_ground/proving_ground.tscn"
const DT := 1.0 / 120.0
const SPAWN_LIFT := 0.1 ## metres above the marker so the car drops onto its springs

var tree: SceneTree
var spawn := "Spawn_Flat"
var inputs: Array = []
var ticks := 120
## Metres to move along the marker's forward (-Z) before spawning. Non-zero also snaps the car onto
## the ground there (ray cast) and aligns it with the surface normal, keeping its heading.
var forward_offset := 0.0
var initial_speed := 0.0 ## m/s along the heading at t = 0
var controller := Callable()
## Car to drive (#26); null = the reference car. Its `powertrain` field picks the drivetrain.
var car: VehicleDefinition
## Optional Callable(world: Node3D) run right after the track is instanced (e.g. to add a spawn
## marker or a longer surface patch).
var world_setup := Callable()
var csv_path := "" ## "" = no CSV; "user://x.csv" writes the telemetry buffer after the run


func _init(p_tree: SceneTree, p_spawn := "Spawn_Flat", p_inputs: Array = [], p_ticks := 120) -> void:
	tree = p_tree
	spawn = p_spawn
	inputs = p_inputs
	ticks = p_ticks


## Input entry in force at time t (seconds) from the scripted list.
static func input_at(list: Array, t: float) -> Dictionary:
	var cur := {}
	for e in list:
		if float(e.get("t", 0.0)) <= t + 1e-9:
			cur = e
		else:
			break
	return cur


func run() -> Dictionary:
	var world: Node3D = load(PROVING_GROUND).instantiate()
	tree.root.add_child(world)
	if world_setup.is_valid():
		world_setup.call(world)
	var marker: Node3D = world.get_node(spawn)
	var v: Vehicle = load("res://vehicle/vehicle.gd").new()
	var xf := marker.global_transform
	xf.origin += Vector3(0, SPAWN_LIFT, 0)
	if forward_offset != 0.0:
		await tree.physics_frame # let the static colliders register before ray casting
		var from := xf.origin - xf.basis.z * forward_offset + Vector3(0, 20, 0)
		var q := PhysicsRayQueryParameters3D.create(from, from - Vector3(0, 40, 0))
		var hit := world.get_world_3d().direct_space_state.intersect_ray(q)
		assert(not hit.is_empty(), "Scenario: no ground at the offset spawn")
		var up: Vector3 = hit.normal
		var fwd := (-xf.basis.z).slide(up).normalized()
		xf.basis = Basis(fwd.cross(up), up, -fwd)
		xf.origin = hit.position + up * (SPAWN_LIFT + 0.3)
	v.transform = xf
	if car != null:
		v.definition = car
	world.add_child(v)
	if initial_speed != 0.0:
		v.linear_velocity = -v.global_transform.basis.z * initial_speed
		for w in v.wheels:
			w.omega = initial_speed / w.radius
	var rec := TelemetryRecorder.new()
	rec.vehicle = v
	rec.capacity = maxi(ticks + 8, 64)
	tree.root.add_child(rec)
	var out := {"spawn": spawn, "ticks": ticks, "dt": DT, "t": PackedFloat64Array(),
			"pos": [], "fwd": [], "steer_angle": PackedFloat64Array(), "speed": PackedFloat64Array(), "rpm": PackedFloat64Array(),
			"gear": PackedInt32Array(), "omega": [], "start_pos": v.global_position, "csv": ""}
	var st := DriverInputState.new()
	for i in ticks:
		var inp := input_at(inputs, float(i) * DT)
		st.throttle = float(inp.get("throttle", 0.0))
		st.brake = float(inp.get("brake", 0.0))
		st.handbrake = bool(inp.get("handbrake", false))
		st.steer = float(inp.get("steer", 0.0))
		if controller.is_valid():
			controller.call(i, v, st)
		v.apply_input(st)
		await tree.physics_frame
		out.t.append(float(i + 1) * DT)
		out.pos.append(v.global_position)
		out.fwd.append(-v.global_transform.basis.z)
		out.steer_angle.append(0.5 * (v.wheels[0].steer_angle + v.wheels[1].steer_angle))
		out.speed.append(v.linear_velocity.length())
		out.rpm.append(v.rpm())
		out.gear.append(v.gear())
		var om := PackedFloat64Array()
		for w in v.wheels:
			om.append(w.omega)
		out.omega.append(om)
	out.end_pos = v.global_position
	out.end_basis = v.global_transform.basis
	out.end_speed = v.linear_velocity.length()
	if csv_path != "":
		out.csv = rec.dump(csv_path)
	world.queue_free()
	rec.queue_free()
	await tree.physics_frame
	return out
