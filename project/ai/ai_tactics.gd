## AI race tactics (#29): avoid, overtake, defend and joker choice. Tactics never touch the
## physics: they only move the AiDriver's lateral line offset (`lane_target`, metres from the
## racing line, + = right), cap the speed the driver asks for (`speed_cap`, a brake demand, never a
## power or grip multiplier) and pick the line variant (main / joker lap). Everything else (steer,
## pedals) is still the AiDriver writing a DriverInputState.
##
## Reads other cars only through `RaceManager.query()` / its per-car arrays (no scene scans).
## Allocation-free per tick: floats, ints and preallocated members only.
##  - Avoid / overtake: the nearest car ahead whose lateral position is within
##    `car_width + clear_margin` of this car's line is passed on one committed side (the side where
##    the line already is, else the roomier one) with `pass_extra` extra metres. The side is held
##    until the car is `release_behind` m behind, so a pass never flips mid-way. While the lateral
##    gap is not yet open, `speed_cap` limits the closing speed to `bumper_gap / shift_time` (the
##    time the rate-limited lane change needs), which brakes for a stationary car.
##  - Defend: a faster follower within `defend_gap_s`, on a straight, gets ONE lane move toward its
##    side, held to the end of that straight (no weaving).
##  - Joker: at the start of the approach to the detour the lap's variant is chosen once; the joker
##    is taken once per race, preferring a lap with no car within `joker_clear_s` seconds ahead or
##    behind, forced on the last lap. The preferred lap comes from a seeded RNG (deterministic).
class_name AiTactics
extends RefCounted

var mgr: RaceManager
var car := 0
var prox := Proximity.new()

# Parameters (estimates, #29).
var car_width := 1.7 ## m, chassis_size.x
var car_length := 3.4 ## m, chassis_size.z
var clear_margin := 0.5 ## m of lateral clearance wanted beside another car
var pass_extra := 0.3 ## m added to the pass offset
var react_time := 0.4 ## s of steering lag added to the lane-change time
var release_behind := 8.0 ## m a passed car must be behind before the pass side is released
var detect_range := 100.0 ## m
var defend_range := 60.0 ## m behind
var defend_gap_s := 1.0
var defend_closing := 1.0 ## m/s the follower must be faster by (a faster follower)
var defend_shift := 1.2 ## m, single lane move of a defender
var straight_curv := 0.004 ## 1/m: |curvature| below this over `straight_look` counts as a straight
var straight_look := 60.0
var joker_clear_s := 1.5
var joker_lead := 120.0 ## m before the detour entry where the joker choice is made
var overtake_gap_s := 1.5 ## start a pass within this time gap (straights)
var pass_patience := 1.0 ## s without closing before a pass is abandoned
var overtake_ttc := 6.0 ## s: ...and when the bumper gap closes within this time at the current closing speed
var min_closing := 1.0 ## m/s of closing speed that justifies a pass
var obstacle_speed_ratio := 0.5 ## ahead slower than this fraction of own speed = obstacle: avoid anywhere
var follow_dist := 6.0 ## m bumper gap kept when following
var follow_time := 1.5 ## s to close the remaining gap when following
var use_joker := true ## false = never take the joker (tests: plain race on a track that has one)
var lane_rate := 1.5 ## m/s, mirrors AiDriver.lane_rate (shift-time estimate)

## Outputs.
var lane_target := 0.0 ## m from the racing line
var speed_cap := INF ## m/s
var in_straight := false
var passing := -1 ## car id being passed / avoided, -1 = none
var following := -1 ## car id being followed (blocked, not passed), -1 = none
var defending := false
var on_detour := false ## lateral offsets are from the joker detour centre line (this car is on the detour)
var joker_chosen := false ## the joker variant was picked for the current lap
var lap_no := 0
var joker_pref_lap := 0
var chosen_forced := false ## the joker was taken because it was the last lap
var chosen_clear := false ## no car within joker_clear_s at the choice

var _pass_side := 0
var _no_close_t := 0.0
var _defend_side := 0
var _defended := false
var _decided := false
var _rng := RandomNumberGenerator.new()
var _pref_ready := false


## Personality (#30) -> tactical quantities. Documented: aggression sets the lateral clearance wanted
## when passing (`clear_margin`, the minimum overtake gap) and the time gap a pass starts within;
## contact tolerance sets the bumper gap kept when following. Values come from the resource.
var personality: AiPersonality


func apply_personality(p: AiPersonality) -> void:
	personality = p
	clear_margin = p.overtake_clearance()
	overtake_gap_s = p.overtake_gap_s()
	follow_dist = p.follow_distance()


## Minimum lateral gap (m) wanted beside a car when overtaking.
func min_overtake_gap() -> float:
	return clear_margin


func setup(p_mgr: RaceManager, p_car: int, p_seed := 0) -> void:
	mgr = p_mgr
	car = p_car
	_rng.seed = hash([p_seed, p_car]) # setup allocates; update() does not
	_pref_ready = false
	reset()


