## Procedural source heightmap for the #22 spike: rolling 12-25 m terrain with a flat plateau
## at the centre. Returns the analytic height and a FORMAT_RF image sampled from it.
class_name TerrainSource
extends RefCounted

const PLATEAU_H := 18.0


static func analytic(x: float, z: float) -> float:
	var h := 18.0 + 4.0 * sin(x * 0.011) * cos(z * 0.009) + 2.5 * sin(x * 0.031 + z * 0.023) \
		+ 0.8 * sin(x * 0.11) * sin(z * 0.13)
	var d := Vector2(x, z).distance_to(Vector2(500, 500))
	return lerpf(PLATEAU_H, h, smoothstep(20.0, 50.0, d))


static func make_image(n: int, cell: float) -> Image:
	var img := Image.create(n, n, false, Image.FORMAT_RF)
	for iz in n:
		for ix in n:
			img.set_pixel(ix, iz, Color(analytic(ix * cell, iz * cell), 0, 0))
	return img


## Splat map (RGBA = tarmac, dirt, grass, gravel) over the same rectangle: tarmac band along
## the x = z diagonal, dirt shoulders, grass elsewhere, gravel disc on the plateau.
static func make_surface_map(extent: float, res: int) -> SurfaceMap:
	var img := Image.create(res, res, false, Image.FORMAT_RGBA8)
	for iz in res:
		for ix in res:
			var x := (ix + 0.5) / res * extent
			var z := (iz + 0.5) / res * extent
			var off := absf(x - z) / 1.41421356
			var t := 1.0 - smoothstep(4.0, 6.0, off)
			var dt := (1.0 - smoothstep(10.0, 14.0, off)) * (1.0 - t)
			var gr := 0.0
			if Vector2(x, z).distance_to(Vector2(500, 500)) < 40.0:
				gr = 1.0
				t = 0.0
				dt = 0.0
			var g := maxf(1.0 - t - dt - gr, 0.0)
			img.set_pixel(ix, iz, Color(t, dt, g, gr))
	var sm := SurfaceMap.new()
	sm.origin = Vector2.ZERO
	sm.size = Vector2(extent, extent)
	sm.ids = [&"tarmac", &"dirt", &"grass", &"gravel"]
	sm.images = [img]
	return sm
