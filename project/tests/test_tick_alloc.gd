extends GutTest
## Per-tick allocation hygiene (#135): the race, powertrain and ghost tick paths use only
## cached/preallocated storage. GDScript has no allocation counter, so this asserts the
## structural properties (no Dictionary-returning call on the tick path, cached arrays are not
## rebuilt, buffers append in place) and that static memory stays flat over 600 ticks.

const DT := 1.0 / 120.0
const TICKS := 600
const MEM_SLACK := 64 * 1024


func test_forward_at_matches_sample() -> void:
	var track := TrackSpline.make_circle(100.0, 8)
	add_child_autofree(track)
	for d in [0.0, 13.7, 250.0, 700.0, -5.0]:
		var s := track.sample(d)
		assert_true((s["forward"] as Vector3).is_equal_approx(track.forward_at(d)), "forward at %.1f" % d)
		assert_true((s["position"] as Vector3).is_equal_approx(track.position_at(d)), "position at %.1f" % d)


func test_race_state_step_memory_flat() -> void:
	var track := TrackSpline.make_circle(100.0, 8)
	add_child_autofree(track)
	var det := WrongWayDetector.new()
	var vel := Vector3(0, 0, -20)
	var pos := Vector3(100, 0, 0)
	for i in 60:  # warm up
		det.step(vel, track.forward_at(track.nearest_offset(pos)))
	var before := Performance.get_monitor(Performance.MEMORY_STATIC)
	for i in TICKS:
		det.step(vel, track.forward_at(track.nearest_offset(pos)))
	assert_lt(Performance.get_monitor(Performance.MEMORY_STATIC) - before, MEM_SLACK)


func test_powertrain_driven_cached_and_memory_flat() -> void:
	for layout in [PowertrainDefinition.Layout.RWD, PowertrainDefinition.Layout.FWD, PowertrainDefinition.Layout.AWD]:
		var d := PowertrainDefinition.new()
		d.layout = layout
		var pt := Powertrain.new(d)
		assert_eq(pt.driven, d.driven_wheels(), "driven matches the definition")
		var awd: bool = layout == PowertrainDefinition.Layout.AWD
		for i in 60:
			_tick(pt, awd)
		var before := Performance.get_monitor(Performance.MEMORY_STATIC)
		for i in TICKS:
			_tick(pt, awd)
		assert_lt(Performance.get_monitor(Performance.MEMORY_STATIC) - before, MEM_SLACK)


func _tick(pt: Powertrain, awd: bool) -> void:
	if awd:
		pt.step_awd(DT, 1.0, 20.0, 20.0, 20.0, 20.0, 0.0, 5.0)
	else:
		pt.step(DT, 1.0, 20.0, 20.0, 0.0, 5.0)


func test_ghost_add_sample_appends_in_place() -> void:
	var g := GhostLap.new()
	var xf := Transform3D(Basis.IDENTITY, Vector3(1, 2, 3))
	for i in TICKS:
		g.add_sample(xf, 0.5, 1.0, 0.0, i % 2 == 0)
	assert_eq(g.sample_count(), TICKS)
	assert_eq(g.inputs.size(), TICKS * GhostLap.INPUT_STRIDE)
	assert_almost_eq(g.poses[GhostLap.POSE_STRIDE * 5 + 2], 3.0, 1e-5)
	assert_eq(g.inputs[3], 1.0)
	assert_eq(g.inputs[7], 0.0)
