## Pure static-friction stage (#85): a parked, braked tire is anchored to the ground point where
## it came to rest and held by a critically damped spring, clamped to the friction limit. Slip-based
## friction has no static stage (force ~ 0 at zero slip), so without this a parked car creeps.
## No node access, no state: same inputs -> same outputs.
class_name StaticFriction
extends RefCounted

const ENGAGE_SPEED := 0.05 ## m/s: below this a locked, braked wheel latches its anchor
const RELEASE_SPEED := 0.3 ## m/s: above this the anchor is dropped
const OMEGA0 := 30.0 ## rad/s: natural frequency of the anchor spring (critically damped)
const SATURATION := 0.98 ## fraction of the friction limit at which the anchor lets go


## Force (N, in the tangent plane) on the tire for anchor displacement `disp` (m, contact minus
## anchor) and contact velocity `vel` (m/s). `mass` is the share of the car the tire holds.
## Returns the spring-damper force clamped to the circle `f_max`; the clamp is what makes this
## a friction stage rather than a rigid joint.
static func hold_force(disp: Vector2, vel: Vector2, mass: float, f_max: float) -> Vector2:
	var f := -(disp * (mass * OMEGA0 * OMEGA0) + vel * (2.0 * mass * OMEGA0))
	var len := f.length()
	if len > f_max and len > 0.0:
		f *= f_max / len
	return f


## True when the demanded hold force has used up the friction budget (the tire must slide).
static func saturated(force: Vector2, f_max: float) -> bool:
	return force.length() >= f_max * SATURATION
