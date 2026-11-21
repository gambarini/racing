## Brake counter-yaw regression guard (#223, playtest #18: "the car is steering the opposite way I'm
## trying to steer when I brake").
## Proving Ground Spawn_Flat, launched at 20 m/s, steer held from t = 0, brake held, 1.5 s.
## Yaw = signed heading change over the run (+ = left; steer + = right, so a normal turn has
## yaw * steer < 0).
##  A. brake 1.0 (fronts lock, no ABS), steer +-0.5 and +-1.0: the yaw must never have the
##     opposite sign to a normal turn (yaw * steer <= YAW_TOL_DEG; locked fronts may understeer, i.e.
##     yaw ~ 0, but never counter-yaw), and +-steer must be mirror images.
##  B. brake 0 / 0.3 / 0.5 with steer -0.5: partial braking (no lock) keeps its pre-#223 turn,
##     within PARTIAL_TOL_DEG of +49.4 / +46.6 / +31.8 deg (brief past-peak slides move it slightly).
## Every row is printed as INFO for the PR's before/after table.
## Run: godot --headless --fixed-fps 120 --path project -s res://tests/brake_yaw_check.gd
extends SceneTree

const Scenario := preload("res://tests/support/scenario.gd")
const CheckUtil := preload("res://tests/support/check_util.gd")
const SPEED := 20.0
const TICKS := 180
const YAW_TOL_DEG := 0.5 ## allowed counter-yaw (numerical noise), deg
const PARTIAL_REF_YAW_DEG := {0.0: 49.4, 0.3: 46.6, 0.5: 31.8} ## pre-#223 yaw at steer -0.5, deg
const PARTIAL_TOL_DEG := 3.0
const MIRROR_TOL_DEG := 0.5

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


func _run(steer: float, brake: float) -> Dictionary:
	var sc := Scenario.new(self, "Spawn_Flat", [{"t": 0.0, "steer": steer, "brake": brake}], TICKS)
	sc.initial_speed = SPEED
	var r: Dictionary = await sc.run()
	var yaw := 0.0
	for i in r.ticks - 1:
		var f0: Vector3 = r.fwd[i]
		var f1: Vector3 = r.fwd[i + 1]
		yaw += atan2(f0.cross(f1).y, f0.dot(f1))
	var mean_steer := 0.0
	for a in r.steer_angle:
		mean_steer += a
	mean_steer /= maxf(r.steer_angle.size(), 1)
	var out := {"yaw": rad_to_deg(yaw), "end_speed": r.end_speed, "steer_deg": rad_to_deg(mean_steer)}
	print("INFO: steer %+.1f brake %.1f -> yaw %+.1f deg, end speed %.1f m/s, mean front steer %+.1f deg" % [
			steer, brake, out.yaw, out.end_speed, out.steer_deg])
	return out


func _main() -> void:
	await physics_frame
	var full := {}
	for steer in [-1.0, -0.5, 0.5, 1.0]:
		var r := await _run(steer, 1.0)
		full[steer] = r
		cu.check(r.yaw * signf(steer) <= YAW_TOL_DEG,
				"A brake 1.0 steer %+.1f: yaw %+.1f deg is not against the steer (counter-yaw <= %.1f)" % [steer, r.yaw, YAW_TOL_DEG])
	for s in [0.5, 1.0]:
		cu.check_range("A brake 1.0 steer +-%.1f mirror |yaw(+) + yaw(-)| deg" % s,
				absf(full[s].yaw + full[-s].yaw), 0.0, MIRROR_TOL_DEG)
	for brake in [0.0, 0.3, 0.5]:
		var r := await _run(-0.5, brake)
		var ref: float = PARTIAL_REF_YAW_DEG[brake]
		cu.check_range("B brake %.1f steer -0.5 yaw deg" % brake, r.yaw, ref - PARTIAL_TOL_DEG, ref + PARTIAL_TOL_DEG)
	cu.finish(self)
