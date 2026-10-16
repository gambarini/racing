# Contributing

Design lives in the [Wiki](https://github.com/gambarini/racing/wiki); this file is the code-and-workflow contract. When in doubt, [Vision and Pillars](https://github.com/gambarini/racing/wiki/Vision-and-Pillars) wins, in pillar order (physics first).

Setup: Godot 4.6 (exact build pinned in `project/project.godot` and README), Git LFS (`brew install git-lfs && git lfs install` **before your first commit**).

## 1. Folder layout and ownership

| Path | Purpose | Owner / area label |
|---|---|---|
| `project/core` | autoloads: game state, settings, input, save | `area:core` (developer) |
| `project/vehicle` | wheel, tire, suspension, powertrain, assists | `area:vehicle` (developer) |
| `project/vehicle/definitions` | `VehicleDefinition` resources, one per car | developer / designer (numbers) |
| `project/surfaces` | `SurfaceDefinition` resources + VFX/SFX | developer |
| `project/ai` | racing line, driver controller, personalities | developer |
| `project/race` | race manager, rules, penalties, timing, grid | developer |
| `project/tracks` | one folder per venue (scenes, splines, surface maps) | level designer |
| `project/camera` | camera rigs | developer |
| `project/audio` | audio systems, buses, sounds | audio designer |
| `project/ui` | HUD and menus | developer |
| `project/debug` | telemetry overlay, recorders | developer |
| `project/tests` | GUT tests | everyone |
| `art-source/` | Blender `.blend` sources (LFS), outside the Godot project | technical artist |
| `tools/` | offline scripts (telemetry analysis, line solver) | developer |
| `docs/` | short in-repo docs; design belongs in the Wiki | designer |

Do not add top-level folders under `project/` without updating [Tech Architecture](https://github.com/gambarini/racing/wiki/Tech-Architecture) in the same PR.

## 2. GDScript conventions

- Follow the official GDScript style guide, plus the rules below.
- **Files:** `snake_case.gd`; one `class_name` per file in `PascalCase`, matching the file (`tire_model.gd` -> `TireModel`). Scenes `snake_case.tscn`, resources `snake_case.tres`.
- **Names:** functions/variables `snake_case`; constants and enum members `UPPER_SNAKE_CASE`; enum types and signals: type `PascalCase`, signal `past_tense_snake_case` (`lap_completed`); private members prefixed `_`.
- **Static typing is mandatory** for function parameters, return types, member variables and constants (`var slip_ratio: float`, `func compute(slip: float) -> Vector2:`). Use `:=` only when the type is obvious from the right-hand side.
- **Units:** SI (m, s, kg, N, rad) inside the sim; convert (km/h, degrees) only in UI. Put the unit in the name when ambiguous (`mass_kg`, `max_steer_rad`).
- **No magic numbers.** Tunables (grip, spring rates, gear ratios, AI skill) live in `Resource` definitions or `@export` vars with sensible ranges, never inline literals in logic.
- **Data-driven:** no car-specific or track-specific `if`s in code; behaviour differences come from Resources.
- Prefer composition and signals over deep inheritance; avoid `get_node("../..")` paths, use `@export var x: Node` or `@onready` with unique names.
- Keep functions short (aim < 40 lines); comment the *why* and cite the physics source/assumption, not the *what*.

### Sim vs presentation (checkable rule)
- Code under `project/vehicle/` and `project/race/` must **not** reference meshes (`MeshInstance3D`), audio (`AudioStreamPlayer*`), particles (`GPUParticles3D`, `CPUParticles3D`), `Camera3D` or UI nodes. `grep` for these in review.
- Simulation runs only in `_physics_process` (fixed 120 Hz tick, interpolated render). Never advance sim state in `_process`; never use `delta` from `_process` in the sim.
- Presentation (audio, VFX, camera, HUD) reads sim state via signals or exported properties and never writes back.
- Tire and powertrain math are **pure functions** (inputs in, outputs out, no node access) so they are unit-testable.
- Randomness in the sim goes through a seeded `RandomNumberGenerator` owned by the sim, never global `randf()`.

## 3. Branches, commits, pull requests

- **Branch:** `issue-<n>-<short-slug>` from `main` (e.g. `issue-6-contributing`).
- **Commits:** imperative subject <= 72 chars, reference the issue (`Add tire slip curve (#12)`); small, working commits; no WIP commits left unexplained on the PR.
- **One issue per PR.** Description starts with `Closes #<n>` and summarises what changed and how it was verified. Merge policy: **squash-merge**, branch deleted afterwards.
- Label PRs/issues with `area:*` and the milestone of the issue.

### PR checklist
- [ ] Every acceptance-criteria checkbox on the issue is satisfied (tick them in the PR description).
- [ ] `godot --headless --path project --import --quit` prints no `ERROR` / `SCRIPT ERROR`.
- [ ] Test command (section 5) exits 0; new logic has tests.
- [ ] No sim code references presentation (section 2 rule).
- [ ] No unrelated changes, generated caches (`.godot/`) or telemetry dumps.
- [ ] Wiki/README updated if a design number, folder or command changed.
- [ ] **Physics changes only** (anything under `vehicle/` or `surfaces/` that alters behaviour): telemetry evidence attached or linked, i.e. a CSV channel summary or plot from the telemetry overlay before vs after, plus a one-line statement of the expected feel change. See [Physics Tuning and Telemetry](https://github.com/gambarini/racing/wiki/Physics-Tuning-and-Telemetry).

## 4. Assets and Git LFS

- Binary types tracked by LFS are defined in `.gitattributes` (`png jpg jpeg tga exr hdr psd glb gltf fbx blend obj wav ogg mp3 ttf otf`). Do not commit those types without `git lfs install` having run; verify with `git lfs ls-files`.
- `.blend` sources go in `art-source/<category>/<asset>.blend`, **never** inside `project/`. Exports go in `project/<area>/<asset>/<asset>.glb` using the "Racing glb" export preset.
- Follow the [Art Pipeline (Blender)](https://github.com/gambarini/racing/wiki/Art-Pipeline-Blender) rig naming contract and its checklist before committing an asset (applied transforms, scale 1, origins, collision hull, tri budget, faces +Z).
- Keep files within [Performance Budgets](https://github.com/gambarini/racing/wiki/Performance-Budgets). Do not commit `.blend1`/`.blend2` backups or telemetry CSVs (gitignored).
- Only add assets you made or whose licence permits it; record the source in the PR.

## 5. Tests

- Framework: **GUT**, installed at `project/addons/gut` (version pinned in README).
- Tests live in `project/tests/`, files named `test_<subject>.gd`, extending `GutTest`, functions `test_<behaviour>`.
- Run all tests headless (same command CI uses):
  ```
  godot --headless --path project -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
  ```
- Expectations: pure logic (tire model, powertrain, race rules, lap timing) **must** ship with unit tests, including edge cases (zero speed, zero load, full lock). Scene wiring and visuals need tests only where cheap; otherwise describe the manual check in the PR.
- Tests must be deterministic and fast (< 1 s each): fixed seeds, fixed `delta`, no wall-clock or real-time waits.
- A bug fix includes a regression test that fails before the fix.
