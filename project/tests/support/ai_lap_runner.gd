## Headless AI lap runner (#34): drives one car through AiDriver around a track under the real
## RaceManager (standing start, countdown, lap timers) and returns lap times and incident counts.
## Tracks: "quarry" (QuarryDrive scene, shipped racing line) and "proving_ground" (the 30 m tarmac
## circle in the Proving Ground, a lap loop built here in code: TrackSpline + RacingLine, no assets).
## The Proving Ground loop is a test-only stand-in until the real Proving Ground lap track exists.
## Sim only: no audio, camera or HUD. Run from a SceneTree script with --fixed-fps 120.
extends RefCounted

const QUARRY_SCENE := "res://tracks/quarry/quarry_drive.tscn"
const QUARRY_LINE := "res://tracks/quarry/quarry_racing_line.tres"
const PROVING_GROUND := "res://tracks/proving_ground/proving_ground.tscn"
const CAR_RWD := "res://vehicle/definitions/reference_car.tres"
const CAR_AWD := "res://vehicle/definitions/awd_car.tres"
const PG_CENTRE := Vector3(-100.0, 0.0, 100.0) ## Circle node origin in proving_ground.tscn
const PG_RADIUS := 30.0
const PG_HALF_WIDTH := 4.0 ## metadata/width = 8
const PG_GATES := 8
const PG_SPAWN_LIFT := 0.5
const MAX_SECONDS := 400.0 ## per run safety cap (sim seconds)

var tree: SceneTree
var trace := OS.get_environment("AI_TRACE") != ""


class Pilot extends Node:
	## Applies AI -> pre-GO lock -> vehicle each tick, after the vehicle and the scene's own driver.
	var ai: AiDriver
	var vehicle: Vehicle
	var mgr: RaceManager
	var state := DriverInputState.new()

	func _init() -> void:
		process_physics_priority = 20

	func _physics_process(delta: float) -> void:
		ai.drive(vehicle, state, delta)
		mgr.gate_input(state)
		vehicle.apply_input(state)


func _init(p_tree: SceneTree) -> void:
	tree = p_tree


## Runs `laps` laps of `track` ("quarry" | "proving_ground") with `car` ("rwd" | "awd").
## Returns {lap_ticks: PackedInt32Array, ticks, wrong_way, rejected_gates, off_track, off_ticks,
## contacts, resets, finished, wall_ms}.
func run(track: String, car: String, laps: int, max_seconds := MAX_SECONDS) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var def := load(CAR_AWD if car == "awd" else CAR_RWD) as VehicleDefinition
	var world: Node3D
	var space := _new_space()
	var v: Vehicle
	var spline: TrackSpline
	var line: RacingLine
	var off_track: Callable
	if track == "quarry":
		var drive: QuarryDrive = (load(QUARRY_SCENE) as PackedScene).instantiate()
		drive.get_node("Vehicle/VehicleAudio").free()
		drive.get_node("TimeTrial").ghost_path = "user://ai_lap_check_ghost.dat"
		drive.get_node("TimeTrial").process_mode = Node.PROCESS_MODE_DISABLED # no ghost files: runs must be independent
		space.add_child(drive)
		await tree.physics_frame
		world = drive
		v = drive.vehicle
		spline = drive.quarry.track
		line = load(QUARRY_LINE)
		if car == "awd":
			v.set_car(def)
		drive.place_on_grid(0)
		off_track = func() -> bool:
			for w in v.wheels:
				if w.is_grounded and w.surface_id == &"grass":
					return true
			return false
	else:
		world = (load(PROVING_GROUND) as PackedScene).instantiate()
		space.add_child(world)
		spline = make_pg_track()
		world.add_child(spline)
		line = make_pg_line()
		v = load("res://vehicle/vehicle.gd").new()
		v.definition = def
		v.transform = Transform3D(Basis.IDENTITY, Vector3(0, 100, 0))
		world.add_child(v)
		await tree.physics_frame
		off_track = func() -> bool:
			var d := Vector2(v.global_position.x - PG_CENTRE.x, v.global_position.z - PG_CENTRE.z).length()
			return absf(d - PG_RADIUS) > PG_HALF_WIDTH
	var mgr := RaceManager.new()
	mgr.setup(spline, laps)
	mgr.joker_required = false
	world.add_child(mgr)
	var id := mgr.add_car(v, "AI")
	if track != "quarry":
		var grid := mgr.grid_transform(0, 1)
		grid.origin.y = PG_SPAWN_LIFT
		v.global_transform = grid
		v.linear_velocity = Vector3.ZERO
	var ai := AiDriver.new()
	ai.setup(line, 0)
	var pilot := Pilot.new()
	pilot.ai = ai
	pilot.vehicle = v
	pilot.mgr = mgr
	world.add_child(pilot)
	mgr.race_started.connect(ai.reset)
	# Incident counters.
	var contacts := [0]
	v.contact_monitor = true
	v.max_contacts_reported = 4
	v.body_entered.connect(func(_b: Node) -> void: contacts[0] += 1)
	var wrong := WrongWayDetector.new()
	var wrong_events := 0
	var was_wrong := false
	var off_events := 0
	var off_ticks := 0
	var was_off := false
	mgr.start_countdown()
	var timer := mgr.timers[id]
	var ticks := 0
	var cap := int(max_seconds * 120.0)
	while timer.laps.size() < laps and ticks < cap:
		await tree.physics_frame
		ticks += 1
		if mgr.state != RaceManager.State.RACING:
			continue
		if trace and ticks % 240 == 0:
			print("TRACE t=%.0f s=%.0f spd=%.1f tgt=%.1f ct=%.1f gate=%d pos=%s" % [ticks / 120.0, ai.s, ai.speed_now, ai.target_speed, ai.cross_track, timer.last_gate_crossed, v.global_position])
		var is_wrong := wrong.step(v.linear_velocity, spline.forward_at(spline.nearest_offset(v.global_position)))
		if is_wrong and not was_wrong:
			wrong_events += 1
		was_wrong = is_wrong
		var is_off: bool = off_track.call()
		if is_off:
			off_ticks += 1
			if not was_off:
				off_events += 1
		was_off = is_off
	var lap_ticks := PackedInt32Array()
	for l in timer.laps:
		lap_ticks.append(l["ticks"])
	var resets := 0
	for e in mgr.ledger:
		if e["reason"] == RaceManager.RESET_REASON:
			resets += 1
	var out := {"lap_ticks": lap_ticks, "ticks": ticks, "wrong_way": wrong_events,
			"rejected_gates": timer.out_of_order_crossings, "off_track": off_events, "off_ticks": off_ticks,
			"contacts": contacts[0], "resets": resets, "finished": timer.laps.size() >= laps,
			"wall_ms": Time.get_ticks_msec() - t0}
	space.queue_free()
	await tree.physics_frame
	return out


