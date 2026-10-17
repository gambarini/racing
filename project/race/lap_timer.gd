class_name LapTimer
extends RefCounted
## Ordered-gate lap and sector timing with physics-tick resolution (issue #105).
## Pure logic: feed it the car position once per physics tick via `step()`.
## Gate 0 is start/finish. In flying-lap mode (default) a lap starts at the first crossing of
## gate 0 and completes when gate 0 is crossed again after every gate 1..n-1 was crossed in
## order. In standing-start mode (`start_standing()`, #141) lap 1 starts at the explicit signal
## tick; a grid slot behind the line crosses gate 0 once to clear the grid, a slot past the
## line goes straight to gate 1 (#143). Out-of-order crossings are ignored. `sector_end_gates` lists the gate indices ending sector 1 and 2;
## the last sector ends at the finish line, so sector ticks always sum to the lap ticks.

signal lap_completed(record: Dictionary)

var gates: Array[Gate] = []
var sector_end_gates: Array[int] = []
var joker_gate: Gate = null
var tick_dt := 1.0 / 120.0

var tick := 0
var running := false
var next_gate := 0
var laps: Array[Dictionary] = []  ## {lap, ticks, time, sector_ticks, sector_times, joker}
var out_of_order_crossings := 0
var last_gate_crossed := -1  ## last valid gate this lap, for reset-to-track

var penalty_ticks := 0  ## penalties accrued in the running lap (reset-to-track), in ticks
var _lap_start_tick := 0
var _sector_start_tick := 0
var _sector_ticks: Array[int] = []
var _joker := false
var _has_prev := false
var _awaiting_line := false  ## standing start: the first gate-0 crossing after the signal is not a lap end
var _prev := Vector3.ZERO


func _init(p_gates: Array[Gate], p_sector_end_gates: Array[int], p_joker: Gate = null, p_tick_dt := 1.0 / 120.0) -> void:
	gates = p_gates
	sector_end_gates = p_sector_end_gates
	joker_gate = p_joker
	tick_dt = p_tick_dt


func sector_count() -> int:
	return sector_end_gates.size() + 1


## Advance one physics tick with the car's new position.
func step(pos: Vector3) -> void:
	tick += 1
	if _has_prev:
		_crossings(_prev, pos)
	_prev = pos
	_has_prev = true


func _crossings(a: Vector3, b: Vector3) -> void:
	if running and joker_gate != null and joker_gate.crossed_by(a, b):
		_joker = true
	for i in gates.size():
		if not gates[i].crossed_by(a, b):
			continue
		if _awaiting_line and i == 0:
			_awaiting_line = false  # grid to line: lap 1 keeps timing from the start signal
		elif (running or i == 0) and (i == next_gate or (i == 0 and next_gate == gates.size())):
			_accept(i)
		else:
			out_of_order_crossings += 1


func _accept(i: int) -> void:
	if i == 0:
		if running:
			_close_sector()
			var total := tick - _lap_start_tick
			var secs: Array[float] = []
			for st in _sector_ticks:
				secs.append(st * tick_dt)
			var rec := {
				"lap": laps.size() + 1,
				"ticks": total,
				"time": (total + penalty_ticks) * tick_dt,
				"raw_time": total * tick_dt,
				"penalty": penalty_ticks * tick_dt,
				"sector_ticks": _sector_ticks.duplicate(),
				"sector_times": secs,
				"joker": _joker,
			}
			laps.append(rec)
			lap_completed.emit(rec)
		_start_lap()
		next_gate = 1
		last_gate_crossed = 0
		return
	_awaiting_line = false  # a gate i>0 was accepted: the car started past the line, gate 0 now closes the lap
	if sector_end_gates.has(i):
		_close_sector()
	last_gate_crossed = i
	next_gate = i + 1


## Standing-start mode (#141): lap 1 is timed from this explicit start signal (call it on the
## tick the race starts); the first gate-0 crossing afterwards just clears the grid and laps 2+
## run gate-0 to gate-0. Without this call the timer stays in flying-lap mode.
func start_standing() -> void:
	_start_lap()
	next_gate = 1
	last_gate_crossed = 0
	_awaiting_line = true


func _start_lap() -> void:
	running = true
	_lap_start_tick = tick
	_sector_start_tick = tick
	_sector_ticks = []
	_joker = false
	penalty_ticks = 0


func _close_sector() -> void:
	_sector_ticks.append(tick - _sector_start_tick)
	_sector_start_tick = tick


func current_lap_ticks() -> int:
	return tick - _lap_start_tick if running else 0


## Add a time penalty (s) to the running lap's recorded time. Ignored before the first start
## crossing. Sector and raw lap ticks are unaffected; `time` of the lap record includes it.
func add_penalty(seconds: float) -> void:
	if running:
		penalty_ticks += int(round(seconds / tick_dt))


## The car was moved by a reset: forget the previous position so the jump is not a crossing.
func teleported() -> void:
	_has_prev = false
