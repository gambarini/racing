extends GutTest
## SurfaceMap weight cache (#159): pre-warmed at load, explicit dirty flag, ids >= 64 and
## same-count image swaps give correct weights.

func _img(c: Color) -> Image:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return img


func _map(n_ids: int, img: Image) -> SurfaceMap:
	var m := SurfaceMap.new()
	m.size = Vector2(2, 2)
	var ids: Array[StringName] = []
	for i in n_ids:
		ids.append(StringName("s%d" % i))
	m.ids = ids
	m.images = [img]
	return m


func test_prewarm_means_first_sample_does_not_rebuild() -> void:
	var m := _map(4, _img(Color(1, 0, 0, 0)))
	m.rebuild_cache()
	assert_eq(m.cache_builds, 1)
	var out := PackedFloat32Array()
	assert_true(m.sample_into(1.0, 1.0, out))
	m.sample_into(0.2, 0.7, out)
	assert_eq(m.cache_builds, 1, "sample_into must not rebuild after pre-warm")


func test_quarry_build_prewarms() -> void:
	var q := Quarry.new()
	q.build()
	var sm := q.terrain.surface_map
	assert_eq(sm.cache_builds, 1)
	var out := PackedFloat32Array()
	sm.sample_into(0.0, 0.0, out)
	assert_eq(sm.cache_builds, 1, "first sample_into after Quarry.build() must not rebuild")
	q.free()


func test_same_count_image_swap_is_picked_up() -> void:
	var m := _map(4, _img(Color(1, 0, 0, 0)))
	var out := PackedFloat32Array()
	m.sample_into(1.0, 1.0, out)
	assert_almost_eq(out[0], 1.0, 1e-5)
	m.images = [_img(Color(0, 1, 0, 0))] # same image count, same id count
	m.sample_into(1.0, 1.0, out)
	assert_almost_eq(out[0], 0.0, 1e-5)
	assert_almost_eq(out[1], 1.0, 1e-5)


func test_id_swap_same_count_is_picked_up() -> void:
	var m := _map(4, _img(Color(1, 0, 0, 0)))
	var out := PackedFloat32Array()
	m.sample_into(1.0, 1.0, out)
	var builds := m.cache_builds
	var ids: Array[StringName] = [&"a", &"b", &"c", &"d"]
	m.ids = ids
	m.sample_into(1.0, 1.0, out)
	assert_eq(m.cache_builds, builds + 1)


func test_id_count_ge_64_does_not_collide_with_image_count() -> void:
	# Old key images*64+ids: (1 image, 4 ids) = 68 == (0 images, 68 ids); (2, 4) == (1, 68).
	var m := _map(4, _img(Color(1, 0, 0, 0)))
	var out := PackedFloat32Array()
	m.sample_into(1.0, 1.0, out)
	var ids: Array[StringName] = []
	for i in 68:
		ids.append(StringName("x%d" % i))
	m.ids = ids
	m.images = [_img(Color(0, 0, 1, 0)), _img(Color(0, 0, 0, 1))] # 2 images, 68 ids (key 196)
	m.sample_into(1.0, 1.0, out)
	assert_eq(out.size(), 68)
	assert_almost_eq(out[2], 0.5, 1e-5)
	assert_almost_eq(out[7], 0.5, 1e-5)
	assert_almost_eq(out[0], 0.0, 1e-5)


func test_invalidate_after_pixel_edit() -> void:
	var img := _img(Color(1, 0, 0, 0))
	var m := _map(4, img)
	var out := PackedFloat32Array()
	m.sample_into(1.0, 1.0, out)
	img.fill(Color(0, 0, 1, 0))
	m.invalidate_cache()
	m.sample_into(1.0, 1.0, out)
	assert_almost_eq(out[2], 1.0, 1e-5)
