## Surface definition (#12, wiki "Surfaces"): multipliers relative to dry tarmac, applied to
## whatever reference tire the car has (see TireParams.for_surface). Data only, no logic.
class_name SurfaceDefinition
extends Resource

@export var id: StringName = &"tarmac"
@export var peak_mu_scale := 1.0 ## mu_peak multiplier
@export var slide_mu_scale := 1.0 ## mu_slide multiplier
@export var peak_slip_scale := 1.0 ## kappa_peak and alpha_peak multiplier
@export var rolling_resistance := 0.012 ## Crr, F = Crr * Fz (N)
@export var deformation_drag := 0.0 ## k, F = k * Fz * v^2 (v in m/s)
@export var particle_effect: SurfaceParticleEffect ## #20, non-null for every v1 surface
@export var tyre_mark: TyreMarkStyle ## #20, non-null for every v1 surface


## True when applying this surface leaves a tire unchanged.
func is_neutral() -> bool:
	return peak_mu_scale == 1.0 and slide_mu_scale == 1.0 and peak_slip_scale == 1.0


## Magnitude of the passive resistance force at normal load `fz` and contact speed `speed`.
func resistance_force(fz: float, speed: float) -> float:
	if fz <= 0.0:
		return 0.0
	return fz * (rolling_resistance + deformation_drag * speed * speed)
