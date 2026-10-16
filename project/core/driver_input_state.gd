## Plain driver-input snapshot produced each physics tick (read by the vehicle).
class_name DriverInputState
extends RefCounted

var steer := 0.0  # [-1, 1], positive = right
var throttle := 0.0  # [0, 1]
var brake := 0.0  # [0, 1]
var handbrake := false
