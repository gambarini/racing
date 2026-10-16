# Racing (working title)

A 3D off-road racing game: wheel-to-wheel packs of cars on dirt, gravel, mud and mixed-surface tracks, built around vehicle physics convincing enough that every surface change is something you feel and use.

- **Engine:** Godot 4 · **Platform:** PC · **Mode:** single-player vs AI (multiplayer later)
- **Design docs / GDD:** [Wiki](https://github.com/gambarini/racing/wiki) — start with [Vision and Pillars](https://github.com/gambarini/racing/wiki/Vision-and-Pillars)
- **Roadmap:** [GitHub Project "Racing Roadmap"](https://github.com/users/gambarini/projects/2) · [Milestones](https://github.com/gambarini/racing/milestones)

## Where we are
Pre-production. The first goal is **M1 — Driving-feel prototype**: one car on a test pad with tarmac, gravel and mud patches, a custom tire model and a telemetry overlay. Everything else builds outward from a car that is fun to drive.

## Getting started (once M0 lands)
1. Install Godot **4.6.2.stable.official.71f334935** (`Godot --version` must print exactly this; pinned in `project/project.godot` as `config/godot_version`).
2. Install Git LFS: `brew install git-lfs && git lfs install` (once per machine; run it before your first commit). After cloning, run `git lfs pull` to fetch real binaries. CI: use `actions/checkout` with `lfs: true`.
3. Clone, then open `project/project.godot` in Godot.
4. Models and animation are made in Blender (`art-source/`) and exported as `.glb` — see [Art Pipeline (Blender)](https://github.com/gambarini/racing/wiki/Art-Pipeline-Blender).

## Repository layout
See [Tech Architecture](https://github.com/gambarini/racing/wiki/Tech-Architecture). Conventions, PR checklist and test expectations: [CONTRIBUTING.md](CONTRIBUTING.md).

## Running tests
Tests use [GUT](https://github.com/bitwes/Gut) **v9.6.1** (pinned), installed at `project/addons/gut` and enabled in `project.godot`. Tests live in `project/tests/` as `test_<subject>.gd`.

```
godot --headless --path project --import --quit      # once after a fresh clone
godot --headless --path project -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```
Exit code is 0 when all tests pass, non-zero otherwise. CI (#4) calls the same command. On macOS, `godot` is `/Applications/Godot.app/Contents/MacOS/Godot`.
