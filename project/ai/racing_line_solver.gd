## Pure target-speed solver for a closed racing line (#27). No scene access, deterministic.
## Per sample: v_corner = min(v_max, sqrt(mu * g / |curvature|) * skill_scale), clamped to
## [v_min, v_max]; then a backward pass (deceleration <= brake limit) and a forward pass
## (acceleration <= accel limit) round the ring, each run twice so the loop closes.
class_name RacingLineSolver
extends RefCounted


## Signed curvature (1/m, + = turning right with +X right and -Z forward) of a closed polyline in
## the XZ plane, Menger curvature of (i - k, i, i + k).
static func curvature(pos: PackedVector3Array, k: int) -> PackedFloat32Array:
	var n := pos.size()
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var a := pos[(i + n - k) % n]
		var b := pos[i]
		var c := pos[(i + k) % n]
		var abx := b.x - a.x
		var abz := b.z - a.z
		var bcx := c.x - b.x
		var bcz := c.z - b.z
		var acx := c.x - a.x
		var acz := c.z - a.z
		var cross := abx * bcz - abz * bcx
		var den := sqrt(abx * abx + abz * abz) * sqrt(bcx * bcx + bcz * bcz) * sqrt(acx * acx + acz * acz)
		out[i] = 2.0 * cross / den if den > 1e-9 else 0.0
	return out


## Copy of `src` (and its joker lap) with the target speeds re-solved at `skill` (the fraction of
## the grip-limited corner speed). Geometry and surface data are shared; only target_speed differs.
## Setup-time (allocates). `base` supplies the car/driver limits; its skill_scale is replaced.
static func resolve_line(src: RacingLine, skill: float, base: RacingLineParams = null) -> RacingLine:
	var p := RacingLineParams.new() if base == null else base.duplicate() as RacingLineParams
	p.skill_scale = skill
	var out := src.duplicate() as RacingLine
	var n := src.s.size() # own arrays, whatever the variant
	var ds := PackedFloat32Array()
	ds.resize(n)
	for i in n:
		var a := src.pos[i]
		var b := src.pos[(i + 1) % n]
		ds[i] = Vector2(b.x - a.x, b.z - a.z).length()
	out.target_speed = solve(src.curvature, ds, src.surface_mu, p)
	if src.joker != null:
		out.joker = resolve_line(src.joker, skill, base)
	return out


## Corner-speed cap (m/s) for curvature `kappa` on a surface: no longitudinal passes applied.
static func corner_speed(kappa: float, mu_scale: float, p: RacingLineParams) -> float:
	var v := sqrt(p.mu(mu_scale) * p.gravity / maxf(absf(kappa), 1e-4)) * p.skill_scale
	return clampf(v, p.v_min, p.v_max)


## Target speeds (m/s) per sample. `kappa` curvature, `ds[i]` distance from sample i to i + 1
## (wrapping), `mu_scale` surface peak-mu scale per sample.
static func solve(kappa: PackedFloat32Array, ds: PackedFloat32Array, mu_scale: PackedFloat32Array,
		p: RacingLineParams) -> PackedFloat32Array:
	var n := kappa.size()
	var v := PackedFloat32Array()
	v.resize(n)
	for i in n:
		v[i] = corner_speed(kappa[i], mu_scale[i], p)
	for _pass in 2:
		for step in n:
			var i := n - 1 - step
			var j := (i + 1) % n
			v[i] = minf(v[i], _brake_entry_speed(v[i], v[j], kappa[i], ds[i], mu_scale[i], p))
	for _pass in 2:
		for i in n:
			var j := (i + 1) % n
			var a := long_budget(p.accel_limit(v[i], mu_scale[i]), v[i], kappa[i], mu_scale[i], p)
			v[j] = minf(v[j], sqrt(v[i] * v[i] + 2.0 * a * ds[i]))
	return v


## Friction-ellipse budget (#154): the longitudinal accel/brake available (m/s^2) at speed `v` in
## curvature `kappa` is `limit * sqrt(max(0, 1 - (v^2 |kappa| / (mu g))^2))`, so the combined
## load sqrt(a_lat^2 + a_long^2) never exceeds mu * g (limit <= mu * g by construction).
static func long_budget(limit: float, v: float, kappa: float, mu_scale: float, p: RacingLineParams) -> float:
	var r := v * v * absf(kappa) / (p.mu(mu_scale) * p.gravity)
	return limit * sqrt(maxf(0.0, 1.0 - r * r))


## Highest entry speed x <= `cap` that can brake down to `v_next` over `ds` with the ellipse
## budget evaluated at x itself (bisection; x - entry(x) is monotone increasing in x).
static func _brake_entry_speed(cap: float, v_next: float, kappa: float, ds: float, mu_scale: float,
		p: RacingLineParams) -> float:
	var limit := p.brake_limit(mu_scale)
	var hi := cap
	if hi <= sqrt(v_next * v_next + 2.0 * long_budget(limit, hi, kappa, mu_scale, p) * ds):
		return hi
	var lo := minf(v_next, cap)
	for _it in 20:
		var mid := 0.5 * (lo + hi)
		if mid <= sqrt(v_next * v_next + 2.0 * long_budget(limit, mid, kappa, mu_scale, p) * ds):
			lo = mid
		else:
			hi = mid
	return lo
