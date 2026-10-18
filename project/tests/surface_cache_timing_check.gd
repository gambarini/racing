## Frame-hitch check (#159): the first physics tick on the Quarry must not pay for building the
## SurfaceMap weight cache. Runs interleaved A/B rounds: A = cache invalidated before the first tick
## (the old lazy behaviour), B = as shipped (pre-warmed in Quarry.build()). "First tick" cost = the
## first surface query after load (where the old code rebuilt); gate: B <= 2x the median physics
## frame interval of ticks 20..119 (estimate). Also asserts no rebuild happened in B.
## Run: godot --headless --path project -s res://tests/surface_cache_timing_check.gd
extends SceneTree

const CheckUtil := preload("res://tests/support/check_util.gd")
const SCENE := "res://tracks/quarry/quarry_drive.tscn"
const ROUNDS := 3
const TICKS := 120

var cu := CheckUtil.new()


func _initialize() -> void:
	_main()


## Returns [first_tick_us, median_us, rebuilds_after_load].
func _run(cold: bool) -> Array:
	var drive: QuarryDrive = (load(SCENE) as PackedScene).instantiate()
	# Audio is irrelevant here, and freed/quitting players leak AudioStreamPlayback at exit.
	drive.get_node("Vehicle/VehicleAudio").free()
	root.add_child(drive)
	await physics_frame
	var sm := drive.quarry.terrain.surface_map
	var builds0 := sm.cache_builds
	if cold:
		sm.invalidate_cache()
	# Direct cost of the first surface query after load (frame-to-frame wall time is too noisy to
	# resolve a ~ms rebuild, so this is the gated number).
	var out := PackedFloat32Array()
	var t1 := Time.get_ticks_usec()
	sm.sample_into(sm.origin.x + 1.0, sm.origin.y + 1.0, out)
	var query_us := float(Time.get_ticks_usec() - t1)
	var d := PackedFloat64Array()
	for i in TICKS:
		var t0 := Time.get_ticks_usec()
		await physics_frame
		d.append(float(Time.get_ticks_usec() - t0))
	var first := query_us
	var slowest10 := 0.0
	for i in 10:
		slowest10 = maxf(slowest10, d[i])
	print("  (info) slowest of first 10 frame intervals: %.0f us" % slowest10)
	var rest := d.slice(20)
	rest.sort()
	var med: float = rest[rest.size() / 2]
	var rebuilds := sm.cache_builds - builds0
	drive.queue_free()
	await physics_frame
	return [first, med, rebuilds]


func _main() -> void:
	await physics_frame
	var ratios_a := []
	var ratios_b := []
	for r in ROUNDS:
		var a: Array = await _run(true)
		var b: Array = await _run(false)
		print("round %d  A(lazy) first query %.0f us med %.0f us rebuilds %d | B(prewarm) first query %.0f us med %.0f us rebuilds %d" % [r, a[0], a[1], a[2], b[0], b[1], b[2]])
		ratios_a.append(a[0] / a[1])
		ratios_b.append(b[0] / b[1])
		cu.check(b[2] == 0, "round %d: no cache rebuild after load" % r)
	ratios_a.sort()
	ratios_b.sort()
	print("median first/median ratio: lazy %.2f, prewarmed %.2f" % [ratios_a[ROUNDS / 2], ratios_b[ROUNDS / 2]])
	cu.check_range("prewarmed first-tick / median tick (estimate)", ratios_b[ROUNDS / 2], 0.0, 2.0)
	cu.finish(self)
