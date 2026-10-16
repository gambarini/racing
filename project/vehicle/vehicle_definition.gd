## Data-driven car description (Tech Architecture: /vehicle/definitions). Defaults are the
## M1 reference car from wiki "Vehicle Physics Design"; they are starting values, tuned in #15.
## Frame: body origin is on the ground at design ride height, mid-wheelbase; forward is -Z.
class_name VehicleDefinition
extends Resource

@export_group("Mass")
@export var mass := 1200.0 ## kg
@export var wheelbase := 2.5 ## m
@export var track := 1.5 ## m
@export var com_height := 0.45 ## m above ground at rest
@export_range(0.0, 1.0) var com_from_front := 0.525 ## fraction of wheelbase from front axle
## Explicit principal inertia tensor (pitch X, yaw Y, roll Z), kg m^2. Never auto-computed.
@export var inertia := Vector3(1900.0, 2100.0, 500.0)

@export_group("Wheel")
@export var wheel_radius := 0.32 ## m
@export var wheel_inertia := 1.2 ## kg m^2 per wheel (rim, tire, brake disc)
@export var handbrake_torque := 3000.0 ## Nm on each rear wheel while the handbrake is applied

@export_group("Suspension")
@export var spring_rate := 30000.0 ## N/m per wheel
@export var travel := 0.20 ## m, full droop to full bump
@export var damper_bump := 2000.0 ## Ns/m (compressing)
@export var damper_rebound := 3000.0 ## Ns/m (extending)
@export var bump_stop_zone := 0.02 ## m of travel before full bump where the stop engages
@export var bump_stop_rate := 400000.0 ## N/m extra stiffness inside the zone
@export var arb_front := 10000.0 ## N/m of left-right compression difference
@export var arb_rear := 8000.0

@export_group("Chassis collider")
@export var chassis_size := Vector3(1.7, 0.5, 3.4) ## m
## Underside height above ground at design ride height; it doubles as the hard bump stop
## (about travel minus static compression), so the hub can never enter the chassis.
@export var chassis_bottom := 0.10

@export_group("Stub: static hold (replaced by brakes/tire in #9/#10)")
@export var hold_friction_mu := 1.0
@export var hold_stiffness := 20000.0 ## N/m anchor spring per wheel
@export var hold_damping := 2000.0 ## Ns/m per wheel


func front_axle_z() -> float:
	return -wheelbase * 0.5


func rear_axle_z() -> float:
	return wheelbase * 0.5


## CoM in body frame (origin mid-wheelbase on the ground).
func com_position() -> Vector3:
	return Vector3(0.0, com_height, front_axle_z() + com_from_front * wheelbase)


## Share of the weight carried by the front axle: 1 - d_front / wheelbase.
func front_weight_share() -> float:
	return 1.0 - com_from_front


## Static load per wheel (N) for the given axle.
func static_wheel_load(front: bool, g: float) -> float:
	var share := front_weight_share() if front else 1.0 - front_weight_share()
	return mass * g * share * 0.5


## Mount height (m above ground at design ride) so the body sits level with c = F/k.
func mount_height(front: bool, g: float) -> float:
	return wheel_radius + travel - static_wheel_load(front, g) / spring_rate


## Wheel mount in body frame. index: 0 FL, 1 FR, 2 RL, 3 RR.
func mount_position(index: int, g: float) -> Vector3:
	var front := index < 2
	var x := (-1.0 if index % 2 == 0 else 1.0) * track * 0.5
	return Vector3(x, mount_height(front, g), front_axle_z() if front else rear_axle_z())
