class_name TrackLimits
extends RefCounted
## Per-car track-limit excursion tracker (issue #174). Pure logic: feed `step()` once per physics
## tick with the number of wheels beyond the road edge (0..4).
## A violation is one excursion: it starts the tick all 4 wheels are off and lasts until at least
## one wheel has been back on the road continuously for `debounce` seconds. Re-entry flicker
## shorter than that stays the same excursion. Time is counted in whole ticks.

enum Result { NONE, WARNING, PENALTY }

var debounce := 0.5  ## s (estimate)
var tick_dt := 1.0 / 120.0
var violations := 0  ## excursions counted so far
var in_excursion := false

var _on_ticks := 0


func _init(p_tick_dt := 1.0 / 120.0, p_debounce := 0.5) -> void:
	tick_dt = p_tick_dt
	debounce = p_debounce


## Returns NONE, WARNING (first violation) or PENALTY (every further one) on the tick a new
## excursion starts.
func step(wheels_off: int) -> int:
	if wheels_off >= 4:
		_on_ticks = 0
		if not in_excursion:
			in_excursion = true
			violations += 1
			return Result.WARNING if violations == 1 else Result.PENALTY
	elif in_excursion:
		_on_ticks += 1
		if _on_ticks * tick_dt >= debounce - 1e-9:
			in_excursion = false
	return Result.NONE


func reset() -> void:
	violations = 0
	in_excursion = false
	_on_ticks = 0
