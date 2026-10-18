## Quarry surface audio check (#130): VehicleAudio on the car-in-track scene, run headless (no audio
## device needed; players are inspected, not listened to).
##  1. the scene's VehicleAudio is a player bound to 4 wheels and stays within the voice budget; a
##     copy with is_player = false (AI / ghost) creates no players,
##  2. identification proxy: at mid-zone of each of the 5 Quarry surfaces, steady 15 m/s straight,
##     the loudest roll loop is that surface's and the 5 (gain, pitch) pairs are pairwise distinct,
##  3. slip proxy on tarmac and gravel: launch from rest and lock-up braking make the slip loop
##     audible, steady running leaves it silent, and the two surfaces use different slip streams,
##  4. one autopilot lap: no player's volume moves >= 6 dB per 50 ms in the audible range
##     (tarmac -> dirt -> gravel -> dirt -> mud crossfades included), the lap time equals the lap
##     without VehicleAudio (audio must not touch physics), and the per-surface slip magnitude
##     statistics (p50 / p95, straight vs cornering) are printed for threshold tuning.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/quarry_audio_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const IDS: Array[StringName] = [&"tarmac", &"dirt", &"gravel", &"mud", &"grass"]
const GRASS_S := 10.0 ## flat straight start zone; grass is sampled beside the road there
const GRASS_OFFSET := 8.0 ## m beyond the road edge
const WIN := 6 ## ticks per 50 ms at 120 Hz
const AUDIBLE_DB := -40.0 ## below this a loop is in its start/stop snap region
const SKIP_TICKS := 120 * 6 ## standing-start launch excluded from the slip statistics
const MAX_LAP_TICKS := 120 * 120
const GHOST := "user://test_ghost_quarry_audio.dat" ## never the player's user://ghost_best.dat (#153)

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _spawn(player: bool, remove := false) -> QuarryDrive:
	var d: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	var a: VehicleAudio = d.get_node("Vehicle/VehicleAudio")
	if remove:
		a.free()
	else:
		a.is_player = player
	d.get_node("TimeTrial").ghost_path = GHOST
	root.add_child(d)
	return d


## Stops every voice before freeing, so the audio server holds no playback (clean exit).
func _dispose(d: QuarryDrive) -> void:
	for pl in d.find_children("*", "AudioStreamPlayer", true, false):
		pl.stop()
	d.queue_free()


func _audio(d: QuarryDrive) -> VehicleAudio:
	return d.get_node("Vehicle/VehicleAudio")


## Lateral offset (m, + = right of travel) at which `id` is sampled.
func _lat(q: Quarry, id: StringName, s: float) -> float:
	return q.road_half(s) + GRASS_OFFSET if id == &"grass" else 0.0


func _pos(q: Quarry, s: float, lat: float) -> Vector3:
	var smp: Dictionary = q.track.sample(s)
	var fwd: Vector3 = smp["forward"]
	return (smp["position"] as Vector3) + fwd.cross(Vector3.UP) * lat


func _weight(q: Quarry, s: float, lat: float, id: StringName) -> float:
	var p := _pos(q, s, lat)
	return q.terrain.surface_map.sample(p.x, p.z).get(id, 0.0)


## Middle of the longest purest stretch of `id` (purity over +-5 m) on the main line.
func _mid_zone(q: Quarry, id: StringName) -> float:
	if id == &"grass":
		return GRASS_S
	var n := int(q.track.length() / 2.0)
	var pur := PackedFloat32Array()
	pur.resize(n)
	var best := -1.0
	for i in n:
		var m := 1.0
		for d in range(-5, 6, 5):
			m = minf(m, _weight(q, i * 2.0 + d, 0.0, id))
		pur[i] = m
		best = maxf(best, m)
	var run_lo := 0
	var best_lo := 0
	var best_len := 0
	for i in n + 1:
		if i < n and pur[i] >= 0.99:
			continue
		if i - run_lo > best_len:
			best_len = i - run_lo
			best_lo = run_lo
		run_lo = i + 1
	return (best_lo + best_lo + best_len - 1) * 1.0


