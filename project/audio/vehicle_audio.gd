## Per-surface tire audio and gamepad rumble for one vehicle (#21). Add as a child of a Vehicle
## (or call bind_vehicle); it only reads Wheel state, vehicle.gd is untouched.
## One rolling and one slip looping player per surface id; their gains are the wheel-averaged
## surface weights (#19) times the wheel's speed/slip level, slewed so crossfades never click.
class_name VehicleAudio
extends Node

const IMPACT_MIN_RATE := 0.3 ## m/s compression rate that counts as a landing
const IMPACT_FULL_RATE := 3.0 ## m/s compression rate for full impact volume
const RUMBLE_DURATION := 0.1 ## s per start_joy_vibration call (refreshed every tick)

@export var rumble_enabled := true
@export var rumble_scale := 1.0 ## user setting, 0..1
@export var joy_device := 0

var wheels: Array[Wheel] = []
var rumble_weak := 0.0 ## last computed motor amplitudes (valid with or without a gamepad)
var rumble_strong := 0.0

var _ids: Array = []
var _roll: Dictionary = {} ## id -> AudioStreamPlayer
var _slip: Dictionary = {}
var _roll_g: Dictionary = {} ## id -> current slewed gain
var _slip_g: Dictionary = {}
var _impact: Array[AudioStreamPlayer] = [] ## one per wheel
var _was_grounded: Array[bool] = []
var _built := false


func _ready() -> void:
	var v := get_parent()
	if v is Vehicle:
		bind_vehicle(v)
	_build()


func bind_vehicle(v: Vehicle) -> void:
	wheels = v.wheels


func _build() -> void:
	if _built:
		return
	_built = true
	_ids = SurfaceRegistry.ids()
	for id in _ids:
		var p := SurfaceAudioRegistry.get_profile(id)
		_roll[id] = _make_loop(p.roll_stream)
		_slip[id] = _make_loop(p.slip_stream)
		_roll_g[id] = 0.0
		_slip_g[id] = 0.0
	for i in 4:
		var pl := AudioStreamPlayer.new()
		add_child(pl)
		_impact.append(pl)
		_was_grounded.append(false)


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
	_build()
	var n := wheels.size()
	if n == 0:
		return
	var roll_t: Dictionary = {}
	var slip_t: Dictionary = {}
	var speed_sum: Dictionary = {}
	var weight_sum: Dictionary = {}
	for id in _ids:
		roll_t[id] = 0.0
		slip_t[id] = 0.0
		speed_sum[id] = 0.0
		weight_sum[id] = 0.0
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
		for id in w.surface_weights:
			if not _roll.has(id):
				continue
			var wt: float = w.surface_weights[id]
			var p := SurfaceAudioRegistry.get_profile(id)
			roll_t[id] += wt * SurfaceAudioMath.roll_gain(p, speed) / n
			slip_t[id] += wt * SurfaceAudioMath.slip_gain(p, slip) / n
			speed_sum[id] += wt * speed
			weight_sum[id] += wt
			var r := SurfaceAudioMath.rumble(p, speed, slip)
			weak += wt * r.x / n
			strong += wt * r.y / n
	for id in _ids:
		_roll_g[id] = SurfaceAudioMath.slew(_roll_g[id], roll_t[id], delta)
		_slip_g[id] = SurfaceAudioMath.slew(_slip_g[id], slip_t[id], delta)
		var p := SurfaceAudioRegistry.get_profile(id)
		var avg_speed: float = speed_sum[id] / weight_sum[id] if weight_sum[id] > 0.0 else 0.0
		_apply(_roll[id], _roll_g[id], SurfaceAudioMath.roll_pitch(p, avg_speed))
		_apply(_slip[id], _slip_g[id], 1.0)
	rumble_weak = clampf(weak, 0.0, 1.0)
	rumble_strong = clampf(strong, 0.0, 1.0)
	_send_rumble()


func _apply(pl: AudioStreamPlayer, gain: float, pitch: float) -> void:
	pl.volume_db = linear_to_db(gain) if gain > 0.0001 else -80.0
	pl.pitch_scale = pitch
	var should_play := gain > 0.0001
	if should_play and not pl.playing and pl.is_inside_tree():
		pl.play()
	elif not should_play and pl.playing:
		pl.stop()


func _check_impact(i: int, w: Wheel) -> void:
	if not w.is_grounded or _was_grounded[i] or w.compression_rate < IMPACT_MIN_RATE:
		return
	var p := SurfaceAudioRegistry.get_profile(w.surface_id)
	var pl := _impact[i]
	pl.stream = p.impact_stream
	pl.volume_db = linear_to_db(p.impact_gain * clampf(w.compression_rate / IMPACT_FULL_RATE, 0.1, 1.0))
	if pl.is_inside_tree():
		pl.play()


func _send_rumble() -> void:
	if not rumble_enabled or Input.get_connected_joypads().is_empty():
		return
	Input.start_joy_vibration(joy_device, rumble_weak * rumble_scale, rumble_strong * rumble_scale,
			RUMBLE_DURATION)


func _exit_tree() -> void:
	if not Input.get_connected_joypads().is_empty():
		Input.stop_joy_vibration(joy_device)
