## Static lookup of surface definitions by id (#12). Unknown ids fall back to tarmac and warn
## once per id (not per tick).
class_name SurfaceRegistry
extends RefCounted

const DEFAULT_ID := &"tarmac"
const _PATHS := {
	&"tarmac": "res://surfaces/tarmac.tres",
	&"gravel": "res://surfaces/gravel.tres",
	&"mud": "res://surfaces/mud.tres",
}

static var _defs: Dictionary = {}
static var _warned: Dictionary = {}


static func get_surface(id: StringName) -> SurfaceDefinition:
	if _defs.is_empty():
		for k in _PATHS:
			_defs[k] = load(_PATHS[k])
	if _defs.has(id):
		return _defs[id]
	if not _warned.has(id):
		_warned[id] = true
		push_warning("SurfaceRegistry: unknown surface id '%s', using tarmac" % id)
	return _defs[DEFAULT_ID]


static func ids() -> Array:
	return _PATHS.keys()
