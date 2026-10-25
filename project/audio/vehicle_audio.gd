## Per-surface tire audio and gamepad rumble for the player's vehicle (#21). Add as a child of a
## Vehicle (or call bind_vehicle); it only reads Wheel state, vehicle.gd is untouched.
## Wired into the car-in-track scene (#130): tracks/quarry/quarry_drive.tscn has it as a child of
## Vehicle with is_player = true. A spawner of AI cars / ghosts sets `is_player = false` on the
## instance before adding it to the tree: such instances create no players and never touch the gamepad.
## Loops are created lazily, one rolling + one slip player per surface actually seen under a wheel;
## their gains are the wheel-averaged surface weights (#19) times the wheel's speed/slip level,
## slewed so crossfades never click. step() allocates nothing.
class_name VehicleAudio
extends Node

const IMPACT_MIN_RATE := 0.3 ## m/s compression rate that counts as a landing
const IMPACT_FULL_RATE := 3.0 ## m/s compression rate for full impact volume
const RUMBLE_DURATION := 0.1 ## s per start_joy_vibration call (refreshed every tick)

@export var is_player := false ## only the player car makes tire sound and rumble
@export var rumble_enabled := true
@export var rumble_scale := 1.0 ## user setting, 0..1
@export var joy_device := 0

var wheels: Array[Wheel] = []
var rumble_weak := 0.0 ## last computed motor amplitudes (valid with or without a gamepad)
var rumble_strong := 0.0

var _ids: Array = []
var _idx: Dictionary = {} ## surface id -> index into the arrays below
var _profiles: Array[SurfaceAudioProfile] = []
var _roll: Array[AudioStreamPlayer] = [] ## null until the surface is first seen
var _slip: Array[AudioStreamPlayer] = []
var _roll_g := PackedFloat32Array() ## current slewed gains
var _slip_g := PackedFloat32Array()
var _roll_t := PackedFloat32Array() ## per-tick targets (scratch, reused)
var _slip_t := PackedFloat32Array()
var _speed_sum := PackedFloat32Array()
var _weight_sum := PackedFloat32Array()
var _impact: Array[AudioStreamPlayer] = [] ## one per wheel
var _was_grounded: Array[bool] = []
var _have_pad := false
var _rumbling := false
var _built := false


func _ready() -> void:
	var v := get_parent()
	if v is Vehicle:
		bind_vehicle(v)
	if is_player:
		_build()


func bind_vehicle(v: Vehicle) -> void:
	wheels = v.wheels


## Number of surfaces (roll/slip loop slot pairs). Read-only accessors for tests.
func surface_count() -> int:
	return _ids.size()


func surface_id(s: int) -> StringName:
	return _ids[s]


## Roll loop player of surface slot `s`, or null until that surface was first seen.
func roll_player(s: int) -> AudioStreamPlayer:
	return _roll[s]


## Slip loop player of surface slot `s`, or null until that surface was first seen.
func slip_player(s: int) -> AudioStreamPlayer:
	return _slip[s]


## Slip loop player of surface `id`, or null (unknown surface or not yet created).
func slip_player_for(id: StringName) -> AudioStreamPlayer:
	var s: int = _idx.get(id, -1)
	return _slip[s] if s >= 0 else null


## Number of AudioStreamPlayer children (voice budget; tested).
func player_count() -> int:
	var n := 0
	for c in get_children():
		if c is AudioStreamPlayer:
			n += 1
	return n


func _build() -> void:
	if _built:
		return
	_built = true
	_ids = SurfaceRegistry.ids()
	var k := _ids.size()
	for i in k:
		_idx[_ids[i]] = i
		_profiles.append(SurfaceAudioRegistry.get_profile(_ids[i]))
		_roll.append(null)
		_slip.append(null)
	for arr in [_roll_g, _slip_g, _roll_t, _slip_t, _speed_sum, _weight_sum]:
		arr.resize(k)
	for i in 4:
		var pl := AudioStreamPlayer.new()
		add_child(pl)
		_impact.append(pl)
		_was_grounded.append(false)
	_have_pad = not Input.get_connected_joypads().is_empty()
	Input.joy_connection_changed.connect(_on_joy_changed)


func _on_joy_changed(_device: int, _connected: bool) -> void:
	_have_pad = not Input.get_connected_joypads().is_empty()


func _make_loop(stream: AudioStream) -> AudioStreamPlayer:
	var pl := AudioStreamPlayer.new()
	pl.stream = _looped(stream)
	pl.volume_db = -80.0
	add_child(pl)
	return pl


