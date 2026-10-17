class_name ResultsScreen
extends Control
## Race results table (issue #150): rank, name, time, best lap, penalties for every car, fed by
## RaceManager.race_finished. Rows are built once per `show_results()` call (an event, not a
## per-tick path). Placeholder styling: plain labels, no art.

const COLUMNS := ["Pos", "Driver", "Time", "Best lap", "Penalties"]

@onready var grid: GridContainer = $Panel/Margin/VBox/Grid


## Number of data rows (header excluded).
func row_count() -> int:
	return maxi(grid.get_child_count() / COLUMNS.size() - 1, 0)


## Text of cell (row, col) of the data rows (row 0 = first place).
func cell_text(row: int, col: int) -> String:
	return (grid.get_child((row + 1) * COLUMNS.size() + col) as Label).text


static func format_time(seconds: float) -> String:
	if seconds < 0.0:
		return "--"
	var m := int(seconds) / 60
	return "%d:%06.3f" % [m, seconds - m * 60]


func show_results(results: Array) -> void:
	for c in grid.get_children():
		grid.remove_child(c)
		c.queue_free()
	grid.columns = COLUMNS.size()
	for h in COLUMNS:
		_cell(h, true)
	for r in results:
		var dnf: bool = r["dnf"]
		_cell("DNF" if dnf else str(r["rank"]))
		var nm: String = r.get("name", "Car %d" % (int(r["car"]) + 1))
		_cell(nm + ("" if bool(r.get("joker_taken", true)) or dnf else "  (no joker)"))
		_cell(format_time(float(r["time"])))
		_cell(format_time(float(r.get("best_lap", -1.0))))
		var pen := float(r["penalties"])
		var txt := "--" if pen <= 0.0 else "+%.1f s" % pen
		var reasons: Array = []
		for e in r.get("penalty_list", []):
			reasons.append(String(e["reason"]))
		if not reasons.is_empty():
			txt += " (" + ", ".join(reasons) + ")"
		_cell(txt)


func _cell(text: String, header := false) -> void:
	var l := Label.new()
	l.text = text
	if header:
		l.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(l)
