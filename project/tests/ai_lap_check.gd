## Headless AI lap test (#34): N laps (default 3; AI_LAPS overrides) per track x car, through
## AiDriver and the real RaceManager (standing start). Tracks Quarry and Proving Ground (30 m circle),
## cars M1 RWD and AWD. One summary line per combo, incident gates, lap bounds, determinism, CSV.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/ai_lap_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const Runner := preload("res://tests/support/ai_lap_runner.gd")
const OUT_DIR_ENV := "AI_LAP_OUT" ## directory for the CSVs (CI archives it); default user://
const SCRIPTED_REF := 63.95 ## s, Quarry scripted-driver flying lap (Track-Design wiki)
const MAX_STD := 1.0 ## s (estimate), flying laps (lap 2 onwards)
## Best flying lap bounds (s) per combo, from the first measured baseline (see PR): about -/+ 10 %.
const BOUNDS := {
	"quarry/rwd": Vector2(0.85 * SCRIPTED_REF, 1.25 * SCRIPTED_REF), ## issue #34 criterion; measured 69.7 s
	"quarry/awd": Vector2(62.5, 76.5), ## measured 69.5 s -/+ 10 %
	"proving_ground/rwd": Vector2(16.0, 19.6), ## measured 17.76 s -/+ 10 %
	"proving_ground/awd": Vector2(16.0, 19.6), ## measured 17.76 s -/+ 10 %
}
const COMBOS := [["quarry", "rwd"], ["quarry", "awd"], ["proving_ground", "rwd"], ["proving_ground", "awd"]]

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


static func stats(times: Array) -> Dictionary:
	var n := times.size()
	var best := 1.0e9
	var sum := 0.0
	for t: float in times:
		best = minf(best, t)
		sum += t
	var mean := sum / maxf(n, 1)
	var ss := 0.0
	for t: float in times:
		ss += (t - mean) * (t - mean)
	return {"best": best, "mean": mean, "std": sqrt(ss / maxf(n, 1))}


## Strict XFAIL (design ruling on PR #180, tied to #178): only the incident gates (wrong-way, rejected
## gates, off-track) of these combos are expected to fail. Quarry RWD lap 1 (standing start) leaves the
## road today; #178 tracks the AI fix. Everything else (completion, flying-lap
## bounds, std-dev, CSV, determinism in run_ci.sh) stays enforced. When the gates pass, this check FAILS
## until the entry is removed.
const XFAIL := [] ## #178 fixed by #171 (steer range compensation): quarry/rwd passes the gates now


func _run_pass(runner: Object, laps: int, only: String) -> Dictionary:
	var out := {}
	for combo in COMBOS:
		var key: String = combo[0] + "/" + combo[1]
		if only != "" and not key.begins_with(only):
			continue
		out[key] = await runner.run(combo[0], combo[1], laps)
	return out


func _main() -> void:
	await physics_frame
	var laps := int(OS.get_environment("AI_LAPS")) if OS.get_environment("AI_LAPS") != "" else 3
	var only := OS.get_environment("AI_COMBO") ## debug filter, e.g. "quarry/rwd"
	var runner := Runner.new(self)
	var results: Dictionary = await _run_pass(runner, laps, only)
	var csv_laps := "track,car,lap,ticks,seconds\n"
	var csv_sum := "track,car,laps,best,mean,std,flying_std,wrong_way,rejected_gates,off_track,contacts,resets,wall_s\n"
	var total_wall := 0
	var off_max := ceili(2.0 * laps / 3.0)
	for key: String in results:
		var r: Dictionary = results[key]
		var parts := key.split("/")
		total_wall += r.wall_ms
		var times: Array = []
		var flying: Array = [] ## laps 2.. (lap 1 is the standing start)
		for i in r.lap_ticks.size():
			var t: float = r.lap_ticks[i] / 120.0
			times.append(t)
			if i > 0:
				flying.append(t)
			csv_laps += "%s,%s,%d,%d,%.4f\n" % [parts[0], parts[1], i + 1, r.lap_ticks[i], t]
		var st := stats(times)
		var fl := stats(flying)
		var lap_txt := ""
		for t: float in times:
			lap_txt += "%.2f " % t
		print("SUMMARY %s laps=%d/%d [ %s] best %.2f mean %.2f std %.2f (flying std %.2f) | wrong-way %d rejected-gates %d off-track %d contacts %d resets %d | runtime %.1f s" % [
				key, times.size(), laps, lap_txt, st.best, st.mean, st.std, fl.std, r.wrong_way, r.rejected_gates, r.off_track,
				r.contacts, r.resets, r.wall_ms / 1000.0])
		csv_sum += "%s,%s,%d,%.4f,%.4f,%.4f,%.4f,%d,%d,%d,%d,%d,%.2f\n" % [parts[0], parts[1], times.size(), st.best, st.mean, st.std,
				fl.std, r.wrong_way, r.rejected_gates, r.off_track, r.contacts, r.resets, r.wall_ms / 1000.0]
		cu.check(r.finished, "%s completes %d laps (%d)" % [key, laps, times.size()])
		if XFAIL.has(key):
			var clean: bool = r.wrong_way == 0 and r.rejected_gates == 0 and r.off_track <= off_max
			print("XFAIL (#178) %s lap-1 incidents: wrong-way %d, rejected gates %d, off-track %d (limit %d)" % [
					key, r.wrong_way, r.rejected_gates, r.off_track, off_max])
			cu.check(not clean, "%s XFAIL gates unexpectedly pass: remove XFAIL (#178)" % key)
		else:
			cu.check(r.wrong_way == 0, "%s: zero wrong-way flags (%d)" % [key, r.wrong_way])
			cu.check(r.rejected_gates == 0, "%s: zero rejected gates (%d)" % [key, r.rejected_gates])
			cu.check(r.off_track <= off_max, "%s: off-track events %d <= %d" % [key, r.off_track, off_max])
		if flying.size() >= 2:
			cu.check_range("%s flying-lap std-dev (s)" % key, fl.std, 0.0, MAX_STD)
		if BOUNDS.has(key) and flying.size() >= 1:
			var b: Vector2 = BOUNDS[key]
			for t: float in flying:
				cu.check_range("%s flying lap (s)" % key, t, b.x, b.y)
	var dir := OS.get_environment(OUT_DIR_ENV)
	if dir == "":
		dir = "user://"
	else:
		DirAccess.make_dir_recursive_absolute(dir)
	var p_laps := dir.path_join("ai_lap_laps.csv")
	var p_sum := dir.path_join("ai_lap_summary.csv")
	_write(p_laps, csv_laps)
	_write(p_sum, csv_sum)
	print("CSV: ", ProjectSettings.globalize_path(p_laps), " and ", ProjectSettings.globalize_path(p_sum))
	# In-process second pass: every run lives in its own physics space (ai_lap_runner), so the lap ticks
	# must be bit-identical (#179; the run index used to drift them by 1-2 ticks). AI_DET=0 skips it.
	if OS.get_environment("AI_DET") != "0":
		var again: Dictionary = await _run_pass(runner, laps, only)
		for key: String in results:
			total_wall += again[key].wall_ms
			cu.check(results[key].lap_ticks == again[key].lap_ticks and results[key].ticks == again[key].ticks,
					"%s deterministic: identical lap ticks across two passes (%s vs %s)" % [key, results[key].lap_ticks, again[key].lap_ticks])
	print("INFO: total runtime %.1f s (timed runs)" % (total_wall / 1000.0))
	for i in 5:
		await process_frame
	cu.finish(self)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		cu.check(false, "cannot write " + path)
		return
	f.store_string(text)
