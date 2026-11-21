## Quarry playtest scene smoke check (#18 / #192): the race mode builds a field of AI cars of the
## chosen difficulty under a RaceManager, runs the countdown and finishes with a results table and
## a results CSV (the idle player car is classified DNF); the time-trial mode builds, reads no
## AI, and writes the lap CSV header. Run:
##   godot --headless --fixed-fps 120 --path project -s res://tests/quarry_playtest_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const SCENE := "res://debug/playtest/quarry_playtest.tscn"
const AI := 3
const MAX_TICKS := 120 * 200

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _make(args: Array) -> Node:
	var pt: Node = (load(SCENE) as PackedScene).instantiate()
	pt.opts = PlaytestStats.parse_args(PackedStringArray(args))
	root.add_child(pt)
	pt.drive.get_node("Vehicle/VehicleAudio").free()
	pt.drive.get_node("TimeTrial").ghost_path = "user://quarry_playtest_check.dat"
	return pt


func _race() -> void:
	var pt: Node = _make(["--mode=race", "--difficulty=hard", "--ai=%d" % AI, "--laps=1", "--tester=check"])
	await physics_frame
	cu.check(pt.mgr != null and pt.mgr.car_count() == AI + 1, "race: %d cars registered" % (AI + 1))
	cu.check(pt.player_id == AI, "race: player on the back slot by default (id %d)" % pt.player_id)
	var hard := AiPersonality.MEAN_SKILL[AiPersonality.Difficulty.HARD]
	var ok := true
	for d: AiDriver in pt.ai_drivers:
		ok = ok and absf(d.personality.skill - minf(hard, AiPersonality.SKILL_CAP)) <= AiPersonality.SKILL_SPREAD + 1e-6
	cu.check(ok, "race: every AI has a Hard personality")
	var t := 0
	var moved := false
	var start: Vector3 = pt.ai_vehicles[0].global_position
	while pt.mgr.state != RaceManager.State.FINISHED and t < MAX_TICKS:
		await physics_frame
		t += 1
		if pt.mgr.state == RaceManager.State.COUNTDOWN and pt.ai_vehicles[0].global_position.distance_to(start) > 0.5:
			moved = true
	cu.check(not moved, "race: AI cars held on the grid during the countdown")
	cu.check(pt.mgr.state == RaceManager.State.FINISHED, "race finished (%d ticks)" % t)
	var finished := 0
	for id: int in pt.ai_ids:
		if pt.mgr.is_finished(id):
			finished += 1
	cu.check(finished == AI, "race: all %d AI finished (%d)" % [AI, finished])
	cu.check(pt.mgr.results.size() == AI + 1, "race: results for every car (%d)" % pt.mgr.results.size())
	var player_dnf := false
	for r: Dictionary in pt.mgr.results:
		if int(r.car) == pt.player_id:
			player_dnf = bool(r.dnf)
	cu.check(player_dnf, "race: idle player is DNF")
	var screen: Node = pt._layer.get_child(pt._layer.get_child_count() - 1)
	cu.check(screen is ResultsScreen and (screen as ResultsScreen).row_count() == AI + 1, "race: results screen shown")
	var path: String = pt.csv_path
	pt.queue_free()
	await physics_frame
	var rows := FileAccess.get_file_as_string(path).strip_edges().split("\n")
	cu.check(rows.size() == AI + 2 and rows[0] == PlaytestStats.RESULT_HEADER, "race: results CSV has header + %d rows (%d lines)" % [AI + 1, rows.size()])
	DirAccess.remove_absolute(path)


func _time_trial() -> void:
	var pt: Node = _make(["--tester=check"])
	await physics_frame
	cu.check(pt.mgr == null and pt.ai_vehicles.is_empty(), "time trial: no race manager, no AI")
	for i in 120:
		await physics_frame
	cu.check(pt.drive.is_physics_processing(), "time trial: QuarryDrive still drives the car")
	var path: String = pt.csv_path
	pt.queue_free()
	await physics_frame
	cu.check(FileAccess.get_file_as_string(path).strip_edges() == PlaytestStats.LAP_HEADER, "time trial: lap CSV header written")
	DirAccess.remove_absolute(path)


func _main() -> void:
	await physics_frame
	await _race()
	await _time_trial()
	for i in 5:
		await process_frame
	cu.finish(self)
