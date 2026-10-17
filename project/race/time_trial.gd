class_name TimeTrial
extends Node
## Time trial with ghost (issue #25). Observes the LapTimer stepped by the RaceMonitor, so place
## this node AFTER the RaceMonitor in the tree. Records pose at 60 Hz plus the applied driver
## input each lap; on lap completion saves the lap as the best ghost when it is valid (no reset
## penalty, no out-of-order gate crossing) and faster than the stored best. The ghost replays
## the best lap from the lap start; it has no collision (a plain Node3D with a mesh).
## `observe()` is also callable without the Node plumbing (tests).

signal lap_finished(ticks: int, valid: bool, saved: bool)

@export var ghost_path := "user://ghost_best.dat"
var vehicle: Vehicle
var timer: LapTimer
var track_id := ""
var best: GhostLap = null
var ghost: Node3D = null
var ghost_visible := true

var _rec: GhostLap = null
var _rec_tick := 0
var _was_running := false
var _laps_seen := 0
var _oor_at_start := 0
var _replay_tick := -1  ## -1 = not replaying


func setup(p_vehicle: Vehicle, p_timer: LapTimer, p_track_id := "") -> void:
	vehicle = p_vehicle
	timer = p_timer
	track_id = p_track_id
	_laps_seen = timer.laps.size()
	_was_running = timer.running
	var loaded := GhostLap.load_file(ghost_path)
	if loaded != null and loaded.track_id == track_id:
		if loaded.tick_hz == Engine.physics_ticks_per_second:
			best = loaded
		else:
			# Replay advances one recorded tick per physics tick: a different rate would run the ghost at the wrong speed.
			push_warning("Ghost recorded at %d Hz, playback is %d Hz: ignoring it" % [loaded.tick_hz, Engine.physics_ticks_per_second])
	if ghost == null:
		ghost = _make_ghost_node()
		add_child(ghost)
		ghost.visible = false


func _physics_process(_delta: float) -> void:
	if vehicle == null or timer == null:
		return
	observe(vehicle.global_transform, vehicle.steer, vehicle.throttle, vehicle.brake, vehicle.handbrake)


## Call once per physics tick AFTER the timer was stepped with the same position.
func observe(xf: Transform3D, steer: float, throttle: float, brake: float, handbrake: bool) -> void:
	var completed := timer.laps.size() > _laps_seen
	if completed:
		_laps_seen = timer.laps.size()
		_finish_lap(xf, steer, throttle, brake, handbrake)
	var started := timer.running and (completed or not _was_running)
	_was_running = timer.running
	if started:
		_rec = GhostLap.new()
		_rec.track_id = track_id
		_rec.tick_hz = Engine.physics_ticks_per_second
		_rec_tick = 0
		_oor_at_start = timer.out_of_order_crossings
		_replay_tick = 0 if best != null else -1
	elif _rec != null:
		_rec_tick += 1
		if _replay_tick >= 0:
			_replay_tick += 1
	if _rec != null and timer.running:
		var every := maxi(_rec.tick_hz / GhostLap.SAMPLE_HZ, 1)
		if _rec_tick % every == 0:
			_rec.add_sample(xf, steer, throttle, brake, handbrake)
	_update_ghost()


func _finish_lap(xf: Transform3D, steer: float, throttle: float, brake: float, handbrake: bool) -> void:
	if _rec == null:
		return
	var rec_dict := timer.laps[timer.laps.size() - 1]
	var valid: bool = float(rec_dict["penalty"]) <= 0.0 and timer.out_of_order_crossings == _oor_at_start
	var saved := false
	_rec.ticks = _rec_tick + 1
	if valid and _rec.sample_count() > 1 and (best == null or _rec.ticks < best.ticks):
		_rec.add_sample(xf, steer, throttle, brake, handbrake)  # exact final pose
		best = _rec
		saved = best.save(ghost_path)
	lap_finished.emit(_rec.ticks, valid, saved)
	_rec = null


func _update_ghost() -> void:
	if ghost == null:
		return
	ghost.visible = ghost_visible and best != null and _replay_tick >= 0
	if ghost.visible:
		ghost.global_transform = best.pose_at_tick(_replay_tick)


func _make_ghost_node() -> Node3D:
	var n := Node3D.new()
	n.name = "Ghost"
	n.top_level = true
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.8, 1.2, 4.2)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.4, 0.8, 1.0, 0.35)
	mi.material_override = mat
	mi.position.y = 0.6
	n.add_child(mi)
	return n