## Puts the car at distance s (offset lat), heading along the line, moving at `speed`.
func _teleport(d: QuarryDrive, s: float, lat: float, speed: float) -> void:
	var fwd: Vector3 = d.quarry.track.sample(s)["forward"]
	var pos := _pos(d.quarry, s, lat)
	pos.y = d.quarry.terrain.height_at(pos.x, pos.z) + d.spawn_lift
	d.vehicle.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), pos)
	d.vehicle.linear_velocity = fwd * speed
	d.vehicle.angular_velocity = Vector3.ZERO
	for w in d.vehicle.wheels:
		w.omega = speed / w.radius


func _speed(d: QuarryDrive) -> float:
	return d.vehicle.linear_velocity.dot(-d.vehicle.global_transform.basis.z)


## Holds `speed` with a throttle/brake P controller for `ticks` ticks, steering straight.
func _hold(d: QuarryDrive, speed: float, ticks: int) -> void:
	for i in ticks:
		var err := speed - _speed(d)
		var st := d.driver_input.state
		st.steer = 0.0
		st.handbrake = false
		st.throttle = clampf(err * 0.5, 0.0, 1.0)
		st.brake = clampf(-err * 0.5, 0.0, 1.0)
		await physics_frame


## Loudest active roll loop: {id, db, pitch, stream}.
func _loudest_roll(a: VehicleAudio) -> Dictionary:
	var best := {"id": &"", "db": -80.0, "pitch": 1.0, "stream": ""}
	for s in a._ids.size():
		var pl: AudioStreamPlayer = a._roll[s]
		if pl != null and pl.volume_db > best.db:
			best = {"id": a._ids[s], "db": pl.volume_db, "pitch": pl.pitch_scale,
					"stream": pl.stream.resource_path}
	return best


func _slip_db(a: VehicleAudio, id: StringName) -> float:
	var pl: AudioStreamPlayer = a._slip[a._idx[id]]
	return pl.volume_db if pl != null else -80.0


## Peak slip-loop volume of `id` over `ticks` ticks of full throttle / full brake / speed hold.
func _max_slip(d: QuarryDrive, id: StringName, ticks: int, mode: String, speed: float) -> float:
	var a := _audio(d)
	var peak := -80.0
	for i in ticks:
		var st := d.driver_input.state
		st.steer = 0.0
		match mode:
			"launch":
				st.throttle = 1.0
				st.brake = 0.0
			"lock":
				st.throttle = 0.0
				st.brake = 1.0
			_:
				var err := speed - _speed(d)
				st.throttle = clampf(err * 0.5, 0.0, 1.0)
				st.brake = clampf(-err * 0.5, 0.0, 1.0)
		await physics_frame
		peak = maxf(peak, _slip_db(a, id))
	return peak


func _pct(a: PackedFloat32Array, p: float) -> float:
	if a.is_empty():
		return -1.0
	var b := a.duplicate()
	b.sort()
	return b[mini(int(p * b.size()), b.size() - 1)]