## Loop flag lives on the stream resource; set it here so any dropped-in sample loops.
static func _looped(stream: AudioStream) -> AudioStream:
	if stream is AudioStreamWAV:
		var w := stream as AudioStreamWAV
		if w.loop_mode == AudioStreamWAV.LOOP_DISABLED:
			var n := w.data.size() / (2 if w.format == AudioStreamWAV.FORMAT_16_BITS else 1)
			if w.stereo:
				n /= 2
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = n
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	return stream


func _physics_process(delta: float) -> void:
	step(delta)


## One audio-state update. Public so tests can drive it with hand-set Wheel state.
func step(delta: float) -> void:
	if not is_player:
		return
	_build()
	var n := wheels.size()
	if n == 0:
		return
	var k := _ids.size()
	_roll_t.fill(0.0)
	_slip_t.fill(0.0)
	_speed_sum.fill(0.0)
	_weight_sum.fill(0.0)
	var weak := 0.0
	var strong := 0.0
	for i in n:
		var w := wheels[i]
		if i < _was_grounded.size():
			_check_impact(i, w)
			_was_grounded[i] = w.is_grounded
		if not w.is_grounded:
			continue
		var speed := absf(w.omega * w.radius)
		var slip := SurfaceAudioMath.slip_amount(w.kappa, w.alpha)
		for j in w.weight_count:
			var wt: float = w.weights[j]
			if wt <= 0.0:
				continue
			var s: int = _idx.get(w.weight_ids[j], -1)
			if s < 0:
				continue
			var p := _profiles[s]
			_roll_t[s] += wt * SurfaceAudioMath.roll_gain(p, speed) / n
			_slip_t[s] += wt * SurfaceAudioMath.slip_gain(p, slip) / n
			_speed_sum[s] += wt * speed
			_weight_sum[s] += wt
			weak += wt * SurfaceAudioMath.rumble_weak(p, speed, slip) / n
			strong += wt * SurfaceAudioMath.rumble_strong(p, speed, slip) / n
	for s in k:
		if _roll[s] == null:
			if _roll_t[s] <= 0.0 and _slip_t[s] <= 0.0:
				continue # surface never heard yet: no players
			_roll[s] = _make_loop(_profiles[s].roll_stream)
			_slip[s] = _make_loop(_profiles[s].slip_stream)
		_roll_g[s] = SurfaceAudioMath.slew(_roll_g[s], _roll_t[s], delta)
		_slip_g[s] = SurfaceAudioMath.slew(_slip_g[s], _slip_t[s], delta)
		var avg_speed := _speed_sum[s] / _weight_sum[s] if _weight_sum[s] > 0.0 else 0.0
		_apply(_roll[s], _roll_g[s], SurfaceAudioMath.roll_pitch(_profiles[s], avg_speed))
		_apply(_slip[s], _slip_g[s], 1.0)
	rumble_weak = clampf(weak, 0.0, 1.0)
	rumble_strong = clampf(strong, 0.0, 1.0)
	_send_rumble()


func _apply(pl: AudioStreamPlayer, gain: float, pitch: float) -> void:
	var should_play := gain > 0.0001
	pl.volume_db = linear_to_db(gain) if should_play else -80.0
	pl.pitch_scale = pitch
	if should_play and not pl.playing and pl.is_inside_tree():
		pl.play()
	elif not should_play and pl.playing:
		pl.stop()


func _check_impact(i: int, w: Wheel) -> void:
	if not w.is_grounded or _was_grounded[i] or w.compression_rate < IMPACT_MIN_RATE:
		return
	var s: int = _idx.get(w.surface_id, -1)
	var p := _profiles[s] if s >= 0 else _profiles[0]
	var pl := _impact[i]
	pl.stream = p.impact_stream
	pl.volume_db = linear_to_db(p.impact_gain * clampf(w.compression_rate / IMPACT_FULL_RATE, 0.1, 1.0))
	if pl.is_inside_tree():
		pl.play()


func _send_rumble() -> void:
	if not is_player or not rumble_enabled or not _have_pad:
		return
	_rumbling = true
	Input.start_joy_vibration(joy_device, rumble_weak * rumble_scale, rumble_strong * rumble_scale,
			RUMBLE_DURATION)


func _exit_tree() -> void:
	if is_player and _rumbling:
		Input.stop_joy_vibration(joy_device)
