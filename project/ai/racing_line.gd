## Racing line (#27): closed loop of samples along a track with a target speed per sample. Data
## resource + queries, no scene access (loads and queries headless). Consumed by the AI driver
## (#28) and the overtaking / personality / recovery issues (#29 #30 #31).
##
## Format (parallel arrays, index i = 0 .. count()-1, driving direction, closed: sample count()-1
## connects back to sample 0 over `ds_last`):
##  s[i]            arc length from sample 0 along the line (m); s[0] = 0, strictly increasing
##  pos[i]          world position (x, road y, z)
##  lane_offset[i]  signed lateral distance (m, + = right of travel) from the route's own centre
##                  line; 0 on the detour centre line of the joker segment
##  target_speed[i] solved speed (m/s) in [params.v_min, params.v_max]
##  curvature[i]    signed curvature (1/m, + = turning right)
##  surface_mu[i]   peak-mu scale of the surface under the sample (1 = tarmac), for #29/#31
## `length` is the closed loop length. Queries wrap s into [0, length).
##
## Variants: the resource holds the MAIN lap. `joker` (when set) is a complete second lap with
## the detour in place of main s in `joker_span_main`; it lives in its own s space (after the
## detour s_joker = s_main + joker_length_delta). `variant = JOKER` makes every query use it.
## s is therefore variant-local: do not carry an s across a variant switch (use nearest_s).
class_name RacingLine
extends Resource

enum Variant { MAIN, JOKER }

@export var s := PackedFloat32Array()
@export var pos := PackedVector3Array()
@export var lane_offset := PackedFloat32Array()
@export var target_speed := PackedFloat32Array()
@export var curvature := PackedFloat32Array()
@export var surface_mu := PackedFloat32Array()
@export var length := 0.0 ## closed loop length, m
@export var joker: RacingLine ## full lap taking the joker detour (null if the track has none)
@export var joker_span_main := Vector2.ZERO ## (entry s, rejoin s) of the detour on the MAIN lap
@export var joker_span_joker := Vector2.ZERO ## (entry s, rejoin s) of the detour in the JOKER lap
@export var variant := Variant.MAIN


func count() -> int:
	var d := _src()
	return d.s.size()


## Lap length (m) of the active variant.
func lap_length() -> float:
	return _src().length


## Detour length minus the main-lap span it replaces (m); 0 without a joker lap.
func joker_length_delta() -> float:
	if joker == null:
		return 0.0
	return joker.length - length


func has_joker() -> bool:
	return joker != null and joker.s.size() > 0


## Position on the line at arc length s (linear between samples).
func point_at(at: float) -> Vector3:
	var d := _src()
	var i := d._index(at)
	var f := d._frac(i, at)
	return d.pos[i].lerp(d.pos[(i + 1) % d.pos.size()], f)


## Horizontal unit tangent (driving direction) at s.
func tangent_at(at: float) -> Vector3:
	var d := _src()
	var i := d._index(at)
	var a := d.pos[i]
	var b := d.pos[(i + 1) % d.pos.size()]
	var t := Vector3(b.x - a.x, 0.0, b.z - a.z)
	return t.normalized() if t.length_squared() > 1e-12 else Vector3(0.0, 0.0, -1.0)


func target_speed_at(at: float) -> float:
	var d := _src()
	var i := d._index(at)
	return lerpf(d.target_speed[i], d.target_speed[(i + 1) % d.s.size()], d._frac(i, at))


func curvature_at(at: float) -> float:
	var d := _src()
	var i := d._index(at)
	return lerpf(d.curvature[i], d.curvature[(i + 1) % d.s.size()], d._frac(i, at))


func lane_offset_at(at: float) -> float:
	var d := _src()
	var i := d._index(at)
	return lerpf(d.lane_offset[i], d.lane_offset[(i + 1) % d.s.size()], d._frac(i, at))


func surface_mu_at(at: float) -> float:
	var d := _src()
	var i := d._index(at)
	return lerpf(d.surface_mu[i], d.surface_mu[(i + 1) % d.s.size()], d._frac(i, at))


