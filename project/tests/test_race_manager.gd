extends GutTest
## RaceManager core (#149), driven by teleporting scripted cars along a circular test track:
## grid layout, countdown/GO, input lock, jump start, live positions, gap, finish and DNF.
## Deterministic: no physics, only step() with computed positions.

const DT := 1.0 / 120.0
const CAR_W := 1.8
const CAR_L := 4.2

var _track: TrackSpline
var _len := 0.0


func before_each() -> void:
	_track = TrackSpline.make_circle(100.0, 8)
	add_child_autofree(_track)
	_len = _track.length()


## Scripted field: constant speeds along the line after GO, started from the grid slots.
class Field:
	var mgr: RaceManager
	var track: TrackSpline
	var n := 0
	var s: PackedFloat64Array = PackedFloat64Array()
	var lat: PackedFloat64Array = PackedFloat64Array()
	var v: PackedFloat64Array = PackedFloat64Array()  ## speed after GO
	var stop_s: PackedFloat64Array = PackedFloat64Array()  ## cars stop here (INF = never)
	var pos := PackedVector3Array()
	var spd := PackedFloat32Array()
	var pre_go_drift: PackedFloat64Array = PackedFloat64Array()  ## total metres moved during the countdown

	func _init(p_mgr: RaceManager, p_track: TrackSpline, p_n: int, speeds: Array) -> void:
		mgr = p_mgr
		track = p_track
		n = p_n
		var spacing := minf(RaceManager.GRID_ROW_SPACING, RaceManager.GRID_ZONE_BEHIND / n)
		for i in n:
			mgr.add_car()
			s.append(-spacing * (i + 1))
			lat.append(RaceManager.GRID_LATERAL if i % 2 == 0 else -RaceManager.GRID_LATERAL)
			v.append(speeds[i])
			stop_s.append(INF)
			pre_go_drift.append(0.0)
			pos.append(Vector3.ZERO)
			spd.append(0.0)
		_place()

	func _place() -> void:
		for i in n:
			var fwd := track.forward_at(s[i])
			pos[i] = track.position_at(s[i]) + fwd.cross(Vector3.UP) * lat[i]

	## Advance the scripted cars one tick, then the manager.
	func tick() -> void:
		var racing := mgr.state == RaceManager.State.RACING or mgr.state == RaceManager.State.FINISHED
		for i in n:
			if racing:
				if s[i] < stop_s[i]:
					s[i] = minf(s[i] + v[i] / 120.0, stop_s[i])
				spd[i] = v[i] if s[i] < stop_s[i] else 0.0
			else:
				s[i] += pre_go_drift[i] / 360.0 if mgr.state == RaceManager.State.COUNTDOWN else 0.0
		_place()
		mgr.step(pos, spd)


func _make(n: int, speeds: Array, laps := 2) -> Field:
	var mgr := RaceManager.new()
	add_child_autofree(mgr)
	mgr.setup(_track, laps)
	return Field.new(mgr, _track, n, speeds)


func _box_clearance(a: Transform3D, b: Transform3D) -> float:
	var rel := a.affine_inverse() * b.origin
	return maxf(absf(rel.x) - CAR_W, absf(rel.z) - CAR_L)


func test_grid_slots_fit_zone_and_do_not_overlap() -> void:
	var mgr := RaceManager.new()
	add_child_autofree(mgr)
	mgr.setup(_track)
	for count in [2, 8, 12]:
		for i in count:
			var xf := mgr.grid_transform(i, count)
			var fwd := _track.forward_at(-1.0 * (i + 1))
			var s := _track.nearest_offset(xf.origin)
			var signed_s := s - _len if s > _len * 0.5 else s
			assert_between(signed_s, -80.0 + 2.1, 60.0, "slot %d of %d inside the flat zone (s=%.1f)" % [i, count, signed_s])
			assert_almost_eq(-xf.basis.z.dot(_track.forward_at(signed_s)), 1.0, 0.01, "slot faces the tangent")
			assert_true(fwd.is_finite())
			for j in range(i + 1, count):
				var c := _box_clearance(xf, mgr.grid_transform(j, count))
				assert_gt(c, 0.5, "clearance slot %d/%d of %d = %.2f m" % [i, j, count, c])
	# Rows are 8 m apart for 8 cars, alternating sides.
	var a := mgr.grid_transform(0, 8).origin
	var b := mgr.grid_transform(1, 8).origin
	assert_almost_eq(a.distance_to(b), sqrt(64.0 + 36.0), 0.2, "8 m rows, +/-3 m stagger")


