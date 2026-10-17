class_name WrongWayDetector
extends RefCounted
## Wrong-way flag from velocity vs. the centre-line tangent (issue #106). Pure logic: feed
## `step()` once per physics tick. The flag is set after `set_after` seconds of continuous
## velocity . tangent < 0 and cleared after `clear_after` seconds of continuous heading
## with dot >= 0 (a stationary car counts as correct). Time is counted in whole ticks.

var set_after := 2.0
var clear_after := 0.5
var tick_dt := 1.0 / 120.0
var wrong_way := false

var _wrong_ticks := 0
var _right_ticks := 0


func _init(p_tick_dt := 1.0 / 120.0) -> void:
	tick_dt = p_tick_dt


func step(velocity: Vector3, tangent: Vector3) -> bool:
	if velocity.dot(tangent) < 0.0:
		_wrong_ticks += 1
		_right_ticks = 0
		if not wrong_way and _wrong_ticks * tick_dt >= set_after - 1e-9:
			wrong_way = true
	else:
		_right_ticks += 1
		_wrong_ticks = 0
		if wrong_way and _right_ticks * tick_dt >= clear_after - 1e-9:
			wrong_way = false
	return wrong_way


func reset() -> void:
	wrong_way = false
	_wrong_ticks = 0
	_right_ticks = 0
