extends GutTest
## AI personalities and difficulty (#30), pure logic: ranges, presets and seeded spread, the
## no-cheat guard, trait getters (monotone), the mistake generator and the allocation-free tick.

const DT := 1.0 / 120.0
const MEM_SLACK := 64 * 1024
const CODE := ["res://ai/ai_driver.gd", "res://ai/ai_tactics.gd", "res://ai/ai_personality.gd"]


## Rectangle 400 x 200 m (as in test_ai_driver), +X along the south edge.
func _line() -> RacingLine:
	var pts := PackedVector3Array()
	var corners := [Vector3(-200, 0, 0), Vector3(200, 0, 0), Vector3(200, 0, 200), Vector3(-200, 0, 200)]
	for c in 4:
		var a: Vector3 = corners[c]
		var b: Vector3 = corners[(c + 1) % 4]
		var n := int(a.distance_to(b) / 5.0)
		for i in n:
			pts.append(a.lerp(b, float(i) / n))
	var ones := PackedFloat32Array()
	ones.resize(pts.size())
	ones.fill(1.0)
	var zeros := PackedFloat32Array()
	zeros.resize(pts.size())
	return RacingLine.build(pts, zeros, ones)


func test_traits_are_range_checked() -> void:
	var p := AiPersonality.new()
	p.skill = 1.7
	p.consistency = -0.3
	p.aggression = 9.0
	p.braking_bravery = -1.0
	p.contact_tolerance = 2.0
	assert_eq(p.skill, 1.0)
	assert_eq(p.consistency, 0.0)
	assert_eq(p.aggression, 1.0)
	assert_eq(p.braking_bravery, 0.0)
	assert_eq(p.contact_tolerance, 1.0)
	assert_true(p.is_valid())
	assert_eq(p.effective_skill(), AiPersonality.SKILL_CAP, "skill 1.0 is capped at the verified ceiling")


func test_presets_and_seeded_spread() -> void:
	for d in 3:
		var mean: float = AiPersonality.MEAN_SKILL[d]
		var field := AiPersonality.make_field(d, 8, 1234)
		var again := AiPersonality.make_field(d, 8, 1234)
		var other := AiPersonality.make_field(d, 8, 99)
		var differs := false
		for i in 8:
			assert_between(field[i].skill, mean - 0.03 - 1e-6, mean + 0.03 + 1e-6, "driver %d within +-0.03 of %.3f" % [i, mean])
			assert_true(field[i].effective_skill() <= AiPersonality.SKILL_CAP)
			assert_true(field[i].is_valid())
			assert_eq(field[i].skill, again[i].skill, "same seed, same skill")
			assert_eq(field[i].aggression, again[i].aggression)
			differs = differs or other[i].skill != field[i].skill
		assert_true(differs, "another seed gives other values")
	assert_eq(AiPersonality.MEAN_SKILL, [0.50, 0.594, 0.66])
	assert_lt(AiPersonality.MEAN_SKILL[2] + AiPersonality.SKILL_SPREAD, AiPersonality.SKILL_CAP + 1e-6, "Hard stays under the cap")


func test_no_cheat_grep() -> void:
	var re := RegEx.create_from_string("\\b(v|vehicle|body|car|wheel|w|tire|engine|powertrain|definition)\\s*(\\.\\w+)+\\s*[-+*/]?=[^=]")
	var re_name := RegEx.create_from_string("\\b(mass|friction|grip|tire_mu|torque|power|mu_scale)\\w*\\s*[-+*/]?=[^=]")
	for path: String in CODE:
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			var l := lines[i].strip_edges()
			if l.begins_with("#") or l.begins_with("##"):
				continue
			l = l.split("##")[0]
			assert_null(re.search(l), "%s:%d assigns to a vehicle member: %s" % [path, i + 1, l])
			assert_null(re_name.search(l), "%s:%d assigns a grip/power/mass value: %s" % [path, i + 1, l])


## Circle of radius 100 m (corner speed below v_max, so skill matters).
func _circle() -> RacingLine:
	var pts := PackedVector3Array()
	for i in 120:
		var a := TAU * i / 120.0
		pts.append(Vector3(cos(a) * 100.0, 0.0, sin(a) * 100.0))
	var ones := PackedFloat32Array()
	ones.resize(120)
	ones.fill(1.0)
	var zeros := PackedFloat32Array()
	zeros.resize(120)
	return RacingLine.build(pts, zeros, ones)


