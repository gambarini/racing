## Authoring script for the Quarry racing line (#27). Builds the Quarry, derives a minimum-curvature
## line inside the road (bounded by the road half-width minus a safety margin), samples the
## surface grip under it, solves target speeds and writes the data file
## res://tracks/quarry/quarry_racing_line.tres (main lap plus the joker lap as a sub-resource).
## Run: godot --headless --path project -s res://ai/author_quarry_line.gd
## Not part of the game: it only runs offline, so it allocates freely.
extends SceneTree

const OUT := "res://tracks/quarry/quarry_racing_line.tres"
const SPACING := 2.8 ## m between samples (criterion: <= 4 m)
const MARGIN := 1.25 ## m kept between the line and the road edge (criterion: >= 1.0)
const JOKER_HALF_BOUND := 5.0 - MARGIN
const JUNCTION_BOUND := 3.5 ## max |offset| right at the joker entry/rejoin, growing 0.2 m per metre away
const JUNCTION_GROWTH := 0.2
const RAMP := 30.0 ## m over which the detour blends from the main line offset to its centre line
## Spans (s_a, s_b, lowest offset) that keep the line off the loose inside lane after the start.
const INSIDE_LIMITS := [Vector3(195.0, 330.0, -2.0)]
const ITERATIONS := 40000


func _initialize() -> void:
	_main()


func _main() -> void:
	var q := Quarry.new()
	root.add_child(q)
	await process_frame
	var line := author(q)
	var err := ResourceSaver.save(line, OUT)
	print("main: %d samples, %.1f m, predicted lap %.2f s" % [line.count(), line.length, line.predicted_lap_time()])
	print("joker: %d samples, %.1f m" % [line.joker.count(), line.joker.length])
	print("saved %s err=%d" % [OUT, err])
	quit(0 if err == OK else 1)


static func author(q: Quarry, params: RacingLineParams = null) -> RacingLine:
	var centre := _resample(q.route_points(&"main", &"none"), SPACING, true)
	var n := centre.size()
	var step := q.track_length / n
	var nrm := PackedVector3Array()
	nrm.resize(n)
	for i in n:
		var t := centre[(i + 1) % n] - centre[(i + n - 1) % n]
		nrm[i] = Vector3(-t.z, 0.0, t.x).normalized() ## right of travel
	# Junctions of the detour on the centre line (s of the nearest resampled point).
	var s_a := _nearest_s(centre, step, Vector3(q.joker_xz[0].x, 0, q.joker_xz[0].y))
	var last := q.joker_xz.size() - 1
	var s_b := _nearest_s(centre, step, Vector3(q.joker_xz[last].x, 0, q.joker_xz[last].y))
	var lo := PackedFloat32Array()
	var hi := PackedFloat32Array()
	lo.resize(n)
	hi.resize(n)
	for i in n:
		var s := i * step
		var b := q.road_half(s) - MARGIN
		b = minf(b, JUNCTION_BOUND + JUNCTION_GROWTH * minf(absf(s - s_a), absf(s - s_b)))
		lo[i] = -b
		hi[i] = b
		for lim: Vector3 in INSIDE_LIMITS:
			if s >= lim.x and s <= lim.y:
				lo[i] = maxf(lo[i], lim.z)
	var off := _min_curvature_offsets(centre, nrm, lo, hi)
	var main_pos := PackedVector3Array()
	main_pos.resize(n)
	for i in n:
		main_pos[i] = centre[i] + nrm[i] * off[i]
	var main_line := RacingLine.build(main_pos, off, _mu(q, main_pos), params)

	# Joker lap: main samples outside the detour, the resampled detour in between.
	var det := PackedVector3Array()
	for k in q.joker_xz.size():
		det.append(Vector3(q.joker_xz[k].x, q.joker_ys[k] + 0.05, q.joker_xz[k].y))
	var dpts := _resample(det, SPACING, false)
	var o_a := _offset_at(off, step, s_a)
	var o_b := _offset_at(off, step, s_b)
	var dlen := 0.0
	for k in dpts.size() - 1:
		dlen += dpts[k].distance_to(dpts[k + 1])
	var jpos := PackedVector3Array()
	var joff := PackedFloat32Array()
	for i in n:
		if i * step <= s_a - 0.8:
			jpos.append(main_pos[i])
			joff.append(off[i])
	var span_start := jpos.size()
	var acc := 0.0
	for k in dpts.size():
		if k > 0:
			acc += dpts[k].distance_to(dpts[k - 1])
		var t := (dpts[mini(k + 1, dpts.size() - 1)] - dpts[maxi(k - 1, 0)])
		var right := Vector3(-t.z, 0.0, t.x).normalized()
		var w_a := 1.0 - smoothstep(0.0, RAMP, acc)
		var w_b := 1.0 - smoothstep(0.0, RAMP, dlen - acc)
		var o := clampf(o_a * w_a + o_b * w_b, -JOKER_HALF_BOUND, JOKER_HALF_BOUND)
		jpos.append(dpts[k] + right * o)
		joff.append(o)
	var span_end := jpos.size() - 1
	for i in n:
		if i * step >= s_b + 0.8:
			jpos.append(main_pos[i])
			joff.append(off[i])
	var joker_line := RacingLine.build(jpos, joff, _mu(q, jpos), params)
	main_line.joker = joker_line
	main_line.joker_span_main = Vector2(main_line.nearest_s(jpos[span_start]), main_line.nearest_s(jpos[span_end]))
	main_line.joker_span_joker = Vector2(joker_line.s[span_start], joker_line.s[span_end])
	return main_line


