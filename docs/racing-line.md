# Racing line (#27)

Consumed by the AI driver (#28). Source: `project/ai/racing_line.gd` (data + queries), `racing_line_solver.gd` (pure speed solver), `racing_line_params.gd` (car/driver limits), `racing_line_debug.gd` (F3 colour map).

## Data (`RacingLine`, Resource, no scene needed)

Closed loop, driving direction, parallel arrays indexed `0 .. count()-1` (sample `count()-1` joins sample 0):

| field | meaning |
|---|---|
| `s[i]` | arc length from sample 0 (m), `s[0] = 0` |
| `pos[i]` | world position (x, road y, z) |
| `lane_offset[i]` | lateral offset (m, + = right of travel) from the route's own centre line (0 on the joker detour centre line) |
| `target_speed[i]` | solved speed (m/s), within `[params.v_min, params.v_max]` |
| `curvature[i]` | signed 1/m, + = turning right |
| `surface_mu[i]` | peak-mu scale under the sample (tarmac 1.0), for lane-offset and recovery logic |
| `length` | loop length (m); every query wraps `s` into `[0, length)` |

Queries (all allocation-free): `point_at(s)`, `tangent_at(s)`, `target_speed_at(s)`, `curvature_at(s)`, `lane_offset_at(s)`, `surface_mu_at(s)`, `nearest_s(pos, hint := -1, window := 40)`, `predicted_lap_time()`.
Per tick call `nearest_s(pos, last_s, 40.0)`: only samples within `window` m of the hint are scanned; without a hint the whole loop is.

## Variants

`variant = RacingLine.Variant.MAIN | JOKER`. The resource holds the main lap; `joker` is a complete second lap with the detour in place of main `s` in `joker_span_main` (~711..986 m). `s` is variant-local: after the detour `s_joker = s_main + joker_length_delta()`. `joker_span_joker` is the detour in joker `s`. Switch variant at the entry decision, then keep using the new `s` (re-derive with `nearest_s` after a switch). Main and joker line meet within 0.01 m at both ends.

## Solver

`v = clamp(min(v_max, sqrt(mu_tire * mu_surface * g / |kappa|) * skill_scale), v_min, v_max)`, then a backward pass (decel <= `brake_grip_frac * mu * g`) and a forward pass (accel <= min(`accel_max`, `power / (m v)`, `accel_grip_frac * mu * g`)), two laps each. `skill_scale` (default 0.66) is the knob for #30 personalities: re-solve with `RacingLine.build(...)` or scale `target_speed_at(s)` at runtime.

## Regenerating the Quarry data

`godot --headless --path project -s res://ai/author_quarry_line.gd` rewrites `res://tracks/quarry/quarry_racing_line.tres` (minimum-curvature line inside the road, 1.25 m margin, grip from the surface map). Check with `tests/racing_line_check.gd`.
Top-down colour maps: `docs/quarry_racing_line.png`, `docs/quarry_racing_line_joker.png` (`ai/capture_racing_line_shot.gd`, needs a display).
