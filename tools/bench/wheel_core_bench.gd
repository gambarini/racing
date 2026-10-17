## Spike #17: per-wheel numeric core, GDScript vs GDExtension (C++). Equivalence over a 600-tick
## scripted input (final omega and Fx within 1e-4 relative) and timing of the same call shape.
## Needs the native library: tools/bench/gdext/build.sh (clang++ only). Without it the native
## columns print "not measured" with the reason.
## Run (repo root): tools/bench/run_bench.sh core   (= godot --headless --fixed-fps 120 --path project
##   -s ../tools/bench/wheel_core_bench.gd). Not a *_check.gd: run_ci.sh does not run it.
extends SceneTree

var CoreGD: GDScript = load("res://../tools/bench/wheel_core_gd.gd")
const EXT := "res://bench_native/wheel_core.gdextension"
const DT := 1.0 / 120.0
const CARS := 12
const TICKS := 1200
const WARMUP := 120

var _gd
var _native: Object = null


func _initialize() -> void:
	_gd = CoreGD.new()
	_main()


func _params() -> PackedFloat64Array:
	var p := TireParams.new()
	return PackedFloat64Array([p.mu_peak, p.mu_slide, p.kappa_peak, p.alpha_peak, p.falloff,
			p.nominal_load, p.load_sensitivity, p.relaxation_length, p.low_speed_floor,
			p.min_relax_rate, 0.32])


## Scripted per-wheel state: wheel 2/3 driven, braking from tick 400, vy and Fz varying.
func _fill(buf: PackedFloat64Array, st: PackedFloat64Array, tick: int) -> void:
	for i in 4:
		var b := 11 + i * 12
		buf[b] = st[i * 4]
		buf[b + 1] = st[i * 4 + 1]
		buf[b + 2] = st[i * 4 + 2]
		buf[b + 3] = st[i * 4 + 3]
		buf[b + 4] = 2.0 * sin(tick * 0.02 + i)
		buf[b + 5] = 3500.0 + 400.0 * sin(tick * 0.013 + i)
		buf[b + 6] = (350.0 * minf(tick / 100.0, 1.0)) if (i >= 2 and tick < 400) else 0.0
		buf[b + 7] = 120.0 if tick >= 400 else 0.0
		buf[b + 8] = 1.6
		buf[b + 9] = 350.0
		buf[b + 10] = 0.3 * 9.81 * 350.0 * 0.05 # a small slope push
		buf[b + 11] = 0.0


## Closed loop: state per wheel = [omega, kappa, alpha, vx]. Returns final outputs and max rel err.
func _run(native: bool, ref_trace: Array = []) -> Dictionary:
	var buf := PackedFloat64Array()
	buf.resize(11 + 48)
	var p := _params()
	for i in 11:
		buf[i] = p[i]
	var st := PackedFloat64Array()
	st.resize(16)
	for i in 4:
		st[i * 4 + 3] = 5.0 # vx
		st[i * 4] = 5.0 / 0.32 # omega
	var trace: Array = []
	var out := PackedFloat64Array()
	var max_rel := 0.0
	for t in 600:
		_fill(buf, st, t)
		out = _native.step4(buf, DT) if native else _gd.step4(buf, DT)
		for i in 4:
			st[i * 4 + 1] = out[i * 5]
			st[i * 4 + 2] = out[i * 5 + 1]
			st[i * 4] = out[i * 5 + 2]
			st[i * 4 + 3] = st[i * 4 + 3] + out[i * 5 + 3] / 350.0 * DT
		trace.append(out.duplicate())
		if native:
			var ref: PackedFloat64Array = ref_trace[t]
			for k in out.size():
				# relative error with a floor per quantity (kappa, alpha, omega, fx, fy) so values that
				# are numerically zero do not dominate: 1e-3, 1e-3, 1e-2 rad/s, 1 N, 1 N
				var rel := absf(out[k] - ref[k]) / maxf(absf(ref[k]), [1e-3, 1e-3, 1e-2, 1.0, 1.0][k % 5])
				max_rel = maxf(max_rel, rel)
	return {"out": out, "trace": trace, "max_rel": max_rel, "st": st}


