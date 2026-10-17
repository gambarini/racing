## Surface id -> SurfaceAudioProfile (#21). One profile per v1 surface id.
class_name SurfaceAudioRegistry
extends RefCounted

static var _profiles: Dictionary = {}


static func get_profile(id: StringName) -> SurfaceAudioProfile:
	if _profiles.is_empty():
		for k in SurfaceRegistry.ids():
			_profiles[k] = load("res://audio/profiles/%s.tres" % k)
	return _profiles.get(id, _profiles[SurfaceRegistry.DEFAULT_ID])


## Drop the cache (tests, so no resource is held at exit).
static func clear() -> void:
	_profiles.clear()
