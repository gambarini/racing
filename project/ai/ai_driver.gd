## AI driver (#28): follows a RacingLine (#27) through the SAME input path as the player. Each
## physics tick `drive()` writes a DriverInputState (steer, throttle, brake, handbrake) and nothing
## else: it only READS the vehicle (position, basis, velocity, rear tyre slip angle). It never
## writes body, wheel or tyre state and has no grip or power multipliers (pillar: same physics).
##  - Steering: pure pursuit to the point `clamp(look_k * speed, look_min, look_max)` m ahead on the
##    line, then SteeringFilter.step_steer (same speed range + rate limit as a human's stick).
##  - Speed: PI controller on `target_speed_at(s + lead)`; throttle xor brake (no overlap).
##  - Slip-aware: rear slip angle above `slip_target_deg` cuts the throttle and counter-steers
##    (toward the slide, the SteeringFilter.counter_steer_assist convention).
## Allocation-free per tick (floats, preallocated telemetry buffer). setup() allocates.
class_name AiDriver
extends RefCounted

const COLS := ["tick", "s", "speed", "target_speed", "look_x", "look_z", "cross_track", "steer", "throttle", "brake", "rear_slip_deg"]

var line: RacingLine
## Lateral offset of the look-ahead target from the racing line (#29), metres, + = right. Set by
## AiTactics (or a test); `lane_now` follows it at `lane_rate` and is clamped to the road.
var lane_target := 0.0
var lane_now := 0.0
var lane_rate := 1.5 ## m/s (estimate, #29)
var road_half := 6.5 ## m, road half-width (Quarry main route)
var joker_road_half := 5.0 ## m, half-width of the joker detour
var car_margin := 1.2 ## m kept between the car centre and the road edge (estimate, #29)
var lane_error := 0.0 ## m, car minus offset line (+ = car right of it), at the car's own s
var tactics_brake_slack := 2.0 ## m/s below the current speed a tactical speed cap may ask for
var tactics: AiTactics ## null = plain line following
## Personality (#30): null = the plain driver. The driver only READS it (skill, speed_scale, braking
## bravery, consistency); it never changes a car parameter. Use `setup_personality()`.
var personality: AiPersonality
var mistakes := 0 ## mistakes (lifts) made so far, for tests
var mistake_factor := 1.0 ## target-speed multiplier of the current mistake (1 = none)
## Look-ahead distance = clamp(look_k * speed, look_min, look_max) metres (estimate, #28).
var look_k := 0.6 ## s
var look_min := 6.0
var look_max := 30.0
var wheelbase := 2.5
var max_steer_rad := deg_to_rad(34.0) ## steer == 1 at the inner front wheel (VehicleDefinition)
## Speed PI.
var kp := 0.5 ## throttle per m/s of error
var ki := 0.25 ## per m/s*s
var i_limit := 0.5
var brake_kp := 0.35 ## brake per m/s of overspeed
var brake_deadband := 0.3 ## m/s of overspeed tolerated before braking
var lead_time := 0.25 ## s of speed look-ahead on the target profile
## Fraction of the line's target speed driven (#30 skill hook; a command-side limit, not a physics
## multiplier). 0.9 keeps margin for the fastest line skills (#171: the line baked at skill 0.66
## completes laps at 1.0 too; above ~0.7 effective the car runs wide in the long Quarry corners).
var speed_scale := 0.9
## Slip-aware throttle cut and counter-steer.
var slip_target_deg := 8.0 ## (estimate, #28)
var slip_span_deg := 6.0 ## throttle reaches 0 this far above the target
var counter_gain := 1.0
var range_compensation := true ## divide the steer command by the filter's speed range scale (#171)
## Pedal ramp like the player's keyboard (DriverInput.pedal_rate_*).
var pedal_rate_up := 14.0
var pedal_rate_down := 20.0

## Outputs / state for tests, HUD and debug draw.
var speed_now := 0.0 ## forward speed (m/s) sensed this tick
var s := 0.0 ## arc length of the car on the line (m)
var look_point := Vector3.ZERO
var target_speed := 0.0
var cross_track := 0.0 ## m, signed, + = line is to the right of the car
var rear_slip_deg := 0.0
var slip_active := false
var tick := 0

## Telemetry (preallocated rows, no per-tick allocation while below capacity).
var telemetry_enabled := false
var telemetry := PackedFloat32Array()
var telemetry_rows := 0
var telemetry_capacity := 0

var _steer := 0.0
var _i := 0.0
var _have_s := false
var _lane_lo := 0.0
var _lane_hi := 0.0
var _rng := RandomNumberGenerator.new()
var _mistake_t := 0.0


func setup(p_line: RacingLine, p_telemetry_capacity := 0) -> void:
	line = p_line
	reset()
	telemetry_capacity = p_telemetry_capacity
	telemetry.resize(telemetry_capacity * COLS.size())
	telemetry_rows = 0