func _time(native: bool) -> PackedFloat64Array:
	var buf := PackedFloat64Array()
	buf.resize(11 + 48)
	var p := _params()
	for i in 11:
		buf[i] = p[i]
	var st := PackedFloat64Array()
	st.resize(16)
	for i in 4:
		st[i * 4 + 3] = 20.0
		st[i * 4] = 20.0 / 0.32
	var per_car := PackedFloat64Array()
	for t in WARMUP + TICKS:
		var t0 := Time.get_ticks_usec()
		for c in CARS:
			_fill(buf, st, t)
			var out: PackedFloat64Array = _native.step4(buf, DT) if native else _gd.step4(buf, DT)
			if c == 0:
				for i in 4:
					st[i * 4 + 1] = out[i * 5]
					st[i * 4 + 2] = out[i * 5 + 1]
					st[i * 4] = out[i * 5 + 2]
		var t1 := Time.get_ticks_usec()
		if t >= WARMUP:
			per_car.append(float(t1 - t0) / CARS)
	return per_car


func _time_fill_only() -> PackedFloat64Array:
	var buf := PackedFloat64Array()
	buf.resize(11 + 48)
	var st := PackedFloat64Array()
	st.resize(16)
	var per_car := PackedFloat64Array()
	for t in WARMUP + TICKS:
		var t0 := Time.get_ticks_usec()
		for c in CARS:
			_fill(buf, st, t)
		var t1 := Time.get_ticks_usec()
		if t >= WARMUP:
			per_car.append(float(t1 - t0) / CARS)
	return per_car


func _stats(label: String, a: PackedFloat64Array) -> void:
	var s := a.duplicate()
	s.sort()
	var m := 0.0
	for x in s:
		m += x
	m /= s.size()
	print("%s: mean %.2f  p50 %.2f  p99 %.2f  max %.2f us per car-tick (4 wheels)" % [label, m,
			s[int(s.size() * 0.5)], s[int(ceil(0.99 * s.size())) - 1], s[s.size() - 1]])


func _main() -> void:
	await physics_frame
	print("== wheel_core_bench: 4-wheel numeric core, %d cars x %d ticks (+%d warm-up)" % [CARS, TICKS, WARMUP])
	print("godot ", Engine.get_version_info().string, " | ", OS.get_name(), " ", OS.get_version(), " | ",
			OS.get_processor_name())
	var gd := _run(false)
	var fill := _time_fill_only()
	var tgd := _time(false)
	_stats("buffer fill only (marshalling floor, GDScript)", fill)
	_stats("GDScript core (production TireModel/WheelSpin)", tgd)
	var err := ""
	if not FileAccess.file_exists(EXT):
		err = "no native library at %s (run tools/bench/gdext/build.sh)" % EXT
	elif GDExtensionManager.load_extension(EXT) != GDExtensionManager.LOAD_STATUS_OK:
		err = "GDExtensionManager.load_extension failed"
	elif not ClassDB.class_exists("WheelCoreNative"):
		err = "class WheelCoreNative not registered"
	if err != "":
		print("GDExtension C++: not measured: ", err)
		print("C#: not measured: Godot build is not the .NET (mono) editor and no dotnet SDK is installed")
		quit(0)
		return
	_native = ClassDB.instantiate("WheelCoreNative")
	var nat := _run(true, gd.trace)
	var tn := _time(true)
	_stats("GDExtension C++ core (clang++ -O2)", tn)
	var og: PackedFloat64Array = gd.out
	var on: PackedFloat64Array = nat.out
	print("equivalence over 600 scripted ticks (per wheel: omega, Fx, GDScript vs C++):")
	var worst := 0.0
	for i in 4:
		var rw := absf(on[i * 5 + 2] - og[i * 5 + 2]) / maxf(absf(og[i * 5 + 2]), 1e-2)
		var rf := absf(on[i * 5 + 3] - og[i * 5 + 3]) / maxf(absf(og[i * 5 + 3]), 1.0)
		worst = maxf(worst, maxf(rw, rf))
		print("  wheel %d: omega %.9f vs %.9f (rel %s)  Fx %.6f vs %.6f (rel %s)" % [i,
				og[i * 5 + 2], on[i * 5 + 2], String.num_scientific(rw), og[i * 5 + 3], on[i * 5 + 3], String.num_scientific(rf)])
	print("  worst final rel error %s; worst over every output of every tick %s -> %s" % [
			String.num_scientific(worst), String.num_scientific(nat.max_rel), "PASS" if worst <= 1e-4 and nat.max_rel <= 1e-4 else "FAIL"])
	print("C#: not measured: Godot build is not the .NET (mono) editor and no dotnet SDK is installed")
	quit(0)