func test_max_twelve_cars() -> void:
	var mgr := RaceManager.new()
	add_child_autofree(mgr)
	mgr.setup(_track)
	for i in 12:
		assert_eq(mgr.add_car(), i)
	assert_eq(mgr.add_car(), -1)


func test_countdown_go_and_input_lock() -> void:
	var f := _make(8, [40, 40, 40, 40, 40, 40, 40, 40])
	var m := f.mgr
	var counts: Array[int] = []
	var count_ticks: Array[int] = []
	var started: Array[int] = []
	m.countdown_tick.connect(func(n: int) -> void:
		counts.append(n)
		count_ticks.append(m.tick))
	m.race_started.connect(func() -> void: started.append(m.tick))
	var st := DriverInputState.new()
	st.throttle = 1.0
	st.brake = 0.3
	m.gate_input(st)
	assert_true(st.handbrake and st.throttle == 0.0 and st.brake == 0.0, "locked before the countdown")
	m.start_countdown()
	for i in 200:
		f.tick()
	assert_true(m.inputs_locked())
	st.throttle = 1.0
	st.handbrake = false
	m.gate_input(st)
	assert_true(st.handbrake and st.throttle == 0.0, "inputs ignored during the countdown")
	for t in m.timers:
		assert_false(t.running, "timers idle until GO")
	for i in 300:
		f.tick()
	assert_eq(counts, [3, 2, 1] as Array[int])
	assert_eq(count_ticks[1] - count_ticks[0], 120, "1.0 s per count")
	assert_eq(count_ticks[2] - count_ticks[1], 120)
	assert_eq(started.size(), 1)
	assert_eq(started[0] - count_ticks[0], 360, "GO 3.0 s after the first count")
	assert_eq(m.go_tick, started[0])
	assert_eq(m.state, RaceManager.State.RACING)
	var t0 := m.timers[0].tick
	for t in m.timers:
		assert_true(t.running, "start_standing() on every timer")
		assert_eq(t.tick, t0, "all timers on the same tick")
		assert_eq(t.current_lap_ticks(), m.tick - m.go_tick)
	st.throttle = 1.0
	st.handbrake = false
	m.gate_input(st)
	assert_true(st.throttle == 1.0 and not st.handbrake, "inputs free after GO")


func test_jump_start_flag_and_penalty() -> void:
	var f := _make(8, [40, 40, 40, 40, 40, 40, 40, 40])
	var m := f.mgr
	f.pre_go_drift[5] = 1.0  # > 0.5 m before GO
	f.pre_go_drift[6] = 0.4  # within tolerance
	m.start_countdown()
	for i in 380:
		f.tick()
	for i in 8:
		assert_eq(m.jump_started[i], i == 5, "jump flag of car %d" % i)
	assert_eq(m.ledger.size(), 1)
	assert_eq(m.ledger[0]["car"], 5)
	assert_eq(m.ledger[0]["reason"], &"jump_start")
	assert_eq(m.ledger[0]["seconds"], 5.0)
	assert_eq(m.penalty_seconds[5], 5.0)
	assert_eq(m.penalty_seconds[6], 0.0)


func test_start_order_gap_and_tie_break() -> void:
	var f := _make(4, [4.0, 10.0, 0.0, 0.0])
	var m := f.mgr
	m.start_countdown()
	for i in 365:
		f.tick()
	assert_eq(m.state, RaceManager.State.RACING)
	for i in 4:
		assert_eq(m.position_of(i), i + 1, "grid order = slot order")
	assert_eq(m.gap_ahead(0), -1.0, "leader has no gap")
	# Cars move on: 0 at 4 m/s (floored to 5), 1 at 10 m/s, rows 8 m apart (initially).
	var d1 := m.total_s[0] - m.total_s[1]
	assert_almost_eq(m.gap_ahead(1), d1 / 10.0, 1e-6, "gap = distance / speed")
	assert_gt(d1, 0.0)
	# Slow car 0 vs the floor: the gap of the car behind uses its own speed.
	f.spd[1] = 2.0
	f.v[1] = 2.0
	f.tick()
	assert_almost_eq(m.gap_ahead(1), (m.total_s[0] - m.total_s[1]) / 5.0, 1e-6, "speed floor 5 m/s")


