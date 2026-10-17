## Tire model parameters (data-driven; reference values from wiki "Vehicle Physics Design").
## Surface variants are derived with for_surface() from this reference (dry tarmac) set.
class_name TireParams
extends Resource

@export var mu_peak := 1.1 ## peak friction coefficient at nominal load
@export var mu_slide := 0.9 ## friction coefficient when fully sliding
@export var kappa_peak := 0.10 ## slip ratio of peak force
@export var alpha_peak := 0.14 ## slip angle of peak force, rad (8 deg)
## Sharpness of the post-peak drop: g = r + (1 - r) / (1 + falloff*(x-1)^2), r = mu_slide/mu_peak.
@export var falloff := 0.1
@export var nominal_load := 3000.0 ## N, load at which mu_peak/mu_slide apply
## Fractional loss of mu per extra nominal_load of Fz (0.05 -> -5 % mu at 2x load).
@export var load_sensitivity := 0.075
@export var relaxation_length := 0.3 ## m, slip lags the target over this rolled distance
@export var low_speed_floor := 0.5 ## m/s, slip-defining speed never drops below this
@export var min_relax_rate := 2000.0 ## 1/s, floor on the slip lag rate: at near-zero speed slip tracks its target instantly (no lag-induced ringing)


## Pure: the tire as it behaves on `surface` (multipliers relative to this reference tire).
## A null or neutral surface returns `base` itself, so tarmac output is bit-identical.
static func for_surface(base: TireParams, surface: SurfaceDefinition) -> TireParams:
	if surface == null or surface.is_neutral():
		return base
	var p: TireParams = base.duplicate()
	p.mu_peak = base.mu_peak * surface.peak_mu_scale
	p.mu_slide = base.mu_slide * surface.slide_mu_scale
	p.kappa_peak = base.kappa_peak * surface.peak_slip_scale
	p.alpha_peak = base.alpha_peak * surface.peak_slip_scale
	return p


## Allocation-free for_surface: writes into caller-owned `out` (same fields as base.duplicate()).
static func for_surface_into(base: TireParams, surface: SurfaceDefinition, out: TireParams) -> TireParams:
	if surface == null or surface.is_neutral():
		return base
	out.mu_peak = base.mu_peak * surface.peak_mu_scale
	out.mu_slide = base.mu_slide * surface.slide_mu_scale
	out.kappa_peak = base.kappa_peak * surface.peak_slip_scale
	out.alpha_peak = base.alpha_peak * surface.peak_slip_scale
	out.falloff = base.falloff
	out.nominal_load = base.nominal_load
	out.load_sensitivity = base.load_sensitivity
	out.relaxation_length = base.relaxation_length
	out.low_speed_floor = base.low_speed_floor
	out.min_relax_rate = base.min_relax_rate
	return out
