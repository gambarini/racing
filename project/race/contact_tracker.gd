class_name ContactTracker
extends RefCounted
## Car-car contact log and contact penalty heuristic (issue #175). Pure logic: RaceManager reports
## contacts and calls `step()` once per physics tick with its own arrays. Per-tick work touches
## only preallocated buffers; contacts and verdicts (events) may allocate.
## A contact is penalised when the attacker hit the victim from behind or the side with enough
## impulse, the victim lost enough time vs its pre-contact pace over the next `window` seconds,
## and the attacker gained at least one position in that time.

enum Zone { REAR, SIDE, FRONT }
const ZONE_NAMES: Array[String] = ["rear", "side", "front"]
const CSV_HEADER := "time_s,attacker,victim,impulse_ns,rel_speed_ms,zone"

var params: ContactParams
var tick_dt := 1.0 / 120.0

# The log (columns, one row per contact).
var time_s := PackedFloat64Array()
var attacker := PackedInt32Array()
var victim := PackedInt32Array()
var impulse := PackedFloat64Array()
var rel_speed := PackedFloat32Array()
var zone := PackedByteArray()
var penalised := PackedByteArray()  ## 1 when this contact earned a penalty

# Pending verdicts (parallel arrays, entries removed when judged).
var _p_log: Array[int] = []
var _p_due: Array[int] = []
var _p_rank: Array[int] = []
var _p_s: Array[float] = []
var _p_pace: Array[float] = []

var _hist := PackedFloat32Array()  ## per-car ring of the last pace_ticks speeds
var _hist_sum := PackedFloat64Array()
var _hist_n := 0
var _hist_i := 0
var _last_pen := PackedFloat64Array()  ## [attacker * cars + victim] time of last penalty
var _last_idx := PackedInt32Array()  ## [attacker * cars + victim] latest log row, -1 = none
var _last_end := PackedFloat64Array()  ## per log row: time of the latest frame merged into it
var _cars := 0


func _init(p_params: ContactParams, p_cars: int, p_tick_dt := 1.0 / 120.0) -> void:
	params = p_params
	tick_dt = p_tick_dt
	_cars = p_cars
	_hist_n = maxi(int(round(params.pace_window / tick_dt)), 1)
	_hist.resize(_cars * _hist_n)
	_hist_sum.resize(_cars)
	_last_pen.resize(_cars * _cars)
	_last_pen.fill(-1.0e9)
	_last_idx.resize(_cars * _cars)
	_last_idx.fill(-1)


## Hit zone on the victim from the contact normal (world, pointing attacker -> victim) and the
## victim's forward direction: an attacker pushing along the victim's heading hits its rear.
static func zone_of(normal: Vector3, victim_forward: Vector3, zone_cos: float) -> int:
	var d := normal.normalized().dot(victim_forward.normalized())
	if d >= zone_cos:
		return Zone.REAR
	if d <= -zone_cos:
		return Zone.FRONT
	return Zone.SIDE


## Contact impulse estimate for two bodies: reduced mass times the lost closing speed (m/s).
static func estimate_impulse(mass_a: float, mass_b: float, closing_before: float, closing_after: float) -> float:
	return mass_a * mass_b / (mass_a + mass_b) * maxf(closing_before - closing_after, 0.0)


## Per-tick bookkeeping: speed history and judging of due contacts. `total_s` is the distance
## raced per car, `rank_of` the live 1-based position. `penalise` is called (car, seconds).
func step(tick: int, speeds: PackedFloat32Array, total_s: PackedFloat64Array, rank_of: PackedInt32Array, penalise: Callable) -> void:
	for i in speeds.size():
		var k := i * _hist_n + _hist_i
		_hist_sum[i] += speeds[i] - _hist[k]
		_hist[k] = speeds[i]
	_hist_i = (_hist_i + 1) % _hist_n
	var n := _p_due.size()
	if n == 0:
		return
	var j := 0
	while j < n:
		if tick >= _p_due[j]:
			_judge(j, total_s, rank_of, penalise)
			n -= 1
			_p_log[j] = _p_log[n]
			_p_due[j] = _p_due[n]
			_p_rank[j] = _p_rank[n]
			_p_s[j] = _p_s[n]
			_p_pace[j] = _p_pace[n]
		else:
			j += 1
	_p_log.resize(n)
	_p_due.resize(n)
	_p_rank.resize(n)
	_p_s.resize(n)
	_p_pace.resize(n)


## Logs a contact, or merges it into the previous one of the pair when it follows within
## `merge_gap` (multi-frame contact), and queues it for judging `window` seconds later.
func report(tick: int, race_time: float, att: int, vic: int, imp: float, speed: float, z: int,
		total_s: PackedFloat64Array, rank_of: PackedInt32Array) -> void:
	var key := att * _cars + vic
	var li := _last_idx[key]
	if li >= 0 and race_time - _last_end[li] <= params.merge_gap:
		impulse[li] += imp
		rel_speed[li] = maxf(rel_speed[li], speed)
		_last_end[li] = race_time
		return
	time_s.append(race_time)
	attacker.append(att)
	victim.append(vic)
	impulse.append(imp)
	rel_speed.append(speed)
	zone.append(z)
	penalised.append(0)
	_last_end.append(race_time)
	li = time_s.size() - 1
	_last_idx[key] = li
	if z == Zone.FRONT:
		return
	_p_log.append(li)
	_p_due.append(tick + int(round(params.window / tick_dt)))
	_p_rank.append(rank_of[att])
	_p_s.append(total_s[vic])
	_p_pace.append(_hist_sum[vic] / _hist_n)


func _judge(p: int, total_s: PackedFloat64Array, rank_of: PackedInt32Array, penalise: Callable) -> void:
	var li := _p_log[p]
	var att := attacker[li]
	var vic := victim[li]
	if impulse[li] < params.min_impulse:
		return
	var pace := _p_pace[p]
	if pace < params.min_pace:
		return
	var loss := params.window - (total_s[vic] - _p_s[p]) / pace
	if loss < params.min_time_loss:
		return
	if _p_rank[p] - rank_of[att] < params.min_positions_gained:
		return
	var t := time_s[li]
	if t - _last_pen[att * _cars + vic] < params.cooldown:
		return
	_last_pen[att * _cars + vic] = t
	penalised[li] = 1
	penalise.call(att, params.penalty_seconds)


func count() -> int:
	return time_s.size()


func penalty_count() -> int:
	var n := 0
	for p in penalised:
		n += p
	return n


func to_csv() -> String:
	var out := CSV_HEADER + "\n"
	for i in time_s.size():
		out += "%.3f,%d,%d,%.1f,%.2f,%s\n" % [time_s[i], attacker[i], victim[i], impulse[i], rel_speed[i], ZONE_NAMES[zone[i]]]
	return out


func save_csv(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(to_csv())
	return OK
