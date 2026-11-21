extends GutTest
## Pure helpers of the Quarry playtest scene (#18 / #192).


func test_parse_args_defaults_when_empty() -> void:
	var a := PlaytestStats.parse_args(PackedStringArray())
	assert_eq(a.mode, "timetrial")
	assert_eq(a.difficulty, "medium")
	assert_eq(a.ai, 5)
	assert_eq(a.laps, 4)
	assert_eq(a.grid, -1)
	assert_eq(a.errors.size(), 0)


func test_parse_args_reads_race_options() -> void:
	var a := PlaytestStats.parse_args(PackedStringArray(["--mode=race", "--difficulty=HARD", "--ai=7",
			"--laps=3", "--grid=2", "--seed=9", "--tester=Ana B"]))
	assert_eq(a.mode, "race")
	assert_eq(a.difficulty, "hard")
	assert_eq(a.ai, 7)
	assert_eq(a.laps, 3)
	assert_eq(a.grid, 2)
	assert_eq(a.seed, 9)
	assert_eq(a.tester, "Ana_B")
	assert_eq(a.errors.size(), 0)
	assert_eq(PlaytestStats.difficulty_enum(a.difficulty), AiPersonality.Difficulty.HARD)


func test_parse_args_rejects_bad_values_and_clamps() -> void:
	var a := PlaytestStats.parse_args(PackedStringArray(["--mode=drift", "--difficulty=insane", "--ai=99",
			"--laps=x", "--grid=50", "--foo=1", "race"]))
	assert_eq(a.mode, "timetrial")
	assert_eq(a.difficulty, "medium")
	assert_eq(a.ai, RaceManager.MAX_CARS - 1, "ai clamped so the field fits RaceManager.MAX_CARS")
	assert_eq(a.laps, 4)
	assert_eq(a.grid, a.ai, "grid clamped to the last slot")
	assert_eq(a.errors.size(), 5)


func test_improvement_needs_six_laps() -> void:
	var r := PlaytestStats.improvement([70.0, 69.0, 68.0, 67.0, 66.0])
	assert_false(r.ready)
	assert_false(r.pass)


func test_improvement_compares_first_and_last_three() -> void:
	var r := PlaytestStats.improvement([72.0, 71.0, 70.0, 69.5, 69.0, 68.0, 68.0, 68.0, 68.0, 68.0])
	assert_true(r.ready)
	assert_almost_eq(r.first3, 71.0, 1e-6)
	assert_almost_eq(r.last3, 68.0, 1e-6)
	assert_almost_eq(r.pct, 3.0 / 71.0 * 100.0, 1e-6)
	assert_true(r.pass, ">= 2 % faster passes")


func test_improvement_slower_or_flat_fails() -> void:
	assert_false(PlaytestStats.improvement([70.0, 70.0, 70.0, 69.5, 69.5, 69.5]).pass, "0.7 % < 2 %")
	assert_true(PlaytestStats.improvement([70.0, 70.0, 70.0, 72.0, 72.0, 72.0]).pct < 0.0)


func test_lap_row_and_result_row() -> void:
	var rec := {"lap": 3, "time": 75.5, "raw_time": 70.5, "penalty": 5.0, "sector_times": [20.0, 25.25, 25.25]}
	assert_eq(PlaytestStats.lap_row("ana", rec, 1), "ana,3,75.500,70.500,5.000,20.000,25.250,25.250,1")
	assert_eq(PlaytestStats.lap_row("ana", {"lap": 1}, 0), "ana,1,0.000,0.000,0.000,,,,0")
	var res := {"rank": 2, "name": "AI 3, Medium", "time": 290.25, "best_lap": 70.1, "penalties": 2.0, "dnf": false}
	assert_eq(PlaytestStats.result_row("ana", "medium", res), "ana,medium,2,AI 3  Medium,290.250,70.100,2.000,false")
	assert_eq(PlaytestStats.LAP_HEADER.split(",").size(), PlaytestStats.lap_row("a", rec, 0).split(",").size())
	assert_eq(PlaytestStats.RESULT_HEADER.split(",").size(), PlaytestStats.result_row("a", "e", res).split(",").size())


func test_format_time() -> void:
	assert_eq(PlaytestStats.format_time(64.381), "1:04.381")
	assert_eq(PlaytestStats.format_time(-1.0), "--")
