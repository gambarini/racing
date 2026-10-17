## Column layout of a telemetry sample (#15). A sample is a flat PackedFloat64Array row; a channel
## that is not available yet is NaN (shown as "n/a" in the overlay, empty cell in the CSV).
## Surface ids are stored as an index into the recorder's name registry (-1 = n/a).
class_name TelemetrySchema
extends RefCounted

const WHEELS: Array[String] = ["fl", "fr", "rl", "rr"]
const CHASSIS: Array[String] = ["t", "speed_kmh", "yaw_rate", "lat_g", "long_g", "steer", "throttle", "brake", "handbrake"]
const WHEEL_CHANNELS: Array[String] = ["fz", "kappa", "alpha", "fx", "fy", "travel", "rpm", "surface"]

## Powertrain channels (#11), appended after the wheel block so earlier columns keep their index.
const POWERTRAIN: Array[String] = ["rpm", "gear", "clutch_slip", "engine_torque"]

## Per-wheel surface weights (#19), appended after the powertrain block: one column per
## SurfaceRegistry id, named <wheel>_w_<id>, in SurfaceRegistry.ids() order.
const SURFACE_W_COL := 9 + 4 * 8 + 4 ## first weight column (N_CHASSIS + 4*N_WHEEL_CH + N_POWERTRAIN)

const N_CHASSIS := 9
const N_WHEEL_CH := 8
const N_POWERTRAIN := 4
const N_SURF := 7 ## == SurfaceRegistry.ids().size() (asserted in tests)
## Per-wheel drive torque in Nm (#26), appended last: fl_drive_tq .. rr_drive_tq.
const DRIVE_TQ_COL := N_CHASSIS + 4 * N_WHEEL_CH + N_POWERTRAIN + 4 * N_SURF
const N_COLS := DRIVE_TQ_COL + 4
const POWERTRAIN_COL := N_CHASSIS + 4 * N_WHEEL_CH
const SURFACE_CH := 7


static func column_names() -> PackedStringArray:
	var out := PackedStringArray(CHASSIS)
	for w in WHEELS:
		for c in WHEEL_CHANNELS:
			out.append(w + "_" + c)
	out.append_array(POWERTRAIN)
	for w in WHEELS:
		for id in SurfaceRegistry.ids():
			out.append("%s_w_%s" % [w, id])
	for w in WHEELS:
		out.append(w + "_drive_tq")
	return out


## Column index of a wheel channel (wheel 0..3, channel 0..7).
static func wheel_col(wheel: int, channel: int) -> int:
	return N_CHASSIS + wheel * N_WHEEL_CH + channel


static func new_row() -> PackedFloat64Array:
	var r := PackedFloat64Array()
	r.resize(N_COLS)
	r.fill(NAN)
	return r


## Column index of wheel `wheel`'s weight for registry surface index `surface` (#19).
static func weight_col(wheel: int, surface: int) -> int:
	return SURFACE_W_COL + wheel * N_SURF + surface
