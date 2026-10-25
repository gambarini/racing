## Per-driver AI personality (#30): data only, plus pure derivation functions. Difficulty scales the
## driver's SKILL (how close to the grip limit the racing line is driven) and its mistake rate, never
## the car: no grip, power, mass, tyre or engine value is read from or written by anything here.
##
## Effective skill = difficulty mean + a seeded per-driver spread. It feeds the racing-line solver
## (`skill_scale`, the fraction of the grip-limited corner speed, see RacingLineSolver.resolve_line)
## and `speed_scale` is a command-side multiplier on the line's target speed (AiDriver). Effective
## skill is capped at SKILL_CAP, the highest value verified by #171 / #187 (0.66 is the Hard mean).
## All trait values are in [0, 1] (setters clamp; `is_valid()` reports a loaded out-of-range value).
## Tuning numbers for what the traits DO live here as exports, not in the consumers.
class_name AiPersonality
extends Resource

enum Difficulty { EASY, MEDIUM, HARD }

const SKILL_CAP := 0.70 ## highest effective skill verified by #171 (0.80 fails, #187)
const MEAN_SKILL := [0.50, 0.594, 0.66] ## per Difficulty (estimate)
const MEAN_CONSISTENCY := [0.6, 0.8, 0.95] ## per Difficulty (estimate)
const SKILL_SPREAD := 0.03 ## +- around the mean (estimate)
const TRAIT_SPREAD := 0.25 ## +- around 0.5 for aggression / bravery / contact tolerance

@export_range(0.0, 1.0) var skill := 0.594: set = _set_skill ## fraction of grip-limited corner speed (before the cap)
@export_range(0.0, 1.0) var consistency := 1.0: set = _set_consistency ## 1 = no mistakes
@export_range(0.0, 1.0) var aggression := 0.5: set = _set_aggression
@export_range(0.0, 1.0) var braking_bravery := 0.5: set = _set_bravery
@export_range(0.0, 1.0) var contact_tolerance := 0.5: set = _set_tolerance
@export_range(0.1, 1.0) var speed_scale := 1.0 ## command-side target-speed multiplier (not a physics multiplier)

@export_group("Tuning")
## Mistakes: a lift (target speed cut) that starts at `mistake_rate_hz * (1 - consistency)` per second.
@export var mistake_rate_hz := 0.08
@export var mistake_duration := 1.0 ## s
@export var mistake_depth := 0.25 ## fraction of the target speed lost (scaled 0.5..1 per mistake)
## Braking bravery shortens the speed look-ahead (s): brake point distance = speed * lead time.
@export var brake_lead_max := 0.4 ## s at bravery 0
@export var brake_lead_min := 0.1 ## s at bravery 1
## Aggression: lateral clearance (m) wanted beside a car when passing, and the time gap (s) within
## which a pass is started.
@export var overtake_clear_max := 0.8 ## m at aggression 0
@export var overtake_clear_min := 0.2 ## m at aggression 1
@export var overtake_gap_s_min := 1.0 ## s at aggression 0
@export var overtake_gap_s_max := 2.0 ## s at aggression 1
## Contact tolerance: bumper gap (m) kept to a car being followed.
@export var follow_dist_max := 10.0 ## m at tolerance 0
@export var follow_dist_min := 3.0 ## m at tolerance 1


func _set_skill(v: float) -> void:
	skill = clampf(v, 0.0, 1.0)


func _set_consistency(v: float) -> void:
	consistency = clampf(v, 0.0, 1.0)


func _set_aggression(v: float) -> void:
	aggression = clampf(v, 0.0, 1.0)


func _set_bravery(v: float) -> void:
	braking_bravery = clampf(v, 0.0, 1.0)


func _set_tolerance(v: float) -> void:
	contact_tolerance = clampf(v, 0.0, 1.0)


## True when every trait is inside [0, 1] (a hand-edited .tres can bypass the setters).
func is_valid() -> bool:
	for x in [skill, consistency, aggression, braking_bravery, contact_tolerance]:
		if x < 0.0 or x > 1.0:
			return false
	return speed_scale > 0.0 and speed_scale <= 1.0


## Skill handed to the racing-line solver: the trait, capped at the verified ceiling.
func effective_skill() -> float:
	return minf(skill, SKILL_CAP)


## Mistakes per second (0 at consistency 1: no errors are injected).
func mistake_rate() -> float:
	return mistake_rate_hz * (1.0 - consistency)


## Speed look-ahead (s) used for the braking decision; braver = shorter = later braking.
func brake_lead_time() -> float:
	return lerpf(brake_lead_max, brake_lead_min, braking_bravery)


## Lateral clearance (m) wanted beside a car when overtaking; more aggressive = tighter.
func overtake_clearance() -> float:
	return lerpf(overtake_clear_max, overtake_clear_min, aggression)


## Time gap (s) within which an overtake is started; more aggressive = starts earlier.
func overtake_gap_s() -> float:
	return lerpf(overtake_gap_s_min, overtake_gap_s_max, aggression)


## Bumper gap (m) kept when following; more contact-tolerant = closer.
func follow_distance() -> float:
	return lerpf(follow_dist_max, follow_dist_min, contact_tolerance)


## Personality of driver `index` at `difficulty`, deterministic from `seed_value`: skill within
## +-SKILL_SPREAD of the difficulty mean (never above SKILL_CAP), the other traits seeded around 0.5.
static func make(difficulty: Difficulty, index: int, seed_value: int) -> AiPersonality:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([seed_value, index, int(difficulty)])
	var p := AiPersonality.new()
	p.skill = minf(MEAN_SKILL[difficulty] + rng.randf_range(-SKILL_SPREAD, SKILL_SPREAD), SKILL_CAP)
	p.consistency = MEAN_CONSISTENCY[difficulty] + rng.randf_range(-0.05, 0.05)
	p.aggression = 0.5 + rng.randf_range(-TRAIT_SPREAD, TRAIT_SPREAD)
	p.braking_bravery = 0.5 + rng.randf_range(-TRAIT_SPREAD, TRAIT_SPREAD)
	p.contact_tolerance = 0.5 + rng.randf_range(-TRAIT_SPREAD, TRAIT_SPREAD)
	return p


## `count` personalities for a field.
static func make_field(difficulty: Difficulty, count: int, seed_value: int) -> Array[AiPersonality]:
	var out: Array[AiPersonality] = []
	for i in count:
		out.append(make(difficulty, i, seed_value))
	return out