func reset() -> void:
	lane_target = 0.0
	speed_cap = INF
	passing = -1
	defending = false
	_pass_side = 0
	_defend_side = 0
	_defended = false
	_decided = false
	joker_chosen = false
	lap_no = 0


## One tick. Reads `drv.line`, `drv.s`; writes `lane_target`, `speed_cap`, and may switch `drv`'s line variant.
func update(drv: AiDriver) -> void:
	var line := drv.line
	var s := drv.s
	mgr.query(car, prox, detect_range, defend_range)
	_to_route_frame(drv)
	in_straight = _straight_at(line, s)
	_update_joker(drv)
	speed_cap = INF
	var want := 0.0
	# --- Avoid / overtake ---
	var tc := _target_car(line, s)
	if tc >= 0:
		var gap := mgr.rel_s(car, tc)
		var lat_c := prox.ahead_lat if tc == prox.ahead else _lat_of(tc)
		var la := line.lane_offset_at(s + maxf(gap, 0.0))
		if passing != tc:
			passing = tc
			_pass_side = _choose_side(lat_c, la, drv)
		var sep_pass := car_width + clear_margin + pass_extra
		want = lat_c + _pass_side * sep_pass - la
		# Closing-speed cap until the lateral gap is open (brakes for a stationary car).
		var sep_now := (prox.own_lat - lat_c) * _pass_side
		var need := car_width + clear_margin - sep_now
		if need > 0.0 and gap > 0.0:
			var t_shift := need / lane_rate + react_time
			var bumper := gap - car_length
			var v_c := mgr.speeds_now[tc]
			if bumper > 1.0:
				speed_cap = v_c + (bumper - 1.0) / t_shift
			else:
				speed_cap = v_c * 0.9
		_defended = true # a pass is this straight's lane move
		defending = false
	else:
		passing = -1
		_pass_side = 0
		if following >= 0:
			var bumper_f := prox.ahead_gap - car_length
			speed_cap = prox.ahead_speed + maxf(bumper_f - follow_dist, 0.0) / follow_time
		want = _defend(line, s, drv)
	lane_target = want


## Lateral offsets are measured from the route this car is on (#177): the main centre line, or the
## detour centre line while this car drives the joker variant inside the detour span, so cars on the
## detour block each other (the lane offsets of the JOKER line are from the detour centre line too).
## Rewrites own/ahead/behind `lat` in `prox`. Allocation-free (Vector3 temporaries only).
func _to_route_frame(drv: AiDriver) -> void:
	on_detour = false
	var line := drv.line
	var trk := mgr.track
	if line.variant != RacingLine.Variant.JOKER or trk.joker_curve == null:
		return
	if drv.s < line.joker_span_joker.x or drv.s > line.joker_span_joker.y:
		return
	on_detour = true
	prox.own_lat = _lat_of(car)
	if prox.ahead >= 0:
		prox.ahead_lat = _lat_of(prox.ahead)
	if prox.behind >= 0:
		prox.behind_lat = _lat_of(prox.behind)


## Lateral offset of car `j` in the active route frame (see `_to_route_frame`).
func _lat_of(j: int) -> float:
	if not on_detour:
		return mgr.lateral[j]
	var trk := mgr.track
	var s := mgr.line_s[j]
	var tf := trk.forward_at(s)
	var base := trk.position_at(s)
	var lat := mgr.lateral[j]
	var p := Vector3(base.x - tf.z * lat, 0.0, base.z + tf.x * lat)
	var inv := trk.global_transform.affine_inverse()
	var local := inv * p
	var cur := trk.joker_curve
	var off := cur.get_closest_offset(local)
	var c := cur.sample_baked(off)
	var c2 := cur.sample_baked(minf(off + 0.5, cur.get_baked_length()))
	if off + 0.5 > cur.get_baked_length():
		c2 = c
		c = cur.sample_baked(maxf(off - 0.5, 0.0))
	var t := trk.global_transform.basis * Vector3(c2.x - c.x, 0.0, c2.z - c.z)
	var tl := maxf(sqrt(t.x * t.x + t.z * t.z), 1e-6)
	var cw := trk.global_transform * cur.sample_baked(off)
	return ((p.x - cw.x) * -t.z + (p.z - cw.z) * t.x) / tl


