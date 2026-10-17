## Samples a Vehicle (and optional DriverInput) every physics tick into a ring buffer and dumps it
## to CSV (#15). Tooling only: reads sim state, never writes it; sim code does not reference this.
class_name TelemetryRecorder
extends Node

const DUMP_DIR := "user://telemetry"
const G := 9.81

@export var vehicle: Vehicle
@export var driver_input: DriverInput
@export var capacity := TelemetryBuffer.DEFAULT_CAPACITY

var buffer: TelemetryBuffer
var row := TelemetrySchema.new_row() ## latest sample (overlay reads this)
var surfaces: Array[StringName] = [] ## registry: surface id -> index stored in the buffer
var record_cost_us := 0.0 ## running average of record() cost, microseconds
var _t := 0.0
var _prev_vel := Vector3.ZERO
var _have_prev := false
var _cost_n := 0


func _ready() -> void:
	if buffer == null:
		buffer = TelemetryBuffer.new(capacity)
	process_physics_priority = 100 # after the vehicle


func _physics_process(delta: float) -> void:
	if vehicle == null:
		return
	var t0 := Time.get_ticks_usec()
	record(delta)
	_cost_n += 1
	record_cost_us += (float(Time.get_ticks_usec() - t0) - record_cost_us) / float(_cost_n)


## Sample the vehicle once. `dt` is the physics tick length.
func record(dt: float) -> void:
	if buffer == null:
		buffer = TelemetryBuffer.new(capacity)
	var r := row
	var basis := vehicle.global_transform.basis
	var vel := vehicle.linear_velocity
	r[0] = _t
	r[1] = vel.length() * 3.6
	r[2] = vehicle.angular_velocity.dot(basis.y)
	if _have_prev:
		var a := (vel - _prev_vel) / dt
		r[3] = a.dot(basis.x) / G
		r[4] = a.dot(-basis.z) / G
	else:
		r[3] = 0.0
		r[4] = 0.0
	_prev_vel = vel
	_have_prev = true
	if driver_input != null:
		var s := driver_input.state
		r[5] = s.steer
		r[6] = s.throttle
		r[7] = s.brake
		r[8] = 1.0 if s.handbrake else 0.0
	else:
		r[5] = NAN
		r[6] = NAN
		r[7] = NAN
		r[8] = 1.0 if vehicle.handbrake else 0.0
	for i in mini(4, vehicle.wheels.size()):
		var w: Wheel = vehicle.wheels[i]
		r[TelemetrySchema.wheel_col(i, 0)] = w.fz
		r[TelemetrySchema.wheel_col(i, 1)] = w.kappa
		r[TelemetrySchema.wheel_col(i, 2)] = w.alpha
		r[TelemetrySchema.wheel_col(i, 3)] = w.fx
		r[TelemetrySchema.wheel_col(i, 4)] = w.fy
		r[TelemetrySchema.wheel_col(i, 5)] = w.compression
		r[TelemetrySchema.wheel_col(i, 6)] = w.omega * 60.0 / TAU
		r[TelemetrySchema.wheel_col(i, 7)] = float(_surface_index(w.surface_id)) if w.is_grounded else -1.0
	var reg := SurfaceRegistry.ids()
	for i in mini(4, vehicle.wheels.size()):
		var w: Wheel = vehicle.wheels[i]
		for s in mini(reg.size(), TelemetrySchema.N_SURF):
			r[TelemetrySchema.weight_col(i, s)] = float(w.surface_weights.get(reg[s], 0.0)) if w.is_grounded else 0.0
	if vehicle.powertrain != null:
		var pc := TelemetrySchema.POWERTRAIN_COL
		r[pc] = vehicle.rpm()
		r[pc + 1] = float(vehicle.gear())
		r[pc + 2] = vehicle.clutch_slip_rpm()
		r[pc + 3] = vehicle.engine_torque()
	buffer.push(r)
	_t += dt


func _surface_index(id: StringName) -> int:
	var i := surfaces.find(id)
	if i == -1:
		surfaces.append(id)
		i = surfaces.size() - 1
	return i


func surface_name(index: float) -> String:
	if is_nan(index) or index < 0.0 or int(index) >= surfaces.size():
		return ""
	return String(surfaces[int(index)])


## Writes the buffer to `path` (default user://telemetry/<timestamp>.csv). Returns the path or "".
func dump(path := "") -> String:
	if path == "":
		DirAccess.make_dir_recursive_absolute(DUMP_DIR)
		path = "%s/%s.csv" % [DUMP_DIR, Time.get_datetime_string_from_system().replace(":", "-")]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("telemetry: cannot write %s" % path)
		return ""
	f.store_line(",".join(TelemetrySchema.column_names()))
	var cells := PackedStringArray()
	cells.resize(TelemetrySchema.N_COLS)
	for i in buffer.count:
		for c in TelemetrySchema.N_COLS:
			var v := buffer.value(i, c)
			var is_surface := c >= TelemetrySchema.N_CHASSIS and c < TelemetrySchema.POWERTRAIN_COL \
					and (c - TelemetrySchema.N_CHASSIS) % TelemetrySchema.N_WHEEL_CH == TelemetrySchema.SURFACE_CH
			if is_surface:
				cells[c] = surface_name(v)
			elif is_nan(v):
				cells[c] = ""
			elif c == 0:
				cells[c] = "%.6f" % v
			else:
				cells[c] = String.num(v, 5)
		f.store_line(",".join(cells))
	f.close()
	return path