static func _mu(q: Quarry, pts: PackedVector3Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(pts.size())
	for i in pts.size():
		var w := q.terrain.surface_at(pts[i].x, pts[i].z)
		out[i] = SurfaceBlend.blend(w).peak_mu_scale if not w.is_empty() else 0.5
	return out


## Offsets minimising the summed squared second difference of the line, clamped to [lo, hi]
## (Gauss-Seidel on the bi-harmonic condition, over-relaxed).
static func _min_curvature_offsets(c: PackedVector3Array, nrm: PackedVector3Array,
		lo: PackedFloat32Array, hi: PackedFloat32Array) -> PackedFloat32Array:
	var n := c.size()
	var p := c.duplicate()
	var off := PackedFloat32Array()
	off.resize(n)
	for _it in ITERATIONS:
		for i in n:
			var a := p[(i + n - 1) % n]
			var b := p[(i + 1) % n]
			var a2 := p[(i + n - 2) % n]
			var b2 := p[(i + 2) % n]
			var want := (4.0 * (a + b) - (a2 + b2)) / 6.0
			var o := (want - c[i]).dot(nrm[i])
			o = clampf(lerpf(off[i], o, 0.9), lo[i], hi[i])
			off[i] = o
			p[i] = c[i] + nrm[i] * o
	return off


static func _offset_at(off: PackedFloat32Array, step: float, s: float) -> float:
	var n := off.size()
	var f := s / step
	var i := int(floorf(f))
	return lerpf(off[i % n], off[(i + 1) % n], f - i)


static func _nearest_s(c: PackedVector3Array, step: float, p: Vector3) -> float:
	var best := INF
	var best_s := 0.0
	var n := c.size()
	for i in n:
		var a := c[i]
		var b := c[(i + 1) % n]
		var ab := Vector3(b.x - a.x, 0.0, b.z - a.z)
		var t := clampf(Vector3(p.x - a.x, 0.0, p.z - a.z).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var d := Vector3(a.x + ab.x * t - p.x, 0.0, a.z + ab.z * t - p.z).length()
		if d < best:
			best = d
			best_s = (i + t) * step
	return best_s


## Equally spaced resample (step <= `spacing`) of a polyline; closed loops do not repeat point 0.
static func _resample(pts: PackedVector3Array, spacing: float, closed: bool) -> PackedVector3Array:
	var m := pts.size()
	var cum := PackedFloat32Array()
	cum.resize(m + 1)
	var acc := 0.0
	for i in m:
		cum[i] = acc
		if i + 1 < m or closed:
			acc += Vector2(pts[i].x, pts[i].z).distance_to(Vector2(pts[(i + 1) % m].x, pts[(i + 1) % m].z))
	cum[m] = acc
	var count := ceili(acc / spacing)
	var out := PackedVector3Array()
	var total := count if closed else count + 1
	var j := 0
	for k in total:
		var d := acc * k / count
		while j + 1 < m + (1 if closed else 0) and cum[j + 1] < d:
			j += 1
		var a := pts[j % m]
		var b := pts[(j + 1) % m]
		var seg := cum[j + 1] - cum[j]
		out.append(a.lerp(b, clampf((d - cum[j]) / seg, 0.0, 1.0) if seg > 1e-9 else 0.0))
	return out
