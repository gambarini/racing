## Shared pass/fail printing for the scenario *_check.gd scripts (#81).
extends RefCounted

var failures := 0


## Prints measured value and allowed range; on failure also the CSV to plot.
func check_range(name: String, value: float, lo: float, hi: float, csv := "") -> void:
	var line := "%s: measured %.4f, allowed %.4f..%.4f" % [name, value, lo, hi]
	if value >= lo and value <= hi:
		print("PASS: ", line)
	else:
		failures += 1
		printerr("FAIL: ", line, ("   csv: " + ProjectSettings.globalize_path(csv)) if csv != "" else "")


func check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		failures += 1
		printerr("FAIL: ", msg)


func finish(tree: SceneTree) -> void:
	print("RESULT: ", "OK" if failures == 0 else "FAILED (%d)" % failures)
	tree.quit(1 if failures > 0 else 0)
