extends GutTest
## Smoke tests proving the GUT framework runs headless.


func test_trivial_assertion() -> void:
	assert_eq(1 + 1, 2, "arithmetic still works")


func test_node3d_transform() -> void:
	var node := Node3D.new()
	add_child_autofree(node)
	node.position = Vector3(1.0, 2.0, 3.0)
	node.rotate_y(PI / 2.0)
	assert_eq(node.position, Vector3(1.0, 2.0, 3.0))
	assert_almost_eq(node.transform.basis.x, Vector3(0.0, 0.0, -1.0), Vector3(0.0001, 0.0001, 0.0001))
