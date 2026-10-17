class_name GhostLap
extends RefCounted
## One recorded lap (issue #25): car transform at 60 Hz plus driver input per sample.
## Pure data + file round-trip. Sample i is at i / SAMPLE_HZ; the last sample is the exact
## lap-end pose and the whole lap is stretched to `ticks` physics ticks on replay.

const SAMPLE_HZ := 60
const FORMAT_VERSION := 1
const MAGIC := "GHST"
const POSE_STRIDE := 7  ## px py pz qx qy qz qw
const INPUT_STRIDE := 4  ## steer throttle brake handbrake

var track_id := ""
var tick_hz := 120
var ticks := 0  ## lap length in physics ticks
var poses := PackedFloat32Array()
var inputs := PackedFloat32Array()


func sample_count() -> int:
	return poses.size() / POSE_STRIDE


func duration() -> float:
	return float(ticks) / tick_hz


func add_sample(xf: Transform3D, steer: float, throttle: float, brake: float, handbrake: bool) -> void:
	var q := xf.basis.get_rotation_quaternion()
	poses.append_array(PackedFloat32Array([xf.origin.x, xf.origin.y, xf.origin.z, q.x, q.y, q.z, q.w]))
	inputs.append_array(PackedFloat32Array([steer, throttle, brake, 1.0 if handbrake else 0.0]))


func pose_at_index(i: int) -> Transform3D:
	var o := i * POSE_STRIDE
	return Transform3D(Basis(Quaternion(poses[o + 3], poses[o + 4], poses[o + 5], poses[o + 6])),
			Vector3(poses[o], poses[o + 1], poses[o + 2]))


## Pose `tick` physics ticks into the lap (clamped to the lap), interpolated.
func pose_at_tick(tick: int) -> Transform3D:
	var n := sample_count()
	if n == 0:
		return Transform3D.IDENTITY
	if n == 1 or ticks <= 0:
		return pose_at_index(0)
	var f := clampf(float(tick) / ticks, 0.0, 1.0) * (n - 1)
	var i := mini(int(floor(f)), n - 2)
	return pose_at_index(i).interpolate_with(pose_at_index(i + 1), f - i)


func input_at_tick(tick: int) -> Array:
	var n := sample_count()
	if n == 0:
		return [0.0, 0.0, 0.0, false]
	var i := clampi(int(round(clampf(float(tick) / maxi(ticks, 1), 0.0, 1.0) * (n - 1))), 0, n - 1)
	var o := i * INPUT_STRIDE
	return [inputs[o], inputs[o + 1], inputs[o + 2], inputs[o + 3] > 0.5]


func to_dict() -> Dictionary:
	return {"version": FORMAT_VERSION, "track_id": track_id, "tick_hz": tick_hz, "ticks": ticks,
			"poses": poses, "inputs": inputs}


static func from_dict(d: Dictionary) -> GhostLap:
	if int(d.get("version", 0)) != FORMAT_VERSION or not d.has("poses") or not d.has("inputs"):
		return null
	var g := GhostLap.new()
	g.track_id = str(d.get("track_id", ""))
	g.tick_hz = int(d.get("tick_hz", 120))
	g.ticks = int(d.get("ticks", 0))
	g.poses = d["poses"]
	g.inputs = d["inputs"]
	if g.poses.size() % POSE_STRIDE != 0 or g.inputs.size() / INPUT_STRIDE != g.sample_count():
		return null
	return g


func save(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	var body := var_to_bytes(to_dict())
	f.store_buffer(MAGIC.to_ascii_buffer())
	f.store_32(body.size())
	f.store_buffer(_digest(body))
	f.store_buffer(body)
	f.close()
	return true


static func _digest(body: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	return ctx.finish()


## Null when the file is missing, truncated or corrupt.
static func load_file(path: String) -> GhostLap:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var data := f.get_buffer(f.get_length())
	f.close()
	if data.size() < 40 or data.slice(0, 4) != MAGIC.to_ascii_buffer():
		return null
	var n := data.decode_u32(4)
	if data.size() != 40 + n or data.slice(8, 40) != _digest(data.slice(40)):
		return null
	var v: Variant = bytes_to_var(data.slice(40))
	return from_dict(v) if v is Dictionary else null