func _main() -> void:
	await physics_frame

	# 1. scene wiring and voice budget
	var d := _spawn(true)
	await physics_frame
	var a := _audio(d)
	cu.check(a.is_player and a.get_parent() == d.vehicle, "VehicleAudio is a player and a child of the Vehicle")
	await _hold(d, 10.0, 120)
	cu.check(a.wheels.size() == 4, "VehicleAudio is bound to the car's 4 wheels (%d)" % a.wheels.size())
	var n := a.player_count()
	cu.check(n >= 1 and n <= 14, "voice count after 1 s is within 1..14 (%d)" % n)
	_dispose(d)
	var ai := _spawn(false)
	await physics_frame
	await _hold(ai, 10.0, 120)
	cu.check(_audio(ai).player_count() == 0, "AI/ghost instance (is_player = false) creates 0 players")
	_dispose(ai)
	await physics_frame

	# 2. per-surface identification proxy
	var probe := _spawn(false)
	await physics_frame
	var mids := {}
	for id in IDS:
		mids[id] = _mid_zone(probe.quarry, id)
		var s: float = mids[id]
		cu.check(_weight(probe.quarry, s, _lat(probe.quarry, id, s), id) > 0.99,
				"control: %s mid-zone at s=%.0f is pure (%.3f)" % [id, s, _weight(probe.quarry, s, _lat(probe.quarry, id, s), id)])
	_dispose(probe)
	await physics_frame
	var res := {}
	for id in IDS:
		var dr := _spawn(true)
		await physics_frame
		var s: float = mids[id]
		_teleport(dr, s - 30.0, _lat(dr.quarry, id, s), 15.0)
		await _hold(dr, 15.0, 240)
		var r := _loudest_roll(_audio(dr))
		res[id] = r
		var hold_slip := PackedFloat32Array()
		for i in 120:
			await _hold(dr, 15.0, 1)
			for w in dr.vehicle.wheels:
				hold_slip.append(SurfaceAudioMath.slip_amount(w.kappa, w.alpha))
		print("INFO: steady 15 m/s hold slip %s: p50 %.3f p95 %.3f" % [id, _pct(hold_slip, 0.5), _pct(hold_slip, 0.95)])
		cu.check(_pct(hold_slip, 0.95) < SurfaceAudioRegistry.get_profile(id).slip_threshold,
				"%s steady 15 m/s slip p95 is below the slip onset" % id)
		var prof := SurfaceAudioRegistry.get_profile(id)
		print("INFO: %s mid s=%.0f: loudest roll %s %.2f dB pitch %.3f (wheel 0 surface %s)" % [
				id, s, r.id, r.db, r.pitch, dr.vehicle.wheels[0].surface_id])
		cu.check(r.stream == prof.roll_stream.resource_path, "%s is identified by its roll loop (heard %s)" % [id, r.id])
		_dispose(dr)
		await physics_frame
	for i in IDS.size():
		for j in range(i + 1, IDS.size()):
			var ra: Dictionary = res[IDS[i]]
			var rb: Dictionary = res[IDS[j]]
			var dg := absf(ra.db - rb.db)
			var dp := absf(ra.pitch - rb.pitch) / minf(ra.pitch, rb.pitch)
			cu.check(dg >= 0.5 or dp >= 0.03, "%s vs %s distinct: %.2f dB, %.1f %% pitch" % [IDS[i], IDS[j], dg, dp * 100.0])

	# 3. slip proxy on tarmac and gravel
	var slip_streams := {}
	for id in [&"tarmac", &"gravel"]:
		var dr := _spawn(true)
		await physics_frame
		var s: float = mids[id]
		_teleport(dr, s - 25.0, 0.0, 0.0)
		await _hold(dr, 0.0, 120)
		var launch := await _max_slip(dr, id, 72, "launch", 0.0)
		_teleport(dr, s - 25.0, 0.0, 15.0)
		await _hold(dr, 15.0, 120)
		var steady := await _max_slip(dr, id, 120, "hold", 15.0)
		_teleport(dr, s - 25.0, 0.0, 20.0)
		await _hold(dr, 20.0, 12)
		var lock := await _max_slip(dr, id, 90, "lock", 0.0)
		print("INFO: %s slip loop peak: launch %.1f dB, steady %.1f dB, lock-up %.1f dB" % [id, launch, steady, lock])
		cu.check(launch > -20.0, "%s launch slip loop audible (%.1f dB > -20)" % [id, launch])
		cu.check(lock > -20.0, "%s lock-up slip loop audible (%.1f dB > -20)" % [id, lock])
		cu.check(steady < -50.0, "%s steady 15 m/s slip loop silent (%.1f dB < -50)" % [id, steady])
		slip_streams[id] = SurfaceAudioRegistry.get_profile(id).slip_stream.resource_path
		_dispose(dr)
		await physics_frame
	cu.check(slip_streams[&"tarmac"] != slip_streams[&"gravel"], "tarmac and gravel use different slip streams")

	# 4. autopilot lap: crossfade slew, determinism, slip statistics
	var bare := await _lap(false)
	var withaud := await _lap(true)
	cu.check(bare.laps >= 1 and withaud.laps >= 1, "both laps complete (%d / %d)" % [bare.laps, withaud.laps])
	cu.check_range("crossfade worst step per 50 ms (dB)", withaud.worst, 0.0, 5.99)
	cu.check_range("lap time with audio minus without (s)", withaud.time - bare.time, -0.0001, 0.0001)
	print("INFO: lap time without audio %.3f s, with %.3f s; crossfade worst %.2f dB / 50 ms; voices peak %d" % [
			bare.time, withaud.time, withaud.worst, withaud.voices])
	var stats: Dictionary = withaud.stats
	for id in IDS:
		var st: Dictionary = stats.get(id, {})
		if st.is_empty():
			print("INFO: slip %s: no samples" % id)
			continue
		var p := SurfaceAudioRegistry.get_profile(id)
		print("INFO: slip hypot(kappa, alpha) %s: n=%d | all p50 %.3f p95 %.3f | straight p50 %.3f p95 %.3f | corner p50 %.3f p95 %.3f | onset %.3f full %.3f" % [
				id, st.all.size(), _pct(st.all, 0.5), _pct(st.all, 0.95), _pct(st.straight, 0.5), _pct(st.straight, 0.95),
				_pct(st.corner, 0.5), _pct(st.corner, 0.95), p.slip_threshold, p.slip_full])
		if st.straight.size() > 100 and st.corner.size() > 100:
			cu.check(p.slip_threshold > _pct(st.straight, 0.5) and p.slip_threshold < _pct(st.corner, 0.95),
					"%s slip onset %.3f is above straight p50 and below cornering p95" % [id, p.slip_threshold])
			cu.check(p.slip_threshold > _pct(st.straight, 0.95),
					"%s slip onset is above straight p95 (straight running stays quiet)" % id)
	SurfaceAudioRegistry.clear()
	# The audio thread releases stopped playbacks in wall-clock time; headless runs are faster than
	# real time, so give it a moment or the exit reports a leaked stream.
	OS.delay_msec(500)
	await physics_frame
	DirAccess.remove_absolute(GHOST)
	cu.finish(self)


