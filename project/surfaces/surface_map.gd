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
@export var ids: Array[StringName] = []: ## channel -> surface id (image 0: R,G,B,A, image 1: ...)
	set(v):
		ids = v
		_cache_dirty = true
@export var images: Array[Image] = []: ## RGBA8 splat images (all the same size)
	set(v):
		images = v
		_cache_dirty = true

# Cached weights, texel-major: _wt[(iz * _cw + ix) * _stride + k] = weight of ids[k] in [0, 1].
# Built eagerly by `rebuild_cache()` (Quarry.build() calls it at track load, #159). Assigning `ids` or
# `images` sets `_cache_dirty`; in-place edits (append, pixel writes, images[i] = x) need an explicit
# `invalidate_cache()` / `rebuild_cache()`. `sample_into` only rebuilds when dirty (or the sizes moved).
var _wt := PackedFloat32Array()
var _cw := 0 ## cached image width
var _ch := 0 ## cached image height
var _stride := 0 ## cached channels per texel = min(ids.size(), 4 * images.size())
var _cache_dirty := true ## set on ids/images assignment; cleared by rebuild_cache()
var _built_ids := -1 ## ids.size() the cache was built for (guards in-place append/remove)
var _built_images := -1 ## images.size() the cache was built for
var cache_builds := 0 ## number of rebuild_cache() runs (tests / diagnostics)


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


## Marks the cache stale; the next `sample_into` rebuilds it. Use after in-place edits.
func invalidate_cache() -> void:
	_cache_dirty = true


## Rebuilds the weight cache used by `sample_into`. Call it at load time to pre-warm (Quarry.build()
## does); `sample_into` still rebuilds lazily if the cache is dirty. Call it after editing pixels.
func rebuild_cache() -> void:
	cache_builds += 1
	_cache_dirty = false
	_wt.clear()
	_cw = 0
	_ch = 0
	_stride = mini(ids.size(), 4 * images.size())
	_built_ids = ids.size()
	_built_images = images.size()
	if images.is_empty():
		return
	_cw = images[0].get_width()
	_ch = images[0].get_height()
	_wt.resize(_cw * _ch * _stride)
	for im in images.size():
		var c := images[im]
		if c.get_format() != Image.FORMAT_RGBA8:
			c = c.duplicate()
			c.convert(Image.FORMAT_RGBA8)
		var bytes := c.get_data()
		var n := mini(_cw * _ch, bytes.size() / 4)
		for t in n:
			for ch in 4:
				var k := im * 4 + ch
				if k < _stride:
					_wt[t * _stride + k] = bytes[t * 4 + ch] / 255.0


## Allocation-free twin of `sample()` for per-tick queries (4 wheels x 60 Hz, #103).
## Writes the normalised weight of `ids[k]` into `out[k]` for every k (same bilinear + renormalise
## maths as `sample()`), resizing `out` only when it is smaller than `ids`; entries beyond
## ids.size() are left untouched. Returns false and zeroes `out[0..ids.size())` outside the map
## or at zero coverage (where `sample()` returns {}). Reads a cached float copy of the images:
## no Dictionary, no get_pixel. Duplicate ids get one slot each (sample() would sum them).
## Call `rebuild_cache()` after modifying the images' pixels.
func sample_into(x: float, z: float, out: PackedFloat32Array) -> bool:
	var nids := ids.size()
	if out.size() < nids:
		out.resize(nids)
	var rx := x - origin.x
	var rz := z - origin.y
	if rx < 0.0 or rz < 0.0 or rx > size.x or rz > size.y or images.is_empty():
		for k in nids:
			out[k] = 0.0
		return false
	if _cache_dirty or _built_ids != nids or _built_images != images.size():
		rebuild_cache()
	var w0 := _cw
	var h0 := _ch
	var fx := clampf(rx / size.x * w0 - 0.5, 0.0, float(w0 - 1))
	var fz := clampf(rz / size.y * h0 - 0.5, 0.0, float(h0 - 1))
	var ix := int(fx)
	var iz := int(fz)
	if ix > w0 - 2:
		ix = maxi(w0 - 2, 0)
	if iz > h0 - 2:
		iz = maxi(h0 - 2, 0)
	var tx := fx - ix
	var tz := fz - iz
	var ix1 := ix + 1 if ix + 1 < w0 else w0 - 1
	var iz1 := iz + 1 if iz + 1 < h0 else h0 - 1
	var st := _stride
	var o00 := (iz * w0 + ix) * st
	var o10 := (iz * w0 + ix1) * st
	var o01 := (iz1 * w0 + ix) * st
	var o11 := (iz1 * w0 + ix1) * st
	var w00 := (1.0 - tx) * (1.0 - tz)
	var w10 := tx * (1.0 - tz)
	var w01 := (1.0 - tx) * tz
	var w11 := tx * tz
	var total := 0.0
	for k in st:
		var w := _wt[o00 + k] * w00 + _wt[o10 + k] * w10 + _wt[o01 + k] * w01 + _wt[o11 + k] * w11
		if w > EPS:
			out[k] = w
			total += w
		else:
			out[k] = 0.0
	for k in range(st, nids):
		out[k] = 0.0
	if total <= EPS:
		return false
	var inv := 1.0 / total
	for k in st:
		out[k] *= inv
	return true
