## Human playtest scene for the Quarry (#18 driving feel, #192 AI difficulty). Wraps the existing
## QuarryDrive scene and adds a lap HUD, a per-lap CSV log, reset-to-track (R / pad Y) and, in race
## mode, a field of AI cars with a chosen difficulty under a real RaceManager (countdown, grid,
## penalties, results screen). Debug tooling, not the game HUD (#39). QuarryDrive is untouched.
##
## Launch (GUI, not headless), options after `--`:
##   Godot --path project res://debug/playtest/quarry_playtest.tscn -- --tester=ana
##   Godot --path project res://debug/playtest/quarry_playtest.tscn -- --mode=race --difficulty=easy
## Options: --mode=timetrial|race  --difficulty=easy|medium|hard  --ai=N (1..11)  --laps=N
##          --grid=SLOT (0 = pole, default back)  --seed=N  --tester=NAME
## Output: user://playtest/<tester>_<mode>_<stamp>.csv (path printed at start and shown on the HUD).
extends Node3D

const DRIVE_SCENE := preload("res://tracks/quarry/quarry_drive.tscn")
const RESULTS_SCENE := preload("res://ui/results_screen.tscn")
const LINE := preload("res://tracks/quarry/quarry_racing_line.tres")
const OUT_DIR := "user://playtest"

var opts: Dictionary
var drive: QuarryDrive
var mgr: RaceManager ## race mode only
var monitor: RaceMonitor ## used for its reset_to_track(); its own tick is off (the timer is stepped elsewhere)
var player_id := 0
var ai_vehicles: Array[Vehicle] = []
var ai_drivers: Array[AiDriver] = []
var ai_states: Array[DriverInputState] = []
var ai_ids: Array[int] = []
var lap_times: Array = [] ## player's lap times (s, incl. penalties) in order
var resets := 0
var csv_path := ""
var _csv: FileAccess
var _hud: Label
var _layer: CanvasLayer
var _banner := ""
var _banner_t := 0.0


func _ready() -> void:
	process_physics_priority = 21 # after the RaceManager node (20), like tests/support/field_pilot.gd
	if opts.is_empty(): # a check sets `opts` (PlaytestStats.parse_args) before adding the scene
		opts = PlaytestStats.parse_args(OS.get_cmdline_user_args())
	for e: String in opts.errors:
		push_warning("playtest: " + e)
	drive = DRIVE_SCENE.instantiate()
	add_child(drive)
	_open_csv()
	_make_hud()
	if opts.mode == "race":
		_setup_race()
	else:
		_setup_time_trial()
	print("PLAYTEST: mode=%s difficulty=%s ai=%d laps=%d tester=%s -> %s" % [opts.mode, opts.difficulty,
			opts.ai, opts.laps, opts.tester, ProjectSettings.globalize_path(csv_path)])


func _open_csv() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "")
	csv_path = "%s/%s_%s_%s.csv" % [OUT_DIR, opts.tester, opts.mode, stamp]
	_csv = FileAccess.open(csv_path, FileAccess.WRITE)
	if _csv == null:
		push_warning("playtest: cannot write %s" % csv_path)
		return
	_csv.store_line(PlaytestStats.LAP_HEADER if opts.mode == "timetrial" else PlaytestStats.RESULT_HEADER)
	_csv.flush()


func _write(line: String) -> void:
	if _csv != null:
		_csv.store_line(line)
		_csv.flush() # survive the window being closed mid-session


# --- time trial (#18) -------------------------------------------------------------------------

func _setup_time_trial() -> void:
	monitor = RaceMonitor.new()
	monitor.setup(drive.vehicle, drive.quarry.track, drive.lap_timer) # drive steps the timer
	monitor.set_physics_process(false)
	add_child(monitor)
	drive.lap_timer.lap_completed.connect(_on_tt_lap)


func _on_tt_lap(rec: Dictionary) -> void:
	lap_times.append(float(rec.time))
	_write(PlaytestStats.lap_row(opts.tester, rec, resets))
	print("PLAYTEST LAP %d: %s (raw %s, penalty %.1f s)" % [rec.lap, PlaytestStats.format_time(rec.time),
			PlaytestStats.format_time(rec.raw_time), rec.penalty])
	_flash("Lap %d  %s" % [rec.lap, PlaytestStats.format_time(rec.time)])


# --- race vs AI (#192) ------------------------------------------------------------------------

func _setup_race() -> void:
	drive.set_physics_process(false) # its LapTimer/apply path is replaced by the manager + this node
	drive.time_trial.set_physics_process(false)
	var track := drive.quarry.track
	var count: int = opts.ai + 1
	var slot: int = opts.grid if opts.grid >= 0 else count - 1
	mgr = RaceManager.new()
	mgr.setup(track, opts.laps)
	mgr.process_physics_priority = 20
	add_child(mgr)
	var field := AiPersonality.make_field(PlaytestStats.difficulty_enum(opts.difficulty), opts.ai, opts.seed)
	var ai_i := 0
	for s in count:
		var xf := mgr.grid_transform(s, count)
		xf.origin.y = drive.quarry.terrain.height_at(xf.origin.x, xf.origin.z) + drive.spawn_lift
		if s == slot:
			drive.vehicle.global_transform = xf
			player_id = mgr.add_car(drive.vehicle, "You")
			continue
		var v := _make_ai_vehicle()
		v.global_transform = xf
		var p: AiPersonality = field[ai_i]
		var id := mgr.add_car(v, "AI %d (%s %.2f)" % [ai_i + 1, opts.difficulty.capitalize(), p.skill])
		var ai := AiDriver.new()
		ai.setup_personality(LINE, p, opts.seed + ai_i)
		ai.attach_tactics(mgr, id, opts.seed)
		ai_vehicles.append(v)
		ai_drivers.append(ai)
		ai_states.append(DriverInputState.new())
		ai_ids.append(id)
		ai_i += 1
	monitor = RaceMonitor.new()
	monitor.setup(drive.vehicle, track, mgr.timers[player_id]) # the manager steps this timer
	monitor.set_physics_process(false)
	add_child(monitor)
	mgr.timers[player_id].lap_completed.connect(_on_race_lap)
	mgr.countdown_tick.connect(func(n: int) -> void: _flash(str(n), 1.0))
	mgr.race_started.connect(func() -> void: _flash("GO!", 1.0))
	mgr.penalty_added.connect(_on_penalty)
	mgr.track_limit_warning.connect(func(car: int) -> void:
		if car == player_id:
			_flash("Track limits warning"))
	mgr.race_finished.connect(_on_race_finished)
	mgr.start_countdown()