## One lap from the grid under the autopilot. Returns lap time, worst audible 50 ms volume step,
## peak voice count and slip magnitude samples per surface.
func _lap(audio: bool) -> Dictionary:
	var d := _spawn(true, not audio)
	await physics_frame
	var pts := d.quarry.route_points(&"main", &"tarmac")
	var drv := QuarryDriver.new()
	drv.setup(pts, d.quarry.route_mu(pts))
	d.autopilot = drv
	var a: VehicleAudio = _audio(d) if audio else null
	var slots := 40
	var hist := PackedFloat32Array() # ring of the last WIN volumes per player slot
	hist.resize(slots * WIN)
	hist.fill(-80.0)
	var worst := 0.0
	var voices := 0
	var stats := {}
	var ticks := 0
	while d.lap_timer.laps.size() < 1 and ticks < MAX_LAP_TICKS:
		await physics_frame
		ticks += 1
		if not audio or ticks < SKIP_TICKS:
			continue
		var k := 0
		for arr in [a._roll, a._slip]:
			for pl: AudioStreamPlayer in arr:
				if pl == null or k >= slots:
					k += 1
					continue
				var v: float = pl.volume_db if pl.playing else -80.0
				var old := hist[k * WIN + ticks % WIN]
				if v > AUDIBLE_DB and old > AUDIBLE_DB and ticks >= WIN:
					worst = maxf(worst, absf(v - old))
				hist[k * WIN + ticks % WIN] = v
				k += 1
		voices = maxi(voices, a.player_count())
		var curve := absf(drv.kappa_s[drv.index])
		for w in d.vehicle.wheels:
			if not w.is_grounded:
				continue
			var sl := SurfaceAudioMath.slip_amount(w.kappa, w.alpha)
			var st: Dictionary = stats.get(w.surface_id, {})
			if st.is_empty():
				st = {"all": PackedFloat32Array(), "straight": PackedFloat32Array(), "corner": PackedFloat32Array()}
				stats[w.surface_id] = st
			st.all.append(sl)
			if curve < 0.002:
				st.straight.append(sl)
			elif curve > 0.01:
				st.corner.append(sl)
	var t: float = d.lap_timer.laps[0].get("raw_time", -1.0) if d.lap_timer.laps.size() > 0 else -1.0
	var out := {"time": t, "laps": d.lap_timer.laps.size(), "worst": worst, "voices": voices, "stats": stats}
	_dispose(d)
	await physics_frame
	return out
