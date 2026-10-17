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

const N_CHASSIS := 9
const N_WHEEL_CH := 8
const N_POWERTRAIN := 4
const N_COLS := N_CHASSIS + 4 * N_WHEEL_CH + N_POWERTRAIN
const POWERTRAIN_COL := N_CHASSIS + 4 * N_WHEEL_CH
const SURFACE_CH := 7


static func column_names() -> PackedStringArray:
	var out := PackedStringArray(CHASSIS)
	for w in WHEELS:
		for c in WHEEL_CHANNELS:
			out.append(w + "_" + c)
	out.append_array(POWERTRAIN)
	return out


## Column index of a wheel channel (wheel 0..3, channel 0..7).
static func wheel_col(wheel: int, channel: int) -> int:
	return N_CHASSIS + wheel * N_WHEEL_CH + channel


static func new_row() -> PackedFloat64Array:
	var r := PackedFloat64Array()
	r.resize(N_COLS)
	r.fill(NAN)
	return r
