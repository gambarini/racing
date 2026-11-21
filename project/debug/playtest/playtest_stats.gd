## Pure helpers for the Quarry playtest scene (#18 / #192): launch-argument parsing, the 10-lap
## improvement metric and CSV rows. No node access, so they are unit-tested in
## tests/test_playtest_stats.gd.
class_name PlaytestStats
extends RefCounted

const MODES := ["timetrial", "race"]
const DIFFICULTIES := {"easy": AiPersonality.Difficulty.EASY, "medium": AiPersonality.Difficulty.MEDIUM,
		"hard": AiPersonality.Difficulty.HARD}
const MAX_AI := RaceManager.MAX_CARS - 1
const DEFAULTS := {"mode": "timetrial", "difficulty": "medium", "ai": 5, "laps": 4, "grid": -1,
		"seed": 2026, "tester": "tester"}
const IMPROVEMENT_TARGET_PCT := 2.0 ## #18: last-3 mean at least 2 % faster than first-3 mean (estimate)


## Parses `--key=value` user args (after `--` on the Godot command line). Unknown keys and bad
## values fall back to DEFAULTS; `errors` lists what was ignored. grid -1 = back of the grid.
static func parse_args(args: PackedStringArray) -> Dictionary:
	var out := DEFAULTS.duplicate()
	var errors: Array[String] = []
	for a in args:
		if not a.begins_with("--") or not a.contains("="):
			errors.append("ignored '%s' (expected --key=value)" % a)
			continue
		var key := a.substr(2, a.find("=") - 2).to_lower()
		var val := a.substr(a.find("=") + 1)
		match key:
			"mode":
				if MODES.has(val.to_lower()):
					out.mode = val.to_lower()
				else:
					errors.append("mode must be one of %s" % str(MODES))
			"difficulty":
				if DIFFICULTIES.has(val.to_lower()):
					out.difficulty = val.to_lower()
				else:
					errors.append("difficulty must be easy, medium or hard")
			"ai", "laps", "grid", "seed":
				if not val.is_valid_int():
					errors.append("%s must be an integer" % key)
				else:
					out[key] = val.to_int()
			"tester":
				var clean := val.validate_filename().replace(" ", "_")
				if clean != "":
					out.tester = clean
			_:
				errors.append("unknown option --%s" % key)
	out.ai = clampi(out.ai, 1, MAX_AI)
	out.laps = clampi(out.laps, 1, 20)
	if out.grid >= 0:
		out.grid = mini(out.grid, out.ai) # slot index in a field of ai + 1 cars
	out["errors"] = errors
	return out


static func difficulty_enum(name: String) -> AiPersonality.Difficulty:
	return DIFFICULTIES.get(name, AiPersonality.Difficulty.MEDIUM)


static func _mean(xs: Array) -> float:
	var m := 0.0
	for x: float in xs:
		m += x
	return m / maxf(xs.size(), 1)


## #18 10-lap improvement: mean of the first 3 vs the last 3 lap times (s). Needs 6+ laps;
## `pct` > 0 means the last laps were faster. Laps with penalties/resets should be passed in
## already (the caller decides whether to keep them).
static func improvement(times: Array) -> Dictionary:
	if times.size() < 6:
		return {"ready": false, "first3": 0.0, "last3": 0.0, "pct": 0.0, "pass": false}
	var first := _mean(times.slice(0, 3))
	var last := _mean(times.slice(times.size() - 3))
	var pct := (first - last) / first * 100.0 if first > 0.0 else 0.0
	return {"ready": true, "first3": first, "last3": last, "pct": pct, "pass": pct >= IMPROVEMENT_TARGET_PCT}


static func format_time(seconds: float) -> String:
	if seconds < 0.0:
		return "--"
	var m := int(seconds) / 60
	return "%d:%06.3f" % [m, seconds - m * 60]


const LAP_HEADER := "tester,lap,time_s,raw_time_s,penalty_s,sector1_s,sector2_s,sector3_s,resets_so_far"


## One CSV row for a LapTimer lap record (see LapTimer._accept for the keys).
static func lap_row(tester: String, rec: Dictionary, resets: int) -> String:
	var secs: Array = rec.get("sector_times", [])
	var s := ["", "", ""]
	for i in mini(secs.size(), 3):
		s[i] = "%.3f" % float(secs[i])
	return "%s,%d,%.3f,%.3f,%.3f,%s,%s,%s,%d" % [tester, int(rec.get("lap", 0)), float(rec.get("time", 0.0)),
			float(rec.get("raw_time", 0.0)), float(rec.get("penalty", 0.0)), s[0], s[1], s[2], resets]


const RESULT_HEADER := "tester,difficulty,rank,driver,time_s,best_lap_s,penalties_s,dnf"


## One CSV row for a RaceManager.race_finished result entry.
static func result_row(tester: String, difficulty: String, r: Dictionary) -> String:
	return "%s,%s,%d,%s,%.3f,%.3f,%.3f,%s" % [tester, difficulty, int(r.get("rank", 0)),
			str(r.get("name", "")).replace(",", " "), float(r.get("time", -1.0)), float(r.get("best_lap", -1.0)),
			float(r.get("penalties", 0.0)), str(bool(r.get("dnf", false)))]