## Every run lives in its own SubViewport with its own World3D, so its own physics space. Jolt orders
## contact pairs by body id (index + reuse sequence number) and ids come from a per-space free list,
## so bodies freed by an earlier run in a shared space change the contact order, and with it the last
## bits of the solver result, of the next run (#179).
func _new_space() -> SubViewport:
	var sv := SubViewport.new()
	sv.own_world_3d = true
	sv.size = Vector2i(2, 2)
	sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	tree.root.add_child(sv)
	return sv


## Closed circle of the Proving Ground, counter-clockwise (left-hand) from its +X point, 8 gates.
func make_pg_track() -> TrackSpline:
	var ts := TrackSpline.new()
	var c := Curve3D.new()
	var k := 64
	for i in k + 1:
		var a := TAU * float(i) / k
		c.add_point(Vector3(PG_RADIUS * cos(a), 0.03, -PG_RADIUS * sin(a)))
	c.bake_interval = 0.5
	ts.centre_line = c
	var l := c.get_baked_length()
	var offs := PackedFloat32Array()
	for i in PG_GATES:
		offs.append(l * float(i) / PG_GATES)
	ts.gate_offsets = offs
	ts.position = PG_CENTRE
	return ts


## Racing line around the circle: constant curvature, target speeds from the shared solver.
func make_pg_line() -> RacingLine:
	var n := 64
	var out := RacingLine.new()
	var ds := PackedFloat32Array()
	var kappa := PackedFloat32Array()
	var mu := PackedFloat32Array()
	var step := TAU * PG_RADIUS / n
	for i in n:
		var a := TAU * float(i) / n
		out.s.append(step * i)
		out.pos.append(PG_CENTRE + Vector3(PG_RADIUS * cos(a), 0.03, -PG_RADIUS * sin(a)))
		out.lane_offset.append(0.0)
		kappa.append(-1.0 / PG_RADIUS) # + = right; the loop turns left
		mu.append(1.0)
		ds.append(step)
	out.curvature = kappa
	out.surface_mu = mu
	out.length = TAU * PG_RADIUS
	out.target_speed = RacingLineSolver.solve(kappa, ds, mu, RacingLineParams.new())
	return out