func test_personality_driver_setup() -> void:
	var p := AiPersonality.new()
	p.skill = 0.5
	p.braking_bravery = 1.0
	var base := _circle()
	var base_before := base.target_speed.duplicate()
	var ai := AiDriver.new()
	ai.setup_personality(base, p, 5)
	assert_eq(ai.personality, p)
	assert_almost_eq(ai.lead_time, p.brake_lead_min, 1e-6)
	var slow := _min(ai.line.target_speed)
	var fast_ai := AiDriver.new()
	var q := AiPersonality.new()
	q.skill = 0.66
	fast_ai.setup_personality(base, q, 5)
	assert_lt(slow, _min(fast_ai.line.target_speed), "lower skill solves lower corner speeds")
	assert_eq(base.target_speed, base_before, "the source line is not modified")


func _min(a: PackedFloat32Array) -> float: ## sum of the speeds (the corner floor v_min hides a min)
	var m := 0.0
	for x in a:
		m += x
	return m


func test_trait_getters_are_monotone() -> void:
	var last_clear := INF
	var last_gap := -INF
	var last_lead := INF
	var last_brake := INF
	var last_follow := INF
	var ai := AiDriver.new()
	ai.setup(_line())
	var t := AiTactics.new()
	for k in 6:
		var x := k / 5.0
		var p := AiPersonality.new()
		p.aggression = x
		p.braking_bravery = x
		p.contact_tolerance = x
		t.apply_personality(p)
		assert_lt(t.min_overtake_gap(), last_clear, "more aggression = tighter overtake gap")
		assert_gt(t.overtake_gap_s, last_gap, "more aggression = passes started earlier")
		assert_lt(t.follow_dist, last_follow, "more tolerance = follows closer")
		last_clear = t.min_overtake_gap()
		last_gap = t.overtake_gap_s
		last_follow = t.follow_dist
		ai.lead_time = p.brake_lead_time()
		assert_lt(p.brake_lead_time(), last_lead, "braver = shorter look-ahead")
		assert_lt(ai.brake_point_distance(40.0), last_brake, "braver = later brake point")
		last_lead = p.brake_lead_time()
		last_brake = ai.brake_point_distance(40.0)
	assert_almost_eq(AiPersonality.new().brake_lead_time(), 0.25, 1e-6, "default bravery keeps the plain driver's 0.25 s")


func _run_ticks(consistency: float, ticks: int) -> AiDriver:
	var p := AiPersonality.new()
	p.consistency = consistency
	var ai := AiDriver.new()
	ai.setup_personality(_line(), p, 3)
	var st := DriverInputState.new()
	for i in ticks:
		ai.step(Vector3.ZERO, Vector3(1, 0, 0), 30.0, 0.0, DT, st)
	return ai


func test_consistency_one_injects_no_errors() -> void:
	var ai := _run_ticks(1.0, 120 * 600)
	assert_eq(ai.mistakes, 0)
	assert_eq(ai.mistake_factor, 1.0)


func test_low_consistency_makes_seeded_mistakes() -> void:
	var a := _run_ticks(0.2, 120 * 600)
	var b := _run_ticks(0.2, 120 * 600)
	assert_gt(a.mistakes, 5, "mistakes happen at consistency 0.2")
	assert_eq(a.mistakes, b.mistakes, "deterministic from the seed")
	assert_gt(_run_ticks(0.2, 120 * 600).mistakes, _run_ticks(0.8, 120 * 600).mistakes, "lower consistency, more mistakes")


func test_personality_tick_is_allocation_free() -> void:
	var ai := _run_ticks(0.2, 600)
	var st := DriverInputState.new()
	var before := Performance.get_monitor(Performance.MEMORY_STATIC)
	for i in 2000:
		ai.step(Vector3.ZERO, Vector3(1, 0, 0), 30.0, 0.0, DT, st)
	assert_lt(Performance.get_monitor(Performance.MEMORY_STATIC) - before, MEM_SLACK)
