## Vehicle sim CPU benchmark (#17). 12 Vehicles on the Proving Ground, full throttle, straight.
## Times only the vehicle tick (step_suspension + step_powertrain + step_wheels), not the Jolt step.
## Pass 1 times the whole tick per car; pass 2 times each stage separately (a fresh run).
## Prints mean / p50 / p99 / max in microseconds per car-tick and the total per physics tick.
## Not named *_check.gd on purpose: tools/ci/run_ci.sh does not run it.
## Run (repo root): tools/bench/run_bench.sh
##   = godot --headless --fixed-fps 120 --path project -s ../tools/bench/vehicle_bench.gd
## Env: BENCH_CARS (12), BENCH_WARMUP (120), BENCH_TICKS (1200).
extends SceneTree

const PROVING_GROUND := "res://tracks/proving_ground/proving_ground.tscn"

var cars := 12
var warmup := 120
var measured := 1200


class Runner:
	extends Node
	var vehicles: Array[Vehicle] = []
	var staged := false
	var warmup := 120
	var measured := 1200
	var tick := 0
	var full_us := PackedFloat64Array() ## per car-tick
	var per_tick_us := PackedFloat64Array() ## all cars, per physics tick
	var stage_us := [PackedFloat64Array(), PackedFloat64Array(), PackedFloat64Array()]
	var grounded_wheels := 0
	var wheel_samples := 0
	var end_speed := 0.0
	var done := false

	func _physics_process(delta: float) -> void:
		if done:
			return
		var measuring := tick >= warmup
		var tick_total := 0.0
		for v in vehicles:
			if staged:
				var t0 := Time.get_ticks_usec()
				v.step_suspension(delta)
				var t1 := Time.get_ticks_usec()
				v.step_powertrain(delta)
				var t2 := Time.get_ticks_usec()
				v.step_wheels(delta)
				var t3 := Time.get_ticks_usec()
				if measuring:
					stage_us[0].append((t1 - t0))
					stage_us[1].append((t2 - t1))
					stage_us[2].append((t3 - t2))
					tick_total += (t3 - t0)
			else:
				var t0 := Time.get_ticks_usec()
				v.step_suspension(delta)
				v.step_powertrain(delta)
				v.step_wheels(delta)
				var t1 := Time.get_ticks_usec()
				if measuring:
					full_us.append((t1 - t0))
					tick_total += (t1 - t0)
			if measuring:
				for w in v.wheels:
					wheel_samples += 1
					if w.is_grounded:
						grounded_wheels += 1
		if measuring:
			per_tick_us.append(tick_total)
		tick += 1
		if tick >= warmup + measured:
			end_speed = vehicles[0].linear_velocity.length()
			done = true


func _initialize() -> void:
	_main()


func _env_int(name: String, default: int) -> int:
	var s := OS.get_environment(name)
	return int(s) if s != "" else default


func _main() -> void:
	cars = _env_int("BENCH_CARS", cars)
	warmup = _env_int("BENCH_WARMUP", warmup)
	measured = _env_int("BENCH_TICKS", measured)
	await physics_frame
	print("== vehicle_bench: %d cars, %d warm-up + %d measured ticks, physics_ticks_per_second=%d" % [
			cars, warmup, measured, Engine.physics_ticks_per_second])
	print("godot ", Engine.get_version_info().string, " | ", OS.get_name(), " ", OS.get_version(),
			" | ", OS.get_processor_name(), " | ", "debug" if OS.is_debug_build() else "release", " build")
	var r1: Dictionary = await _run(false)
	_report_stats("full tick (suspension+powertrain+wheels)", r1.full_us, r1.per_tick_us)
	print("  sanity: grounded wheel fraction %.4f, car0 end speed %.1f m/s" % [
			float(r1.grounded_wheels) / maxf(r1.wheel_samples, 1), r1.end_speed])
	var r2: Dictionary = await _run(true)
	var names := ["stage probe+suspension (step_suspension)", "stage powertrain (step_powertrain)",
			"stage tire/wheel (step_wheels)"]
	var tot := 0.0
	for i in 3:
		_report_stats(names[i], r2.stage_us[i], PackedFloat64Array())
		tot += _mean(r2.stage_us[i])
	print("stage means sum: %.2f us/car-tick (probe %.0f%%, powertrain %.0f%%, wheels %.0f%%)" % [tot,
			100.0 * _mean(r2.stage_us[0]) / tot, 100.0 * _mean(r2.stage_us[1]) / tot,
			100.0 * _mean(r2.stage_us[2]) / tot])
	print("budget: 125 us/car-tick at 120 Hz; decision threshold p99 <= 100 us")
	quit(0)


func _run(staged: bool) -> Dictionary:
	var world: Node3D = load(PROVING_GROUND).instantiate()
	root.add_child(world)
	var marker: Node3D = world.get_node("Spawn_Flat")
	var runner := Runner.new()
	runner.staged = staged
	runner.warmup = warmup
	runner.measured = measured
	var di := DriverInputState.new()
	di.throttle = 1.0
	for i in cars:
		var v: Vehicle = load("res://vehicle/vehicle.gd").new()
		var xf := marker.global_transform
		# One tarmac lane between the gravel/mud patches (x -5..25); start near the far edge.
		xf.origin += Vector3(-4.0 + 2.5 * i, 0.1, 30.0)
		v.transform = xf
		world.add_child(v)
		v.set_physics_process(false) # the Runner calls the three stages itself, timed
		v.apply_input(di)
		runner.vehicles.append(v)
	root.add_child(runner)
	while not runner.done:
		await physics_frame
	var res := {"full_us": runner.full_us, "per_tick_us": runner.per_tick_us, "stage_us": runner.stage_us,
			"grounded_wheels": runner.grounded_wheels, "wheel_samples": runner.wheel_samples,
			"end_speed": runner.end_speed}
	root.remove_child(runner)
	runner.free()
	world.queue_free()
	await physics_frame
	return res


func _mean(a: PackedFloat64Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for x in a:
		s += x
	return s / a.size()


func _pct(sorted: PackedFloat64Array, p: float) -> float:
	return sorted[clampi(int(ceil(p * sorted.size())) - 1, 0, sorted.size() - 1)]


func _report_stats(label: String, per_car: PackedFloat64Array, per_tick: PackedFloat64Array) -> void:
	var s := per_car.duplicate()
	s.sort()
	print("%s: n=%d  mean %.2f  p50 %.2f  p99 %.2f  max %.2f  (us per car-tick)" % [
			label, s.size(), _mean(s), _pct(s, 0.5), _pct(s, 0.99), s[s.size() - 1]])
	if not per_tick.is_empty():
		var t := per_tick.duplicate()
		t.sort()
		print("  total per physics tick (%d cars): mean %.1f  p50 %.1f  p99 %.1f  max %.1f us (budget 3000 us)" % [
				cars, _mean(t), _pct(t, 0.5), _pct(t, 0.99), t[t.size() - 1]])
