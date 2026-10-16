extends GutTest


func test_zero_at_anchor() -> void:
	assert_eq(StaticFriction.hold_force(Vector2.ZERO, Vector2.ZERO, 400.0, 5000.0), Vector2.ZERO)


func test_restoring_and_damping() -> void:
	var f := StaticFriction.hold_force(Vector2(0.001, 0.0), Vector2.ZERO, 400.0, 5000.0)
	assert_lt(f.x, 0.0)
	var d := StaticFriction.hold_force(Vector2.ZERO, Vector2(0.0, 0.1), 400.0, 5000.0)
	assert_lt(d.y, 0.0)


func test_clamped_to_friction_circle() -> void:
	var f := StaticFriction.hold_force(Vector2(1.0, 1.0), Vector2.ZERO, 400.0, 1000.0)
	assert_almost_eq(f.length(), 1000.0, 0.01)
	assert_true(StaticFriction.saturated(f, 1000.0))
	assert_false(StaticFriction.saturated(Vector2(100, 0), 1000.0))
