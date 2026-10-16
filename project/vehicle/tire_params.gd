## Tire model parameters (data-driven; reference values from wiki "Vehicle Physics Design").
## Surface-specific sets arrive in M2; this is the single dry-asphalt set for M1.
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
@export var load_sensitivity := 0.05
@export var relaxation_length := 0.3 ## m, slip lags the target over this rolled distance
@export var low_speed_floor := 0.5 ## m/s, slip-defining speed never drops below this
@export var min_relax_rate := 2000.0 ## 1/s, floor on the slip lag rate: at near-zero speed slip tracks its target instantly (no lag-induced ringing)
