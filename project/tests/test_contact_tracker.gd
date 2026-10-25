extends GutTest
## ContactTracker pure logic (#175): zones, impulse estimate, CSV, params defaults, and the
## RaceManager body-mode contact estimator driven with plain RigidBody3D bodies.


func test_zone_from_normal_and_heading() -> void:
	var fwd := Vector3(0, 0, -1)
	var c := 0.7071
	assert_eq(ContactTracker.zone_of(fwd, fwd, c), ContactTracker.Zone.REAR, "pushed along heading = rear")
	assert_eq(ContactTracker.zone_of(-fwd, fwd, c), ContactTracker.Zone.FRONT, "pushed against heading = front")
	assert_eq(ContactTracker.zone_of(Vector3.RIGHT, fwd, c), ContactTracker.Zone.SIDE)
	assert_eq(ContactTracker.zone_of(Vector3(1, 0, -0.5), fwd, c), ContactTracker.Zone.SIDE, "26 deg off lateral still side")


func test_impulse_estimate() -> void:
	assert_almost_eq(ContactTracker.estimate_impulse(1000.0, 1000.0, 4.0, 0.0), 2000.0, 0.01)
	assert_eq(ContactTracker.estimate_impulse(1000.0, 1000.0, 1.0, 3.0), 0.0, "no negative impulse")


func test_default_params_are_the_estimates() -> void:
	var p := load("res://race/contact_params.tres") as ContactParams
	assert_eq(p.min_impulse, 400.0)
	assert_eq(p.min_time_loss, 1.5)
	assert_eq(p.window, 3.0)
	assert_eq(p.penalty_seconds, 3.0)
	assert_eq(p.cooldown, 5.0)


func test_csv_columns() -> void:
	var t := ContactTracker.new(ContactParams.new(), 2)
	var s := PackedFloat64Array([0.0, 0.0])
	var r := PackedInt32Array([1, 2])
	t.report(10, 1.25, 1, 0, 812.34, 4.5, ContactTracker.Zone.SIDE, s, r)
	assert_eq(t.to_csv(), "time_s,attacker,victim,impulse_ns,rel_speed_ms,zone\n1.250,1,0,812.3,4.50,side\n")


func test_body_mode_estimator_logs_a_rear_end_contact() -> void:
	var track := TrackSpline.make_circle(100.0, 8)
	add_child_autofree(track)
	var mgr := RaceManager.new()
	add_child_autofree(mgr)
	mgr.setup(track, 2)
	mgr.set_physics_process(false)
	var a := RigidBody3D.new()  # attacker, behind
	var b := RigidBody3D.new()  # victim, ahead (-Z is forward)
	for body in [a, b]:
		body.mass = 1000.0
		body.gravity_scale = 0.0
		add_child_autofree(body)
	a.global_position = Vector3(0, 0, 4.2)
	b.global_position = Vector3(0, 0, 0)
	mgr.add_car(a)
	mgr.add_car(b)
	mgr.state = RaceManager.State.RACING
	mgr.go_tick = 0
	mgr._prev_vel[0] = Vector3(0, 0, -10.0)
	mgr._prev_vel[1] = Vector3(0, 0, -6.0)
	# The impact: both end at the same speed along the line.
	a.linear_velocity = Vector3(0, 0, -8.0)
	b.linear_velocity = Vector3(0, 0, -8.0)
	mgr._detect_body_contacts()
	assert_eq(mgr.contact_count(), 1)
	assert_eq(mgr.contacts.attacker[0], 0)
	assert_eq(mgr.contacts.victim[0], 1)
	assert_eq(mgr.contacts.zone[0], ContactTracker.Zone.REAR)
	assert_almost_eq(mgr.contacts.impulse[0], 500.0 * 4.0, 1.0, "reduced mass 500 kg * 4 m/s closing lost")
	assert_almost_eq(mgr.contacts.rel_speed[0], 4.0, 0.01)
