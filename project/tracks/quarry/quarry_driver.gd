## Scripted path-following driver (#104): pure-pursuit steering plus a speed profile derived from
## path curvature and the per-point surface grip. Used by the Quarry drive test to lap the M1 car
## along a route/line; it is test tooling, not the AI (AI tuning is out of scope).
## setup() allocates; drive() is allocation-free (indices, floats and preallocated arrays only).
class_name QuarryDriver
extends RefCounted

const G := 9.81

## Lateral acceleration budget as a fraction of mu * g used for corner speeds.
var lat_g := 0.72
## Peak mu of the reference tyre on dry tarmac; the surface scale multiplies it.
var mu_peak := 1.1
## Braking deceleration as a fraction of mu * g used for the braking pass.
var brake_g := 0.55
var speed_cap := 60.0 ## m/s
## Straight-line speed cap per surface: surface_cap * mu_scale^1.5 (tarmac 55, dirt 36, gravel 29, mud 17).
var surface_cap := 55.0
var speed_floor := 6.0 ## m/s
var lookahead_min := 8.0 ## m
var lookahead_time := 0.45 ## s
var steer_rate := 3.0 ## full-scale steer units per second
var wheelbase := 2.5
var max_steer_rad := deg_to_rad(34.0)
var steer_slack := 0.10 ## rad of steering on top of the geometric angle (tyre slip angle)
var steer_grip := 1.6 ## steering limit as a multiple of the grip-limited lateral acceleration
var stanley_k := 2.0 ## 1/s
var stanley_soft := 2.0 ## m/s
var ff_time := 0.25 ## s of curvature look-ahead for the steering feed-forward
var ff_gain := 1.0
var tc_alpha0 := deg_to_rad(5.0) ## rear slip angle where the throttle starts to lift
var tc_alpha_span := deg_to_rad(8.0)
var tc_kappa0 := 0.12 ## rear slip ratio where the throttle starts to lift
var tc_kappa_span := 0.2
## Speed error (m/s) that maps to full throttle / full brake.
var throttle_span := 3.0
var brake_span := 3.0

var pts := PackedVector3Array() ## closed path, driving direction
var cum := PackedFloat32Array() ## arc length of each point from point 0
var target := PackedFloat32Array() ## target speed per point (m/s)
var mu_now := PackedFloat32Array() ## surface peak-mu scale per point
var kappa_s := PackedFloat32Array() ## signed curvature per point (+ = right turn), 1/m
var n := 0
var length := 0.0
var index := 0 ## nearest path point (progress)
var lap_progress := 0.0 ## path arc length covered since setup, wraps are counted
var steer_cmd := 0.0
var cross_track := 0.0 ## m, signed (+ = path is to the right of the car)
var _started := false


## `points`: closed loop (last point does not repeat the first). `mu`: surface peak-mu scale per point.
func setup(points: PackedVector3Array, mu: PackedFloat32Array) -> void:
	pts = points
	mu_now = mu
	n = pts.size()
	cum.resize(n)
	var acc := 0.0
	for i in n:
		cum[i] = acc
		acc += _flat(pts[i], pts[(i + 1) % n])
	length = acc
	target.resize(n)
	kappa_s.resize(n)
	var k := 4
	for i in n:
		var a := pts[(i + n - k) % n]
		var b := pts[i]
		var c := pts[(i + k) % n]
		var kappa := _curvature(a, b, c)
		var cr := (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)
		kappa_s[i] = kappa if cr >= 0.0 else -kappa
		# the worst grip over the next few metres decides, a corner entry on gravel counts early
		var m := mu[i] * mu_peak
		var v := sqrt(lat_g * m * G / maxf(kappa, 1e-4))
		v = minf(v, surface_cap * pow(mu[i], 1.5))
		target[i] = clampf(v, speed_floor, speed_cap)
	# Smooth the corner profile (min over +-3 points) so single noisy curvature samples do not
	# make the car dip, then run the braking pass round the ring twice.
	var sm := target.duplicate()
	for i in n:
		var lo := target[i]
		for d in range(-3, 4):
			lo = minf(lo, target[(i + d + n) % n])
		sm[i] = lo
	target = sm
	for _pass in 2:
		for step in n:
			var i := (n - 1 - step + n) % n
			var j := (i + 1) % n
			var ds := _flat(pts[i], pts[j])
			var a := brake_g * mu[i] * mu_peak * G
			target[i] = minf(target[i], sqrt(target[j] * target[j] + 2.0 * a * ds))
	index = 0
	_started = false


## Index of the closest path point to `pos` (global search; setup/reset only).
func snap(pos: Vector3) -> void:
	var best := INF
	for i in n:
		var d := _flat2(pts[i], pos)
		if d < best:
			best = d
			index = i
	_started = true