func test_tie_broken_by_earlier_crossing() -> void:
	var f := _make(2, [30.0, 40.0])
	var m := f.mgr
	var gate1 := _track.gate_offsets[1]
	f.stop_s[0] = gate1 + 5.0
	f.stop_s[1] = gate1 + 5.0
	f.lat[0] = 0.0
	f.lat[1] = 0.0
	m.start_countdown()
	for i in 365 + 120 * 4:
		f.tick()
	# Car 1 (faster) crossed gate 1 first; both now rest at the same s.
	assert_almost_eq(m.total_s[0], m.total_s[1], 0.01)
	assert_eq(m.position_of(1), 1, "earlier crossing wins the tie")
	assert_eq(m.position_of(0), 2)


## 8 cars, 2 laps, one jump start: order, flicker, finish, results.
func test_full_race_results_positions_and_determinism() -> void:
	var speeds := [40.0, 41.5, 39.0, 43.0, 38.0, 42.0, 44.0, 40.5]
	var first := _run_race(speeds)
	var second := _run_race(speeds)
	assert_eq(first["results"], second["results"], "two runs identical")
	assert_eq(first["order_log"], second["order_log"], "ranking identical tick for tick")
	var results: Array = first["results"]
	assert_eq(results.size(), 8)
	# Analytic expectation: time to cover 2 laps from the grid slot, plus the jump-start penalty.
	var spacing := 8.0
	var times: Array = []
	for i in 8:
		var dist := 2.0 * _len + spacing * (i + 1) - (1.0 if i == 5 else 0.0)
		times.append([dist / speeds[i] + (5.0 if i == 5 else 0.0), i])
	times.sort()
	var expect: Array = []
	for t in times:
		expect.append(t[1])
	var got: Array = []
	for r in results:
		got.append(r["car"])
	assert_eq(got, expect, "results ordered by finish time + penalties")
	assert_eq(got[7], 5, "the jump-starter drops to last through its +5 s")
	for r in results:
		assert_false(r["dnf"])
		assert_eq(r["penalties"], 5.0 if r["car"] == 5 else 0.0)
		assert_almost_eq(r["time"], r["race_time"] + r["penalties"], 1e-9)
		var analytic: float = (2.0 * _len + spacing * (r["car"] + 1) - (1.0 if r["car"] == 5 else 0.0)) / speeds[r["car"]]
		assert_almost_eq(r["race_time"], analytic, 0.05, "race_time of car %d" % r["car"])
	for i in results.size():
		assert_eq(results[i]["rank"], i + 1)
	# Start order = slot order; the race ended with the last finisher (not 30 s later).
	assert_eq(first["start_order"], [0, 1, 2, 3, 4, 5, 6, 7])
	assert_eq(first["end_tick"] - first["last_finish_tick"], 0, "ends on the last finish")
	# Mid-race positions follow distance raced.
	assert_eq(first["order_mismatches"], 0, "live order matches distance raced at every check")
	# No flicker: total pairwise swaps equal the analytic overtakes (pairs whose finishing order
	# differs from grid order, ignoring the penalty).
	var raw_order: Array = []
	var raw: Array = []
	for i in 8:
		raw.append([(2.0 * _len + spacing * (i + 1)) / speeds[i], i])
	raw.sort()
	for r in raw:
		raw_order.append(r[1])
	var overtakes := 0
	for a in 8:
		for b in range(a + 1, 8):
			if raw_order.find(a) > raw_order.find(b):
				overtakes += 1
	assert_eq(first["swaps"], overtakes, "every position change is a real overtake")


