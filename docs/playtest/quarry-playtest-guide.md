# Quarry playtest guide (#18 driving feel, #192 AI difficulty)

The playtest scene is `res://debug/playtest/quarry_playtest.tscn`. It wraps the Quarry drive scene and adds:
- A lap HUD.
- A per-lap CSV log.
- Reset-to-track.
- In race mode, an AI field of the chosen difficulty.

It's debug tooling, not the game HUD (that's #39).

## Launch

Run these from the repo root. They open a window, so don't add `--headless`.

Time trial (#18). Use one run per tester and put the tester's name in it:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --path project res://debug/playtest/quarry_playtest.tscn -- --tester=ana
```

Race against the AI (#192). Run it once per difficulty:
```bash
/Applications/Godot.app/Contents/MacOS/Godot --path project res://debug/playtest/quarry_playtest.tscn -- --mode=race --difficulty=easy
```
```bash
/Applications/Godot.app/Contents/MacOS/Godot --path project res://debug/playtest/quarry_playtest.tscn -- --mode=race --difficulty=medium
```
```bash
/Applications/Godot.app/Contents/MacOS/Godot --path project res://debug/playtest/quarry_playtest.tscn -- --mode=race --difficulty=hard
```

| Option | Values | Default |
|---|---|---|
| `--mode` | `timetrial`, `race` | `timetrial` |
| `--difficulty` | `easy`, `medium`, `hard` | `medium` |
| `--ai` | number of AI cars, 1–11 | 5 |
| `--laps` | race laps | 4 |
| `--grid` | your grid slot, 0 = pole | back of the grid |
| `--seed` | AI personality seed | 2026 |
| `--tester` | name used in the log file name | `tester` |

The logs are CSV files in `~/Library/Application Support/Godot/app_userdata/Racing/playtest/`. The exact path is printed in the terminal and shown on the HUD.
- **Time trial:** one row per lap, with the lap time, raw time, penalty, sector times and resets so far.
- **Race:** one row per car at the finish.

## Controls

| Action | Keyboard | Gamepad |
|---|---|---|
| Steer | A / D or ← / → | left stick |
| Throttle | W or ↑ | RT |
| Brake | S or ↓ | LT |
| Handbrake | Space | A (south button) |
| Reset to track (+5 s) | R | Y (north button) |
| Telemetry overlay | F1 | |
| Dump telemetry CSV | F2 | |
| Racing line / AI debug | F3 / F4 | |
| Quit | Esc | |

Rumble and tyre audio come only from the player car. Rumble needs a gamepad connected (device 0).

## #18: does driving feel good? (5+ testers)

The targets come from [Vision and Pillars](https://github.com/gambarini/racing/wiki/Vision-and-Pillars) and the [Physics Tuning and Telemetry](https://github.com/gambarini/racing/wiki/Physics-Tuning-and-Telemetry) playtest checklist.

1. **10-lap improvement.** Give each tester 10 timed laps of the time trial, with no coaching.
   - Target: the mean of the last 3 laps is at least 2 % faster than the mean of the first 3.
   - The HUD shows first-3, last-3 and the improvement % once 6 laps are done.
   - A lap with a reset carries the 5 s penalty. Note those laps; the raw time is also in the CSV.
2. **Blind surface identification (eyes closed).** The Quarry has four drivable surfaces: tarmac, dirt, gravel and mud. Grass is the verge.
   - A helper drives with the keyboard while the tester holds the gamepad (rumble works with any input source) and listens with headphones.
   - The tester keeps their eyes closed and calls out the surface whenever it changes, and the helper records whether each call was right.
   - Target: at least 3 of 4 surfaces identified correctly.
3. **Checklist items** (deferred to this playtest by the wiki):
   - **Handbrake hairpin.** Does it rotate the car predictably? Known issue #112: the handbrake turn barely differs between gravel and tarmac, so note whether testers notice.
   - **Jump landing stability** over the Quarry crests.
   - **Lift-off oversteer.** Lifting mid-corner should tighten the line without spinning.
   - **Car-to-car contact sanity.** Use race mode for this one.
4. **Quotes.** Write down one or two verbatim quotes per tester about the feel.

## #192: do the AI difficulty presets feel right?

Race 4 laps at each difficulty, starting from the back.
- **Easy:** it should feel beatable.
- **Hard:** a real fight, without obviously unfair pace.

Headless reference flying-lap means: Easy 80.35 s, Medium 69.02 s, Hard 64.38 s. Standing-start lap 1 is slower.

Record for each difficulty:
- Finishing position.
- Your best lap compared with the AI best laps.
- Whether passing felt possible.
- Any unfair moments: impossible pace, dive-bombs, contact penalties that seemed wrong.

## Findings template (wiki page, e.g. `Playtest-M1-Quarry`)

```
### Tester <name> (<pad/keyboard>, <experience>)
- Laps (s): <l1 … l10>   first-3 <x>  last-3 <y>  improvement <z %>  (pass/fail)
- Blind surfaces: tarmac <✓/✗> dirt <✓/✗> gravel <✓/✗> mud <✓/✗>  -> <n>/4
- Handbrake hairpin: …   Jump landing: …   Lift-off oversteer: …   Contact: …
- Quotes: "…"
- CSV: <file name>

### AI presets (#192)
| Difficulty | Finish | My best lap | AI best laps | Beatable / fight / unfair? | Notes |
|---|---|---|---|---|---|
| Easy | | | | | |
| Medium | | | | | |
| Hard | | | | | |
```

When 5+ testers are done, record the counts on the wiki, update the Roadmap, then close #18. #192 can close on one person's verdict.
