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
			v[i] = minf(v[i], sqrt(v[j] * v[j] + 2.0 * p.brake_limit(mu_scale[i]) * ds[i]))
	for _pass in 2:
		for i in n:
			var j := (i + 1) % n
			v[j] = minf(v[j], sqrt(v[i] * v[i] + 2.0 * p.accel_limit(v[i], mu_scale[i]) * ds[i]))
	return v