## Sets the driver up for a personality (#30): the racing line is re-solved at the personality's
## effective skill (setup-time, allocates), speed_scale and the braking look-ahead come from its
## traits, and the mistake generator is seeded from `seed_value`. Nothing on the car is touched.
func setup_personality(base_line: RacingLine, p: AiPersonality, seed_value := 0, p_telemetry_capacity := 0) -> void:
	personality = p
	setup(RacingLineSolver.resolve_line(base_line, p.effective_skill()), p_telemetry_capacity)
	speed_scale = p.speed_scale
	lead_time = p.brake_lead_time()
	_rng.seed = hash([seed_value, int(p.skill * 1000.0), int(p.consistency * 1000.0)])


## Distance (m) before a target-speed drop at which braking starts to be asked for at `speed`.
func brake_point_distance(speed: float) -> float:
	return maxf(speed, 0.0) * lead_time


## Gives the driver its own copy of the line (its variant switches must not leak into other
## drivers sharing the resource) and a tactics layer fed by `mgr`.
func attach_tactics(mgr: RaceManager, car: int, seed_value := 0) -> AiTactics:
	line = line.duplicate()
	tactics = AiTactics.new()
	tactics.setup(mgr, car, seed_value)
	tactics.lane_rate = lane_rate
	if personality != null:
		tactics.apply_personality(personality)
	return tactics


## Switches the line variant (main / joker lap). s is variant-local, so it is re-acquired.
func set_variant(v: RacingLine.Variant) -> void:
	if line.variant != v:
		line.variant = v
		_have_s = false


## Road half-width (m) at arc length `at` of the active variant.
func road_half_at(at: float) -> float:
	if line.variant == RacingLine.Variant.JOKER:
		var span := line.joker_span_joker
		var w := fposmod(at, line.lap_length())
		if w >= span.x and w <= span.y:
			return joker_road_half
	return road_half


func reset() -> void:
	lane_target = 0.0
	lane_now = 0.0
	_steer = 0.0
	_i = 0.0
	_have_s = false
	tick = 0
	telemetry_rows = 0
	_mistake_t = 0.0
	mistake_factor = 1.0
	mistakes = 0


## One physics tick. `v` is only read.
func drive(v: Vehicle, st: DriverInputState, dt: float) -> void:
	var xf := v.global_transform
	var fwd := -xf.basis.z
	var vel := v.linear_velocity
	var speed := vel.x * fwd.x + vel.y * fwd.y + vel.z * fwd.z
	# Signed rear slip angle in degrees (mean of the rear wheels, + = travelling toward the right).
	var slip := rad_to_deg(0.5 * (v.wheels[2].alpha + v.wheels[3].alpha))
	step(xf.origin, fwd, speed, slip, dt, st)