## Car to avoid / pass: a committed car until it is `release_behind` behind, else the nearest car
## ahead that blocks this car's line AND is worth passing: a (near-)stationary car anywhere, or a
## slower one while on a straight within `overtake_gap_s`. -1 = none (the driver follows instead).
func _target_car(line: RacingLine, s: float) -> int:
	if passing >= 0 and not mgr.retired[passing]:
		var rs := mgr.rel_s(car, passing)
		if rs > -release_behind:
			# Abort a non-obstacle pass that is not working: target out of range, or not being
			# caught for `pass_patience` s while still behind it, or the straight is over.
			var v_p := mgr.speeds_now[passing]
			var obstacle_p := v_p < obstacle_speed_ratio * prox.own_speed
			var closing_p := prox.own_speed - v_p
			if rs > 0.0 and not obstacle_p:
				_no_close_t = _no_close_t + 1.0 / 120.0 if closing_p < min_closing else 0.0
				if rs > detect_range or _no_close_t > pass_patience or not in_straight:
					_no_close_t = 0.0
					return _abort_pass()
			else:
				_no_close_t = 0.0
			return passing
	following = -1
	if prox.ahead >= 0:
		var la := line.lane_offset_at(s + prox.ahead_gap)
		if absf(prox.ahead_lat - la) < car_width + clear_margin:
			var v_c := prox.ahead_speed
			var obstacle := v_c < obstacle_speed_ratio * prox.own_speed
			var closing := prox.own_speed - v_c
			if obstacle or (in_straight and closing > min_closing and prox.ahead_gap_s < overtake_gap_s
					and (prox.ahead_gap - car_length) < overtake_ttc * closing):
				return prox.ahead
			following = prox.ahead
	return -1


func _abort_pass() -> int:
	passing = -1
	_pass_side = 0
	following = -1
	return -1


## Side to pass on: -1 = left, +1 = right. The side the line already is on; with the car dead on the
## line, the side with more road. Falls back to the other side when the clamp would leave no room.
func _choose_side(lat_c: float, la: float, drv: AiDriver) -> int:
	var diff := lat_c - la # + = other car is right of this car's line
	var side := -1 if diff > 0.3 else (1 if diff < -0.3 else (-1 if lat_c >= 0.0 else 1))
	var limit := drv.road_half_at(drv.s) - drv.car_margin
	var sep_pass := car_width + clear_margin + pass_extra
	if absf(lat_c + side * sep_pass) > limit and absf(lat_c - side * sep_pass) <= limit:
		side = -side
	return side


func _defend(line: RacingLine, s: float, drv: AiDriver) -> float:
	if not in_straight:
		_defended = false
		_defend_side = 0
		defending = false
		return 0.0
	if _defend_side == 0 and not _defended and prox.behind >= 0 and prox.behind_gap_s < defend_gap_s \
			and prox.behind_speed > prox.own_speed + defend_closing:
		var diff := prox.behind_lat - prox.own_lat
		if absf(diff) > 0.4:
			_defend_side = 1 if diff > 0.0 else -1
		else:
			_defend_side = _inside_side(line, s)
		_defended = true
	defending = _defend_side != 0
	return _defend_side * defend_shift


## Side (+1 right) of the next real corner after the current straight; right if none.
func _inside_side(line: RacingLine, s: float) -> int:
	var at := s + straight_look
	while at < s + 300.0:
		var c := line.curvature_at(at)
		if absf(c) > straight_curv * 2.0:
			return 1 if c > 0.0 else -1
		at += 10.0
	return 1


func _straight_at(line: RacingLine, s: float) -> bool:
	return absf(line.curvature_at(s)) < straight_curv \
			and absf(line.curvature_at(s + straight_look * 0.5)) < straight_curv \
			and absf(line.curvature_at(s + straight_look)) < straight_curv


## Joker choice: once per lap, `joker_lead` m before the detour entry (main-lap s space).
func _update_joker(drv: AiDriver) -> void:
	if not use_joker or not mgr.track.has_joker or not drv.line.has_joker() or mgr.state != RaceManager.State.RACING:
		return
	var laps_done := mgr.timers[car].laps.size()
	if laps_done + 1 != lap_no:
		lap_no = laps_done + 1
		_decided = false
		joker_chosen = false
		drv.set_variant(RacingLine.Variant.MAIN)
	if _decided:
		return
	if mgr.joker_taken[car]:
		_decided = true
		return
	if not _pref_ready:
		var lo := mini(2, mgr.lap_count)
		pick_joker_lap(lo, maxi(mgr.lap_count - 1, lo))
	var entry := drv.line.joker_span_main.x
	if drv.s < entry - joker_lead or drv.s >= entry:
		return
	_decided = true
	var clear := (prox.ahead < 0 or prox.ahead_gap_s > joker_clear_s) \
			and (prox.behind < 0 or prox.behind_gap_s > joker_clear_s)
	if lap_no >= mgr.lap_count or (lap_no >= joker_pref_lap and clear):
		joker_chosen = true
		chosen_forced = lap_no >= mgr.lap_count
		chosen_clear = clear
		drv.set_variant(RacingLine.Variant.JOKER)


## Draws the preferred joker lap in [lo, hi] from the seeded RNG (once per race).
func pick_joker_lap(lo: int, hi: int) -> void:
	joker_pref_lap = _rng.randi_range(lo, hi)
	_pref_ready = true
