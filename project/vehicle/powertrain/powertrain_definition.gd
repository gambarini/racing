## Data for the M1 reference powertrain (#11). Defaults are the baseline recorded in the wiki page
## "Vehicle Physics Design"; tuned later per car. Pure data: no behaviour beyond small lookups.
class_name PowertrainDefinition
extends Resource

enum DiffType { OPEN, LOCKED, LSD }

@export_group("Engine")
## rpm -> Nm at full throttle (x = rpm, y = Nm), ascending rpm. Clamped outside the table.
@export var torque_curve := PackedVector2Array([
	Vector2(1000, 120), Vector2(2000, 200), Vector2(3500, 250),
	Vector2(4500, 260), Vector2(6000, 235), Vector2(7000, 190)])
@export var idle_rpm := 1000.0
@export var limiter_rpm := 7200.0
## The cut starts this far below the limiter so the one-tick overshoot stays under limiter_rpm.
@export var limiter_lead_rpm := 100.0
@export var limiter_hysteresis_rpm := 50.0
@export var engine_inertia := 0.15 ## kg m^2
@export var closed_torque_base := 20.0 ## Nm; closed-throttle torque = -(base + per_rpm * rpm)
@export var closed_torque_per_rpm := 0.006
@export_range(0.0, 1.0) var idle_base_throttle := 0.18 ## throttle that holds idle_rpm
@export var idle_gain := 0.002 ## extra throttle per rpm below idle

@export_group("Gearbox")
@export var gear_ratios := PackedFloat64Array([3.60, 2.20, 1.55, 1.20, 1.00, 0.82])
@export var reverse_ratio := 3.50
@export var final_drive := 4.10
@export var shift_time := 0.25 ## s of torque cut per shift
@export var min_shift_interval := 0.5 ## s between shift starts
@export var upshift_rpm_closed := 3500.0 ## at throttle 0
@export var upshift_rpm_open := 6500.0 ## at throttle 1
@export var downshift_rpm_closed := 1800.0
@export var downshift_rpm_open := 3000.0

@export_group("Clutch")
@export var clutch_capacity := 450.0 ## Nm at full engagement
## Auto-clutch engagement ramps linearly from 0 to 1 between these rpm.
@export var clutch_start_rpm := 2000.0
@export var clutch_full_rpm := 4500.0
## Driveline inertia (kg m^2 at the axle) the slipping clutch is tuned against; bounds its gain.
@export var clutch_driveline_inertia := 15.0
@export_range(0.0, 1.0) var clutch_slip_inertia_share := 1.0 ## engine inertia kept on the wheels while slipping
@export var clutch_lock_engagement := 0.9 ## engagement needed before the clutch may lock
@export var clutch_lock_window_rpm := 400.0 ## slip must be below this to lock

@export_group("Driveline")
@export var driven_wheels := PackedInt32Array([2, 3]) ## wheel indices; the pair feeds the diff (L, R)
@export var diff_type := DiffType.OPEN
@export var diff_lock_stiffness := 60.0 ## Nm per rad/s of wheel speed difference (LOCKED, LSD)
@export var diff_lock_max := 2000.0 ## Nm, cap on the LOCKED coupling torque
@export var lsd_preload := 100.0 ## Nm
@export var lsd_power_ratio := 0.4 ## extra lock torque per Nm of drive input
@export var lsd_coast_ratio := 0.2 ## same, while braking with the engine


func gear_count() -> int:
	return gear_ratios.size()


## Overall ratio engine -> axle for a gear (1..n forward, -1 reverse, 0 neutral).
func total_ratio(gear: int) -> float:
	if gear == 0:
		return 0.0
	if gear < 0:
		return -reverse_ratio * final_drive
	return gear_ratios[clampi(gear, 1, gear_ratios.size()) - 1] * final_drive
