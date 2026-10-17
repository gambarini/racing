extends GutTest
## ResultsScreen with fake data (#150): row count and label order.

const SCENE := "res://ui/results_screen.tscn"


static func fake() -> Array:
	var out: Array = []
	for i in 8:
		out.append({"rank": i + 1, "car": i, "name": "Car %d" % i, "time": 100.0 + i, "race_time": 100.0 + i,
				"best_lap": 24.5 + i * 0.1, "penalties": 0.0, "penalty_list": [], "joker_taken": true, "dnf": false})
	out[3]["penalties"] = 10.0
	out[3]["joker_taken"] = false
	out[3]["penalty_list"] = [{"car": 3, "seconds": 10.0, "reason": &"joker_missed", "tick": 5}]
	out[7] = {"rank": 8, "car": 7, "name": "Car 7", "time": -1.0, "race_time": -1.0, "best_lap": -1.0,
			"penalties": 0.0, "penalty_list": [], "joker_taken": false, "dnf": true}
	return out


func test_rows_and_order() -> void:
	var s: ResultsScreen = (load(SCENE) as PackedScene).instantiate()
	add_child_autofree(s)
	s.show_results(fake())
	assert_eq(s.row_count(), 8)
	for i in 8:
		assert_true(s.cell_text(i, 1).begins_with("Car %d" % i), "name order row %d" % i)
	assert_eq(s.cell_text(0, 0), "1")
	assert_eq(s.cell_text(7, 0), "DNF")
	assert_eq(s.cell_text(7, 2), "--")
	assert_true(s.cell_text(3, 4).contains("+10.0 s") and s.cell_text(3, 4).contains("joker_missed"))
	assert_eq(s.cell_text(0, 2), "1:40.000")
	s.show_results(fake().slice(0, 3))
	assert_eq(s.row_count(), 3, "rebuild replaces rows")