## Arc length of the point on the line closest to `p` (XZ distance). Without a hint (hint < 0)
## the whole loop is scanned; with `hint` (a previous result) only samples within `window` m of
## it are, which is what a per-tick caller should do. Allocation-free.
func nearest_s(p: Vector3, hint := -1.0, window := 40.0) -> float:
	var d := _src()
	var n := d.s.size()
	var first := 0
	var last := n - 1
	var wrap := false
	if hint >= 0.0:
		var h := d._index(hint)
		var spacing := d.length / float(n)
		var k := int(ceilf(window / spacing))
		if 2 * k + 1 < n:
			first = h - k
			last = h + k
			wrap = true
	var best := INF
	var best_s := 0.0
	for raw in range(first, last + 1):
		var i := posmod(raw, n) if wrap else raw
		var j := (i + 1) % n
		var a := d.pos[i]
		var b := d.pos[j]
		var abx := b.x - a.x
		var abz := b.z - a.z
		var len2 := abx * abx + abz * abz
		var t := 0.0
		if len2 > 1e-12:
			t = clampf(((p.x - a.x) * abx + (p.z - a.z) * abz) / len2, 0.0, 1.0)
		var dx := a.x + abx * t - p.x
		var dz := a.z + abz * t - p.z
		var dist := dx * dx + dz * dz
		if dist < best:
			best = dist
			best_s = d.s[i] + t * d._seg_len(i)
	return fposmod(best_s, d.length)


## Lap time (s) predicted by integrating ds / v over the active variant, v taken as the mean of
## the two end samples' target speeds' harmonic mean (exact for constant acceleration over ds is
## not needed at <= 4 m spacing).
func predicted_lap_time() -> float:
	var d := _src()
	var n := d.s.size()
	var t := 0.0
	for i in n:
		var v0 := d.target_speed[i]
		var v1 := d.target_speed[(i + 1) % n]
		t += d._seg_len(i) * 2.0 / (v0 + v1)
	return t


## Builds a line from sample positions (closed loop, driving direction): arc lengths, curvature
## (window `k` samples each side) and target speeds from the solver. `lane_offset` and `mu` are
## per-sample inputs; `params` null uses the defaults.
static func build(positions: PackedVector3Array, offsets: PackedFloat32Array, mu: PackedFloat32Array,
		params: RacingLineParams = null, k := 2) -> RacingLine:
	var p := params if params != null else RacingLineParams.new()
	var out := RacingLine.new()
	var n := positions.size()
	out.pos = positions
	out.lane_offset = offsets
	out.surface_mu = mu
	out.s.resize(n)
	var ds := PackedFloat32Array()
	ds.resize(n)
	var acc := 0.0
	for i in n:
		out.s[i] = acc
		var a := positions[i]
		var b := positions[(i + 1) % n]
		ds[i] = Vector2(b.x - a.x, b.z - a.z).length()
		acc += ds[i]
	out.length = acc
	out.curvature = RacingLineSolver.curvature(positions, k)
	out.target_speed = RacingLineSolver.solve(out.curvature, ds, mu, p)
	return out


func _src() -> RacingLine:
	if variant == Variant.JOKER and joker != null and joker.s.size() > 0:
		return joker
	return self


## Index of the sample at or before arc length `at` (wrapped).
func _index(at: float) -> int:
	var w := fposmod(at, length)
	var lo := 0
	var hi := s.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if s[mid] <= w:
			lo = mid
		else:
			hi = mid - 1
	return lo


func _seg_len(i: int) -> float:
	var nxt := s[i + 1] if i + 1 < s.size() else length
	return nxt - s[i]


func _frac(i: int, at: float) -> float:
	var l := _seg_len(i)
	if l <= 1e-9:
		return 0.0
	return clampf((fposmod(at, length) - s[i]) / l, 0.0, 1.0)


## --- Index + fraction accessors (#28): a per-tick caller resolves `sample_index(at)` once and
## reuses it for several fields instead of one binary search per query. Allocation-free. ---

## Index of the sample at or before arc length `at` in the active variant.
func sample_index(at: float) -> int:
	return _src()._index(at)


## Interpolation fraction in [0, 1] of `at` inside segment `i` (from `sample_index`).
func sample_frac(i: int, at: float) -> float:
	return _src()._frac(i, at)


func target_speed_at_index(i: int, f: float) -> float:
	var d := _src()
	return lerpf(d.target_speed[i], d.target_speed[(i + 1) % d.s.size()], f)


func point_at_index(i: int, f: float) -> Vector3:
	var d := _src()
	return d.pos[i].lerp(d.pos[(i + 1) % d.pos.size()], f)
