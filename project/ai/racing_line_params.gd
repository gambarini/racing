## Car and driver limits used by the racing-line speed solver (#27). Defaults describe the M1
## reference car (wiki "Vehicle Physics Design") driven at a moderate skill; #30 personalities
## override `skill_scale`. Data only.
class_name RacingLineParams
extends Resource

@export var gravity := 9.81 ## m/s^2
@export var tire_mu := 1.1 ## peak mu of the reference tire on dry tarmac (surface mu scale multiplies it)
@export_range(0.1, 1.5) var skill_scale := 0.66 ## fraction of the grip-limited corner speed the driver uses
@export var v_max := 55.0 ## m/s, car top speed on tarmac (driver cap)
@export var v_min := 8.0 ## m/s, floor for any sample
@export var accel_max := 6.5 ## m/s^2, traction-unlimited launch acceleration of the car
@export var power := 110000.0 ## W at the wheels; a <= power / (mass * v)
@export var mass := 1200.0 ## kg
@export_range(0.1, 1.0) var accel_grip_frac := 0.8 ## longitudinal grip budget: fraction of mu * g usable for driving
@export_range(0.1, 1.0) var brake_grip_frac := 0.8 ## braking budget: fraction of mu * g (brake torque exceeds grip, so grip rules)


## Peak friction coefficient on a surface with peak-mu scale `mu_scale`.
func mu(mu_scale: float) -> float:
	return tire_mu * mu_scale


## Braking deceleration limit (m/s^2) on a surface.
func brake_limit(mu_scale: float) -> float:
	return brake_grip_frac * mu(mu_scale) * gravity


## Forward acceleration limit (m/s^2) at speed v on a surface.
func accel_limit(v: float, mu_scale: float) -> float:
	return minf(minf(accel_max, power / (mass * maxf(v, 1.0))), accel_grip_frac * mu(mu_scale) * gravity)