## Pure-ish control step from sensed values (unit tests feed this directly). `fwd` is the car's
## horizontal-ish forward unit vector, `speed` the signed forward speed, `slip_deg` the rear slip.
func step(pos: Vector3, fwd: Vector3, speed: float, slip_deg: float, dt: float, st: DriverInputState) -> void:
	if not _have_s:
		s = line.nearest_s(pos)
		_have_s = true
	else:
		s = line.nearest_s(pos, s, 40.0)
	rear_slip_deg = slip_deg
	speed_now = speed
	var sp := maxf(speed, 0.0)
	if tactics != null:
		tactics.update(self)
		lane_target = tactics.lane_target
	# --- Steering: pure pursuit to the (laterally offset) look-ahead point ---
	var ld := look_distance(sp)
	var li := line.sample_index(s + ld)
	look_point = line.point_at_index(li, line.sample_frac(li, s + ld))
	# Lane offset: rate-limited toward the target, clamped to the road minus the car margin.
	var c_look := line.lane_offset_at(s + ld)
	var half := road_half_at(s + ld)
	# Limits always include 0: the plain line (no tactics) is never displaced by the clamp (#28 path).
	_lane_lo = minf(-half + car_margin - c_look, 0.0)
	_lane_hi = maxf(half - car_margin - c_look, 0.0)
	lane_now = clampf(move_toward(lane_now, clampf(lane_target, _lane_lo, _lane_hi), lane_rate * dt), _lane_lo, _lane_hi)
	if lane_now != 0.0:
		var tg_l := line.tangent_at(s + ld)
		look_point.x += -tg_l.z * lane_now
		look_point.z += tg_l.x * lane_now
	var dx := look_point.x - pos.x
	var dz := look_point.z - pos.z
	# car-frame: forward component and right component (right = fwd rotated -90 deg about Y)
	var f_len := maxf(sqrt(fwd.x * fwd.x + fwd.z * fwd.z), 1e-6)
	var fx := fwd.x / f_len
	var fz := fwd.z / f_len
	var along := dx * fx + dz * fz
	var side := dx * -fz + dz * fx
	var dist2 := maxf(along * along + side * side, 1e-4)
	var curv := 2.0 * side / dist2 # pure pursuit curvature, + = right
	var delta := atan(wheelbase * curv)
	if along < 0.0:
		delta = signf(side) * max_steer_rad # target behind: full lock toward it
	var want := clampf(delta / max_steer_rad, -1.0, 1.0)
	# --- Slip-aware: counter-steer toward the slide ---
	var over := absf(slip_deg) - slip_target_deg
	slip_active = over > 0.0
	if slip_active:
		# steer toward the slide by the slip beyond the target, on top of the pursuit command
		want = clampf(want + signf(slip_deg) * deg_to_rad(over) / max_steer_rad * counter_gain, -1.0, 1.0)
	# SteeringFilter scales the command by its speed range; undo that so the wheel angle is the one
	# pure pursuit asked for (#171: without it the front axle gets ~half the angle at 110 km/h).
	if range_compensation:
		want = clampf(want / SteeringFilter.range_scale(speed * 3.6), -1.0, 1.0)
	_steer = SteeringFilter.step_steer(_steer, want, dt, speed * 3.6)
	st.steer = _steer
	# --- Speed: PI on the profile a little ahead ---
	var lead_s := s + sp * lead_time
	var li2 := line.sample_index(lead_s)
	var li0 := line.sample_index(s)
	target_speed = minf(line.target_speed_at_index(li2, line.sample_frac(li2, lead_s)),
			line.target_speed_at_index(li0, line.sample_frac(li0, s))) * speed_scale
	if personality != null:
		target_speed *= _mistake(dt)
	if tactics != null:
		# A tactical cap brakes progressively (never below speed - brake_slack), so the front wheels
		# keep enough grip to steer around the car being avoided.
		target_speed = minf(target_speed, maxf(tactics.speed_cap, sp - tactics_brake_slack))
	var t := speed_control(target_speed, sp, dt)
	var thr := maxf(t, 0.0)
	var brk := maxf(-t, 0.0)
	if slip_active:
		thr *= clampf(1.0 - over / slip_span_deg, 0.0, 1.0)
	st.throttle = SteeringFilter.ramp(st.throttle, thr, dt, pedal_rate_up, pedal_rate_down)
	st.brake = SteeringFilter.ramp(st.brake, brk, dt, pedal_rate_up, pedal_rate_down)
	if st.throttle > 0.0 and st.brake > 0.0: # never both pedals
		if brk > 0.0:
			st.throttle = 0.0
		else:
			st.brake = 0.0
	st.handbrake = false
	# cross track (+ = line to the right of the car), at the car's own s
	var p0 := line.point_at(s)
	var tg := line.tangent_at(s)
	cross_track = (p0.x - pos.x) * -tg.z + (p0.z - pos.z) * tg.x
	lane_error = -cross_track - lane_now
	if telemetry_enabled and telemetry_rows < telemetry_capacity:
		var o := telemetry_rows * COLS.size()
		telemetry[o] = tick
		telemetry[o + 1] = s
		telemetry[o + 2] = speed
		telemetry[o + 3] = target_speed
		telemetry[o + 4] = look_point.x
		telemetry[o + 5] = look_point.z
		telemetry[o + 6] = cross_track
		telemetry[o + 7] = st.steer
		telemetry[o + 8] = st.throttle
		telemetry[o + 9] = st.brake
		telemetry[o + 10] = slip_deg
		telemetry_rows += 1
	tick += 1


## Mistake generator (#30): at `personality.mistake_rate()` per second the driver lifts, cutting the
## target speed by a seeded depth for `mistake_duration`. Consistency 1 never draws. Returns the
## target-speed multiplier. Allocation-free.
func _mistake(dt: float) -> float:
	if _mistake_t > 0.0:
		_mistake_t -= dt
		if _mistake_t <= 0.0:
			mistake_factor = 1.0
		return mistake_factor
	var rate := personality.mistake_rate()
	if rate > 0.0 and _rng.randf() < rate * dt:
		_mistake_t = personality.mistake_duration
		mistake_factor = 1.0 - personality.mistake_depth * _rng.randf_range(0.5, 1.0)
		mistakes += 1
	return mistake_factor


## Pure-pursuit look-ahead (m) at forward speed `speed` (m/s).
func look_distance(speed: float) -> float:
	return clampf(look_k * maxf(speed, 0.0), look_min, look_max)


## PI speed controller: > 0 = throttle demand, < 0 = brake demand (both in [-1, 1]).
func speed_control(target: float, speed: float, dt: float) -> float:
	var err := target - speed
	if err >= 0.0:
		_i = clampf(_i + err * dt * ki, 0.0, i_limit)
		return clampf(kp * err + _i, 0.0, 1.0)
	_i = 0.0
	if err > -brake_deadband:
		return 0.0 # coast
	return -clampf(brake_kp * (-err - brake_deadband), 0.0, 1.0)


## CSV text of the recorded rows (header + one row per tick).
func telemetry_csv() -> String:
	var out := ",".join(COLS) + "\n"
	for r in telemetry_rows:
		var o := r * COLS.size()
		var cells := PackedStringArray()
		for c in COLS.size():
			cells.append(str(telemetry[o + c]))
		out += ",".join(cells) + "\n"
	return out


func save_telemetry(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(telemetry_csv())