func _make_ai_vehicle() -> Vehicle:
	var v := Vehicle.new()
	v.surface_map = drive.quarry.terrain.surface_map
	v.add_child(VehicleVisual.new())
	var audio := VehicleAudio.new()
	audio.is_player = false # engine only; tire sound and rumble stay with the player car
	v.add_child(audio)
	v.add_child(VehicleVfx.new())
	drive.add_child(v)
	return v


func _on_race_lap(rec: Dictionary) -> void:
	lap_times.append(float(rec.time))
	_flash("Lap %d  %s  P%d" % [rec.lap, PlaytestStats.format_time(rec.time), mgr.position_of(player_id)])


func _on_penalty(entry: Dictionary) -> void:
	if int(entry.car) == player_id:
		_flash("+%.0f s penalty (%s)" % [entry.seconds, entry.reason], 2.5)


func _on_race_finished(results: Array) -> void:
	for r: Dictionary in results:
		_write(PlaytestStats.result_row(opts.tester, opts.difficulty, r))
		print("PLAYTEST RESULT: P%d %s time %s best %s pen %.1f%s" % [r.rank, r.name,
				PlaytestStats.format_time(r.time), PlaytestStats.format_time(r.best_lap), r.penalties,
				" DNF" if r.dnf else ""])
	var screen := RESULTS_SCENE.instantiate()
	_layer.add_child(screen)
	screen.show_results(results)


# --- per tick ---------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed(RaceMonitor.ACTION_RESET):
		monitor.reset_to_track()
		resets += 1
		_flash("Reset (+%.0f s)" % monitor.reset_penalty)
	if mgr == null:
		return # time trial: QuarryDrive drives the player and steps its timer
	for i in ai_vehicles.size():
		ai_drivers[i].drive(ai_vehicles[i], ai_states[i], delta)
		mgr.gate_input(ai_states[i])
		ai_vehicles[i].apply_input(ai_states[i])
	var st := drive.driver_input.state
	mgr.gate_input(st)
	drive.vehicle.apply_input(st)


func _process(delta: float) -> void:
	_banner_t = maxf(_banner_t - delta, 0.0)
	_hud.text = _hud_text()


func _flash(text: String, seconds := 3.0) -> void:
	_banner = text
	_banner_t = seconds


func _hud_text() -> String:
	var lines: Array[String] = []
	var lt: LapTimer = drive.lap_timer if mgr == null else mgr.timers[player_id]
	if mgr != null:
		lines.append("RACE vs %d AI (%s)   P%d / %d   Lap %d / %d" % [opts.ai, opts.difficulty.capitalize(),
				mgr.position_of(player_id), mgr.car_count(), mini(lt.laps.size() + 1, opts.laps), opts.laps])
		if mgr.state == RaceManager.State.IDLE or mgr.state == RaceManager.State.COUNTDOWN:
			lines.append("Get ready... (handbrake held until GO)")
	else:
		lines.append("TIME TRIAL   tester: %s   laps: %d" % [opts.tester, lap_times.size()])
		if not lt.running:
			lines.append("Drive through the start/finish line to start lap 1")
	if lt.running:
		lines.append("Current  %s" % PlaytestStats.format_time(lt.current_lap_ticks() * lt.tick_dt))
	if not lap_times.is_empty():
		lines.append("Last     %s" % PlaytestStats.format_time(lap_times[-1]))
		lines.append("Best     %s" % PlaytestStats.format_time(lap_times.min()))
	if mgr == null:
		var imp := PlaytestStats.improvement(lap_times)
		if imp.ready:
			lines.append("First-3 mean %s  last-3 mean %s  improvement %+.1f %% (target >= %.0f %%)" % [
					PlaytestStats.format_time(imp.first3), PlaytestStats.format_time(imp.last3), imp.pct,
					PlaytestStats.IMPROVEMENT_TARGET_PCT])
		else:
			lines.append("Improvement shown after 6 laps (%d / 6)" % lap_times.size())
	lines.append("Resets %d   [R / pad Y] reset   [F1] telemetry   [F2] dump telemetry   [Esc] quit" % resets)
	lines.append("Log: %s" % ProjectSettings.globalize_path(csv_path))
	if _banner_t > 0.0:
		lines.append("")
		lines.append(">>> %s <<<" % _banner)
	return "\n".join(lines)


func _make_hud() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 5
	add_child(_layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 16)
	_hud.add_theme_font_size_override("font_size", 20)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 6)
	_layer.add_child(_hud)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().quit()


func _exit_tree() -> void:
	if _csv != null:
		_csv.close()
