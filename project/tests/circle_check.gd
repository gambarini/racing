## Steady-state circle test (#83): 30 m radius on Spawn_Circle, tarmac, speed held by a simple
## throttle controller at 8, 12 and 16 m/s. For each speed a secant search finds the constant
## steer input that keeps the car on R = 30 m +/-1.5 m over 5 s after a 3 s settle. Reports steer
## angle and lateral g, fits the understeer gradient K = d(delta - L/R)/d(a_lat) over the points.
## Sign of K is the hard gate; the 1..4 deg/g magnitude is checked only if the sign passes.
## CSV (user://circle_<v>.csv) is written for a failing speed.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/circle_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")

const RADIUS := 30.0
const TOL := 1.5
const MAX_RESID := 0.3 ## m, window points must lie on one circle (steady state)
const SETTLE := 3.0
const WINDOW := 5.0
const SPEEDS := [8.0, 12.0, 16.0]

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _hold_speed(target: float) -> Callable:
	return func(_i: int, v: Vehicle, st: DriverInputState) -> void:
		var e := target - v.linear_velocity.length()
		st.throttle = clampf(0.25 + 0.4 * e, 0.0, 1.0)
		st.brake = clampf(-0.3 * e - 0.2, 0.0, 1.0)


## One run at a constant steer; returns radius stats over the measurement window.
func _run(speed: float, steer: float, csv := "") -> Dictionary:
	var ticks := int((SETTLE + WINDOW) / Scenario.DT)
	var sc := Scenario.new(self, "Spawn_Circle", [{"t": 0.0, "steer": steer}], ticks)
	sc.initial_speed = speed
	sc.controller = _hold_speed(speed)
	sc.csv_path = csv
	var r: Dictionary = await sc.run()
	var i0 := int(SETTLE / Scenario.DT)
	var pts: Array[Vector2] = []
	var vsum := 0.0
	var dsum := 0.0
	for i in range(i0, ticks):
		var p: Vector3 = r.pos[i]
		pts.append(Vector2(p.x, p.z))
		vsum += r.speed[i]
		dsum += r.steer_angle[i]
	var fit := _fit_circle(pts)
	var n := float(pts.size())
	return {"r_fit": fit.r, "resid": fit.resid, "speed": vsum / n, "delta": dsum / n, "csv": r.csv}


## Algebraic (Kasa) least-squares circle fit of the window positions. The path is a circle of
## radius R_ss around a centre that is generally offset from the marker (the entry is tangent
## with a transient), so the radius is taken from the fit, not from the distance to the marker.
## resid = largest distance of any point from the fitted circle (steadiness check).
func _fit_circle(pts: Array[Vector2]) -> Dictionary:
	var m := Vector2.ZERO
	for p in pts:
		m += p
	m /= float(pts.size())
	var suu := 0.0
	var suv := 0.0
	var svv := 0.0
	var suuu := 0.0
	var svvv := 0.0
	var suvv := 0.0
	var svuu := 0.0
	for p in pts:
		var u := p.x - m.x
		var w := p.y - m.y
		suu += u * u
		suv += u * w
		svv += w * w
		suuu += u * u * u
		svvv += w * w * w
		suvv += u * w * w
		svuu += w * u * u
	# Solve [suu suv; suv svv] [uc; vc] = 0.5 [suuu + suvv; svvv + svuu]
	var det := suu * svv - suv * suv
	var b1 := 0.5 * (suuu + suvv)
	var b2 := 0.5 * (svvv + svuu)
	var uc := (b1 * svv - b2 * suv) / det
	var vc := (suu * b2 - suv * b1) / det
	var r := sqrt(uc * uc + vc * vc + (suu + svv) / float(pts.size()))
	var c := m + Vector2(uc, vc)
	var resid := 0.0
	for p in pts:
		resid = maxf(resid, absf(p.distance_to(c) - r))
	return {"r": r, "resid": resid}


func _main() -> void:
	await physics_frame # let the root finish entering the tree before the first spawn
	var def := VehicleDefinition.new()
	var wb := def.wheelbase
	var xs: Array = [] # a_lat in g
	var ys: Array = [] # delta - L/R in deg
	for speed in SPEEDS:
		# Secant on the mean radius error, starting near the kinematic (Ackermann) steer.
		var s_prev := 0.0
		var f_prev := 0.0
		var s := rad_to_deg(atan(wb / RADIUS)) / def.max_steer_angle * 1.5
		var res: Dictionary = {}
		for it in 8:
			res = await _run(speed, s)
			var f: float = res.r_fit - RADIUS
			if absf(f) < 0.2:
				break
			var s_next := s * (1.0 + f / RADIUS) # first guess: curvature proportional to steer
			if it > 0 and absf(f - f_prev) > 1e-6:
				s_next = s - f * (s - s_prev) / (f - f_prev)
			s_prev = s
			f_prev = f
			s = clampf(s_next, 0.0, 1.0)
		var ok: bool = absf(res.r_fit - RADIUS) <= TOL and res.resid <= MAX_RESID
		if not ok:
			res = await _run(speed, s, "user://circle_%d.csv" % int(speed))
		var a_g: float = res.speed * res.speed / res.r_fit / 9.81
		var delta_deg := rad_to_deg(res.delta)
		var under := delta_deg - rad_to_deg(wb / res.r_fit)
		print("circle %.0f m/s: steer input %.4f, front angle %.3f deg, R %.2f m (fit residual %.3f m), v %.2f m/s, a_lat %.3f g, delta-L/R %.3f deg"
				% [speed, s, delta_deg, res.r_fit, res.resid, res.speed, a_g, under])
		cu.check_range("radius at %.0f m/s (m)" % speed, res.r_fit, RADIUS - TOL, RADIUS + TOL, res.csv)
		cu.check_range("steady-state residual at %.0f m/s (m)" % speed, res.resid, 0.0, MAX_RESID, res.csv)
		xs.append(a_g)
		ys.append(under)
	# Least-squares slope of (delta - L/R) vs a_lat.
	var n := float(xs.size())
	var mx := 0.0
	var my := 0.0
	for i in xs.size():
		mx += xs[i]
		my += ys[i]
	mx /= n
	my /= n
	var sxy := 0.0
	var sxx := 0.0
	for i in xs.size():
		sxy += (xs[i] - mx) * (ys[i] - my)
		sxx += (xs[i] - mx) * (xs[i] - mx)
	var k := sxy / sxx
	print("understeer gradient K = %.3f deg/g" % k)
	cu.check(k > 0.0, "understeer gradient is positive (K = %.3f deg/g)" % k)
	if k > 0.0:
		cu.check_range("understeer gradient K (deg/g)", k, 1.0, 4.0)
	cu.finish(self)
