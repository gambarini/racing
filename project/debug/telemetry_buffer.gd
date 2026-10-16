## Fixed-size ring buffer of telemetry rows (#15). One flat preallocated PackedFloat64Array, so
## pushing never allocates. Default capacity: 60 s at 120 Hz.
class_name TelemetryBuffer
extends RefCounted

const DEFAULT_CAPACITY := 7200

var capacity: int
var count := 0
var _head := 0 ## next write slot
var _data := PackedFloat64Array()


func _init(cap := DEFAULT_CAPACITY) -> void:
	capacity = cap
	_data.resize(cap * TelemetrySchema.N_COLS)
	_data.fill(NAN)


func clear() -> void:
	count = 0
	_head = 0


func push(row: PackedFloat64Array) -> void:
	var n := TelemetrySchema.N_COLS
	var base := _head * n
	for i in n:
		_data[base + i] = row[i]
	_head = (_head + 1) % capacity
	if count < capacity:
		count += 1


## Value at column `col` of the i-th oldest buffered row.
func value(i: int, col: int) -> float:
	var slot := (_head - count + i + capacity * 2) % capacity
	return _data[slot * TelemetrySchema.N_COLS + col]
