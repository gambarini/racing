## Custom heightmap terrain (#22 spike, decision in wiki Track Design "Open questions").
## One float heightmap (n x n samples, `cell` m apart, origin at the min XZ corner) drives
## (a) HeightMapShape3D collision, (b) chunked visual meshes, (c) a pure-GDScript height query
## and (d) an optional SurfaceMap sampled by world XZ (hook for #19). Deterministic, no addons.
class_name HeightmapTerrain
extends Node3D

@export var cell := 1.0 ## m between height samples (collision grid)
@export var mesh_step := 2 ## visual mesh uses every mesh_step-th sample
@export var chunk_cells := 50 ## visual cells per chunk edge (chunk = chunk_cells * mesh_step * cell m)

var n := 0 ## samples per edge
var origin := Vector2.ZERO ## world XZ of sample (0,0)
var heights := PackedFloat32Array() ## row-major, index = iz * n + ix
var surface_map: SurfaceMap
var body: StaticBody3D


## Build from an FORMAT_RF image (one pixel per sample, value = height in m).
func load_from_image(img: Image, world_origin: Vector2) -> void:
	assert(img.get_width() == img.get_height() and img.get_format() == Image.FORMAT_RF)
	n = img.get_width()
	origin = world_origin
	heights = img.get_data().to_float32_array()


func extent() -> float:
	return (n - 1) * cell


## Terrain height at world (x, z); bilinear, clamped at the edges.
func height_at(x: float, z: float) -> float:
	var fx := clampf((x - origin.x) / cell, 0.0, float(n - 1) - 1e-4)
	var fz := clampf((z - origin.y) / cell, 0.0, float(n - 1) - 1e-4)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var i := iz * n + ix
	return lerpf(lerpf(heights[i], heights[i + 1], tx), lerpf(heights[i + n], heights[i + n + 1], tx), tz)


## Surface weights {id: weight} at world (x, z), or {} without a map / outside it.
func surface_at(x: float, z: float) -> Dictionary:
	return surface_map.sample(x, z) if surface_map else {}


## Id of the heaviest surface at world (x, z), or &"" if none.
func dominant_surface_at(x: float, z: float) -> StringName:
	var best := &""
	var bw := 0.0
	var w := surface_at(x, z)
	for id in w:
		if w[id] > bw:
			bw = w[id]
			best = id
	return best


func build_collider() -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	shape.map_data = heights
	body = StaticBody3D.new()
	body.name = "TerrainBody"
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	# HeightMapShape3D is centred on its node and has unit sample spacing.
	body.scale = Vector3(cell, 1.0, cell)
	body.position = Vector3(origin.x + extent() * 0.5, 0.0, origin.y + extent() * 0.5)
	add_child(body)


func build_visual() -> void:
	var step := mesh_step
	var cells := (n - 1) / step
	var chunks := ceili(float(cells) / chunk_cells)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.5, 0.35)
	for cz in chunks:
		for cx in chunks:
			var x0 := cx * chunk_cells
			var z0 := cz * chunk_cells
			var w := mini(chunk_cells, cells - x0)
			var d := mini(chunk_cells, cells - z0)
			var verts := PackedVector3Array()
			var norms := PackedVector3Array()
			verts.resize((w + 1) * (d + 1))
			norms.resize((w + 1) * (d + 1))
			var k := 0
			for iz in d + 1:
				for ix in w + 1:
					var sx := (x0 + ix) * step
					var sz := (z0 + iz) * step
					verts[k] = Vector3(origin.x + sx * cell, heights[sz * n + sx], origin.y + sz * cell)
					var hl := heights[sz * n + maxi(sx - step, 0)]
					var hr := heights[sz * n + mini(sx + step, n - 1)]
					var hd := heights[maxi(sz - step, 0) * n + sx]
					var hu := heights[mini(sz + step, n - 1) * n + sx]
					norms[k] = Vector3(hl - hr, 2.0 * step * cell, hd - hu).normalized()
					k += 1
			var idx := PackedInt32Array()
			idx.resize(w * d * 6)
			var j := 0
			for iz in d:
				for ix in w:
					var a := iz * (w + 1) + ix
					var b := a + 1
					var c := a + w + 1
					var e := c + 1
					idx[j] = a
					idx[j + 1] = c
					idx[j + 2] = b
					idx[j + 3] = b
					idx[j + 4] = c
					idx[j + 5] = e
					j += 6
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = verts
			arrays[Mesh.ARRAY_NORMAL] = norms
			arrays[Mesh.ARRAY_INDEX] = idx
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(0, mat)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.name = "Chunk_%d_%d" % [cx, cz]
			add_child(mi)