func _run_race(speeds: Array) -> Dictionary:
	var f := _make(8, speeds)
	var m := f.mgr
	f.pre_go_drift[5] = 1.0
	var got: Array = []
	m.race_finished.connect(func(r: Array) -> void: got.append(r))
	var last_finish := [0]
	m.car_finished.connect(func(_c: int, _t: int) -> void: last_finish[0] = m.tick)
	m.start_countdown()
	var order_log := PackedInt32Array()
	var prev_rank := PackedInt32Array()
	prev_rank.resize(8)
	for i in 8:
		prev_rank[i] = m.position_of(i)
	var swaps := 0
	var mismatches := 0
	var start_order: Array = []
	var max_ticks := 120 * 70
	var t := 0
	while m.state != RaceManager.State.FINISHED and t < max_ticks:
		f.tick()
		t += 1
		if t == 300:
			for r in 8:
				start_order.append(m.order[r])
		for i in 8:
			order_log.append(m.order[i])
		for a in 8:
			for b in range(a + 1, 8):
				if (prev_rank[a] < prev_rank[b]) != (m.rank_of[a] < m.rank_of[b]):
					swaps += 1
		for i in 8:
			prev_rank[i] = m.rank_of[i]
		if t % 240 == 0 and m.state == RaceManager.State.RACING:
			mismatches += _order_mismatches(f)
	assert_eq(got.size(), 1, "race_finished emitted once")
	return {"results": got[0] if got.size() > 0 else [], "order_log": order_log, "swaps": swaps,
			"order_mismatches": mismatches, "start_order": start_order, "end_tick": m.tick,
			"last_finish_tick": last_finish[0]}


## Cars whose live position disagrees with distance raced by more than 3 m of separation
## (finished cars are ranked by finish order and skipped).
func _order_mismatches(f: Field) -> int:
	var bad := 0
	for a in f.n:
		for b in f.n:
			if f.mgr.is_finished(a) or f.mgr.is_finished(b):
				continue
			if f.s[a] - f.s[b] > 3.0 and f.mgr.position_of(a) > f.mgr.position_of(b):
				bad += 1
	return bad


func test_dnf_thirty_seconds_after_first_finisher() -> void:
	var f := _make(3, [60.0, 55.0, 10.0], 1)
	var m := f.mgr
	var done: Array = []
	m.race_finished.connect(func(r: Array) -> void: done.append(r))
	var first_finish := [0]
	m.car_finished.connect(func(_c: int, _t: int) -> void:
		if first_finish[0] == 0:
			first_finish[0] = m.tick)
	m.start_countdown()
	var t := 0
	while done.is_empty() and t < 120 * 80:
		f.tick()
		t += 1
	assert_eq(done.size(), 1)
	var r: Array = done[0]
	assert_eq(r[0]["car"], 0)
	assert_eq(r[1]["car"], 1)
	assert_eq(r[2]["car"], 2)
	assert_true(r[2]["dnf"], "slow car is DNF")
	assert_false(r[0]["dnf"] or r[1]["dnf"])
	assert_eq(m.tick - first_finish[0], 3600, "30 s after the first finisher")
	# Finished cars keep driving; the finished rank is frozen.
	assert_eq(m.position_of(0), 1)
	assert_eq(m.position_of(2), 3)


func test_retired_car_does_not_hold_the_race() -> void:
	var f := _make(2, [60.0, 10.0], 1)
	var m := f.mgr
	m.retire(1)
	var done: Array = []
	m.race_finished.connect(func(r: Array) -> void: done.append(r))
	m.start_countdown()
	var t := 0
	while done.is_empty() and t < 120 * 40:
		f.tick()
		t += 1
	assert_eq(done.size(), 1, "race ends when every non-retired car finished")
	assert_true(done[0][1]["dnf"])
	assert_lt(t, 120 * 25)


func test_step_memory_flat() -> void:
	var f := _make(8, [40, 41, 42, 43, 44, 45, 46, 47], 4)
	f.mgr.start_countdown()
	for i in 600:
		f.tick()
	var before := Performance.get_monitor(Performance.MEMORY_STATIC)
	for i in 600:
		f.mgr.step(f.pos, f.spd)
	assert_lt(Performance.get_monitor(Performance.MEMORY_STATIC) - before, 64 * 1024)
