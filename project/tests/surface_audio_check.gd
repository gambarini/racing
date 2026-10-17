## Headless check (#21): per-surface audio profiles, roll/slip parameter maps, click-free
## crossfade, rumble difference tarmac vs gravel. Run:
## godot --headless --fixed-fps 120 --path project -s res://tests/surface_audio_check.gd
extends SceneTree

const DT := 1.0 / 60.0
var failures := 0
var made_wheels: Array[Wheel] = []


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


func make_wheels(weights: Dictionary, speed: float, kappa := 0.0) -> Array[Wheel]:
	var out: Array[Wheel] = []
	for i in 4:
		var w := Wheel.new()
		w.is_grounded = true
		w.radius = 0.32
		w.omega = speed / 0.32
		w.kappa = kappa
		w.surface_weights = weights
		w.surface_id = SurfaceBlend.dominant(weights)
		out.append(w)
		made_wheels.append(w)
	return out


func make_audio(wheels: Array[Wheel]) -> VehicleAudio:
	var a := VehicleAudio.new()
	a.wheels = wheels
	a.rumble_enabled = false
	get_root().add_child(a)
	return a


func _initialize() -> void:
	# 1. every v1 surface has all three streams
	var all_set := true
	for id in SurfaceRegistry.ids():
		var p := SurfaceAudioRegistry.get_profile(id)
		if p.surface_id != id or p.roll_stream == null or p.slip_stream == null or p.impact_stream == null:
			all_set = false
			printerr("missing stream for ", id)
	check(all_set and SurfaceRegistry.ids().size() == 7, "7 surfaces each have roll, slip and impact streams")

	# 2. pure maps
	var g := SurfaceAudioRegistry.get_profile(&"gravel")
	check(SurfaceAudioMath.roll_gain(g, 10.0) < SurfaceAudioMath.roll_gain(g, 30.0), "roll gain rises with speed")
	check(SurfaceAudioMath.roll_pitch(g, 10.0) < SurfaceAudioMath.roll_pitch(g, 30.0), "roll pitch rises with speed")
	check(SurfaceAudioMath.slip_gain(g, g.slip_threshold) == 0.0 and SurfaceAudioMath.slip_gain(g, 0.0) == 0.0,
			"slip gain is 0 at/below threshold")
	check(SurfaceAudioMath.slip_gain(g, g.slip_threshold + 0.05) > 0.0
			and SurfaceAudioMath.slip_gain(g, g.slip_threshold + 0.05) < SurfaceAudioMath.slip_gain(g, g.slip_full),
			"slip gain rises with slip")

	# 3. node state follows wheel state
	var ws := make_wheels({&"tarmac": 1.0}, 15.0)
	var a := make_audio(ws)
	for i in 30:
		a.step(DT)
	var roll_lo: float = a._roll[&"tarmac"].volume_db
	var pitch_lo: float = a._roll[&"tarmac"].pitch_scale
	for w in ws:
		w.omega = 35.0 / 0.32
	for i in 60:
		a.step(DT)
	check(a._roll[&"tarmac"].volume_db > roll_lo and a._roll[&"tarmac"].pitch_scale > pitch_lo,
			"roll player volume and pitch rise with wheel speed")
	check(a._slip[&"tarmac"].volume_db <= -79.0, "slip player silent below threshold")
	for w in ws:
		w.kappa = 0.3
	for i in 60:
		a.step(DT)
	check(a._slip[&"tarmac"].volume_db > -20.0, "slip player audible above threshold")
	check(a._roll[&"gravel"].volume_db <= -79.0, "other surfaces' loops stay silent")

	# 4. crossfade tarmac -> gravel by weights, slew-limited (< 6 dB per 50 ms)
	for w in ws:
		w.kappa = 0.0
		w.surface_weights = {&"tarmac": 0.5, &"gravel": 0.5}
	var hist_t: Array[float] = []
	var hist_g: Array[float] = []
	for i in 90:
		if i == 30:
			for w in ws:
				w.surface_weights = {&"gravel": 1.0}
				w.surface_id = &"gravel"
		a.step(DT)
		hist_t.append(a._roll[&"tarmac"].volume_db)
		hist_g.append(a._roll[&"gravel"].volume_db)
	var worst := 0.0
	for h in [hist_t, hist_g]:
		for i in range(3, h.size()):
			if h[i] > -40.0 and h[i - 3] > -40.0:
				worst = maxf(worst, absf(h[i] - h[i - 3]))
	check(worst < 6.0, "crossfade step per 50 ms is %.2f dB (< 6)" % worst)
	check(hist_g[-1] > hist_t[-1] and hist_t[-1] <= -39.0, "crossfade completes to gravel")
	free_all(a)

	# 5. rumble differs by surface at equal speed
	var rt := rumble_for(&"tarmac")
	var rg := rumble_for(&"gravel")
	check((rg.y - rt.y) / rg.y >= 0.3, "strong motor tarmac %.3f vs gravel %.3f differs >= 30%%" % [rt.y, rg.y])
	check((rg.x - rt.x) / rg.x >= 0.3, "weak motor tarmac %.3f vs gravel %.3f differs >= 30%%" % [rt.x, rg.x])

	SurfaceAudioRegistry.clear()
	print("RESULT: ", "OK" if failures == 0 else "FAILED (%d)" % failures)
	quit(1 if failures > 0 else 0)


func rumble_for(id: StringName) -> Vector2:
	var a := make_audio(make_wheels({id: 1.0}, 25.0))
	a.step(DT)
	var r := Vector2(a.rumble_weak, a.rumble_strong)
	free_all(a)
	return r


## Free an audio node and every fake wheel made so far (they are orphan Nodes).
func free_all(a: VehicleAudio) -> void:
	a.free()
	for w in made_wheels:
		w.free()
	made_wheels.clear()