## One physics tick: writes steer/throttle/brake into `st`. `dt` is the tick length.
func drive(v: Vehicle, st: DriverInputState, dt: float) -> void:
	var pos := v.global_position
	if not _started:
		snap(pos)
	# Advance the nearest index within a short window ahead of the last one.
	var best := _flat2(pts[index], pos)
	for step in range(1, 24):
		var j := (index + step) % n
		var d := _flat2(pts[j], pos)
		if d < best:
			best = d
			index = j
	var basis := v.global_transform.basis
	var fwd := -basis.z
	var right := basis.x
	var speed := v.linear_velocity.dot(fwd)
	# Stanley steering on the front axle: heading error + atan(gain * cross-track / speed), plus a
	# feed-forward from the path curvature a little ahead.
	var front := pos + fwd * (wheelbase * 0.5)
	var fi := index
	var fbest := _flat2(pts[fi], front)
	for step in range(1, 12):
		var j := (index + step) % n
		var d := _flat2(pts[j], front)
		if d < fbest:
			fbest = d
			fi = j
	var t := pts[(fi + 1) % n] - pts[(fi + n - 1) % n]
	var tl := maxf(sqrt(t.x * t.x + t.z * t.z), 1e-3)
	var psi := atan2((t.x * right.x + t.z * right.z) / tl, maxf((t.x * fwd.x + t.z * fwd.z) / tl, 0.01))
	var e := (pts[fi].x - front.x) * right.x + (pts[fi].z - front.z) * right.z
	var sp := maxf(absf(speed), 1.0)
	var ahead := (fi + int(clampf(speed * ff_time / 1.5, 0.0, 20.0))) % n
	var delta := psi + atan(stanley_k * e / (sp + stanley_soft)) + atan(wheelbase * kappa_s[ahead]) * ff_gain
	# Never ask for more lateral grip than the surface has (avoids wind-up and saturated steering).
	var dmax := steer_slack + atan(wheelbase * steer_grip * mu_peak * G * mu_now[index] / maxf(speed * speed, 25.0))
	delta = clampf(delta, -dmax, dmax)
	var want := clampf(delta / max_steer_rad, -1.0, 1.0)
	steer_cmd = move_toward(steer_cmd, want, steer_rate * dt)
	st.steer = steer_cmd
	var nb := (index + 1) % n
	var seg := pts[nb] - pts[index]
	var segl := maxf(sqrt(seg.x * seg.x + seg.z * seg.z), 1e-3)
	var rx := pos.x - pts[index].x
	var rz := pos.z - pts[index].z
	# signed distance of the path to the right of the car: positive if the car is left of the path
	cross_track = (rx * seg.z - rz * seg.x) / segl
	var vt := target[index]
	# also respect the target a little ahead (reaction margin)
	var ja := (index + int(clampf(speed * 0.15, 1.0, 12.0))) % n
	vt = minf(vt, target[ja])
	var err := vt - speed
	if err >= 0.0:
		# Traction control: back off while the rear tyres slide sideways or spin.
		var rear := maxf(absf(v.wheels[2].alpha), absf(v.wheels[3].alpha))
		var tc := clampf(1.0 - (rear - tc_alpha0) / tc_alpha_span, 0.0, 1.0)
		var spin := maxf(v.wheels[2].kappa, v.wheels[3].kappa)
		tc = minf(tc, clampf(1.0 - (spin - tc_kappa0) / tc_kappa_span, 0.0, 1.0))
		st.throttle = clampf(err / throttle_span, 0.0, 1.0) * tc
		st.brake = 0.0
	else:
		st.throttle = 0.0
		st.brake = clampf(-err / brake_span, 0.0, 1.0)
	st.handbrake = false


## Path arc length from the current index to path point `j` (for gap measurements).
func distance_to(j: int) -> float:
	var d := cum[j] - cum[index]
	return d if d >= 0.0 else d + length


static func _flat(a: Vector3, b: Vector3) -> float:
	var dx := b.x - a.x
	var dz := b.z - a.z
	return sqrt(dx * dx + dz * dz)


static func _flat2(a: Vector3, pos: Vector3) -> float:
	var dx := a.x - pos.x
	var dz := a.z - pos.z
	return dx * dx + dz * dz


## Menger curvature (1/m) of three points in the XZ plane.
static func _curvature(a: Vector3, b: Vector3, c: Vector3) -> float:
	var cross := (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)
	var ab := _flat(a, b)
	var bc := _flat(b, c)
	var ca := _flat(c, a)
	var den := ab * bc * ca
	return 2.0 * absf(cross) / den if den > 1e-6 else 0.0
