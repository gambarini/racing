## Pure weight-averaging of surface definitions (#19): P = sum(w_i * P_i) for every scalar
## parameter (peak/slide/slip scales, Crr, deformation k).
class_name SurfaceBlend
extends RefCounted

const FALLBACK_ID := &"tarmac"


## Weights for one wheel: the map sample inside the map, else the collider surface, else tarmac.
static func resolve_weights(map: SurfaceMap, x: float, z: float, collider_id: StringName) -> Dictionary:
	if map != null:
		var w := map.sample(x, z)
		if not w.is_empty():
			return w
	return {(collider_id if collider_id != &"" else FALLBACK_ID): 1.0}


## Id with the largest weight (ties: the first inserted).
static func dominant(weights: Dictionary) -> StringName:
	var best: StringName = FALLBACK_ID
	var bw := -1.0
	for k in weights:
		if weights[k] > bw:
			bw = weights[k]
			best = k
	return best


## Weighted-average definition. A single-entry weight set returns the registry definition itself
## (bit-identical to M1). Weights are renormalised defensively.
static func blend(weights: Dictionary) -> SurfaceDefinition:
	if weights.size() == 1:
		return SurfaceRegistry.get_surface(weights.keys()[0])
	var total := 0.0
	for k in weights:
		total += weights[k]
	if total <= 0.0:
		return SurfaceRegistry.get_surface(FALLBACK_ID)
	var out := SurfaceDefinition.new()
	out.peak_mu_scale = 0.0
	out.slide_mu_scale = 0.0
	out.peak_slip_scale = 0.0
	out.rolling_resistance = 0.0
	out.deformation_drag = 0.0
	for k in weights:
		var s := SurfaceRegistry.get_surface(k)
		var w: float = weights[k] / total
		out.peak_mu_scale += w * s.peak_mu_scale
		out.slide_mu_scale += w * s.slide_mu_scale
		out.peak_slip_scale += w * s.peak_slip_scale
		out.rolling_resistance += w * s.rolling_resistance
		out.deformation_drag += w * s.deformation_drag
	out.id = &"blend"
	return out


## Allocation-free twin of `dominant` over parallel buffers (ids[k] <-> w[k], k < n).
static func dominant_of(ids: Array[StringName], w: PackedFloat32Array, n: int) -> StringName:
	var best: StringName = FALLBACK_ID
	var bw := -1.0
	for k in n:
		if w[k] > bw:
			bw = w[k]
			best = ids[k]
	return best


## Allocation-free twin of `blend` over parallel buffers. Zero-weight entries are ignored. A single
## positive entry returns the registry definition itself; otherwise the blend is written into
## `out` (caller-owned scratch) and returned.
static func blend_into(ids: Array[StringName], w: PackedFloat32Array, n: int,
		out: SurfaceDefinition) -> SurfaceDefinition:
	var count := 0
	var only := 0
	var total := 0.0
	for k in n:
		if w[k] > 0.0:
			count += 1
			only = k
			total += w[k]
	if count == 1:
		return SurfaceRegistry.get_surface(ids[only])
	if total <= 0.0:
		return SurfaceRegistry.get_surface(FALLBACK_ID)
	out.peak_mu_scale = 0.0
	out.slide_mu_scale = 0.0
	out.peak_slip_scale = 0.0
	out.rolling_resistance = 0.0
	out.deformation_drag = 0.0
	for k in n:
		if w[k] <= 0.0:
			continue
		var s := SurfaceRegistry.get_surface(ids[k])
		var f: float = w[k] / total
		out.peak_mu_scale += f * s.peak_mu_scale
		out.slide_mu_scale += f * s.slide_mu_scale
		out.peak_slip_scale += f * s.peak_slip_scale
		out.rolling_resistance += f * s.rolling_resistance
		out.deformation_drag += f * s.deformation_drag
	out.id = &"blend"
	return out
