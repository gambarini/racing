## World-aligned splat map of surface ids (#19, wiki "Surfaces / M2 blending"). One or two RGBA8
## images, each channel (R,G,B,A) the weight of the matching entry of `ids` (4 per image, max 8).
## Covers the XZ rectangle [origin, origin + size]. Sampled bilinearly; weights renormalised to 1.
## Pure data + lookup: no scene access, deterministic.
class_name SurfaceMap
extends Resource

const MAX_IDS := 8
const EPS := 1e-6

@export var origin := Vector2.ZERO ## world XZ of the map's min corner, m
@export var size := Vector2(100, 100) ## world XZ extent, m
@export var ids: Array[StringName] = [] ## channel -> surface id (image 0: R,G,B,A, image 1: ...)
@export var images: Array[Image] = [] ## RGBA8 splat images (all the same size)


## True when world (x, z) lies inside the map rectangle.
func contains(x: float, z: float) -> bool:
	return x >= origin.x and z >= origin.y and x <= origin.x + size.x and z <= origin.y + size.y


## Normalised weights at world (x, z) as {id: weight}, summing to 1 over ids. Returns an empty
## Dictionary outside the map or where all weights are zero (caller falls back to the collider).
func sample(x: float, z: float) -> Dictionary:
	if images.is_empty() or not contains(x, z):
		return {}
	var w0: int = images[0].get_width()
	var h0: int = images[0].get_height()
	# Texel centres sit at (i + 0.5) / n of the extent; clamp so edges extend flat.
	var fx := clampf((x - origin.x) / size.x * w0 - 0.5, 0.0, float(w0 - 1))
	var fz := clampf((z - origin.y) / size.y * h0 - 0.5, 0.0, float(h0 - 1))
	var ix := mini(int(fx), maxi(w0 - 2, 0))
	var iz := mini(int(fz), maxi(h0 - 2, 0))
	var tx := fx - ix
	var tz := fz - iz
	var ix1 := mini(ix + 1, w0 - 1)
	var iz1 := mini(iz + 1, h0 - 1)
	var out := {}
	var total := 0.0
	for im in images.size():
		var img := images[im]
		var c00 := img.get_pixel(ix, iz)
		var c10 := img.get_pixel(ix1, iz)
		var c01 := img.get_pixel(ix, iz1)
		var c11 := img.get_pixel(ix1, iz1)
		var c := (c00 * (1.0 - tx) + c10 * tx) * (1.0 - tz) + (c01 * (1.0 - tx) + c11 * tx) * tz
		for ch in 4:
			var k := im * 4 + ch
			if k >= ids.size():
				break
			var w: float = c[ch]
			if w > EPS:
				out[ids[k]] = out.get(ids[k], 0.0) + w
				total += w
	if total <= EPS:
		return {}
	for k in out:
		out[k] = out[k] / total
	return out
