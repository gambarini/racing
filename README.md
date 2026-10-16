# Racing (working title)

A 3D off-road racing game: wheel-to-wheel packs of cars on dirt, gravel, mud and mixed-surface tracks, built around vehicle physics convincing enough that every surface change is something you feel and use.

- **Engine:** Godot 4 · **Platform:** PC · **Mode:** single-player vs AI (multiplayer later)
- **Design docs / GDD:** [Wiki](https://github.com/gambarini/racing/wiki) — start with [Vision and Pillars](https://github.com/gambarini/racing/wiki/Vision-and-Pillars)
- **Roadmap:** [GitHub Project "Racing Roadmap"](https://github.com/users/gambarini/projects/2) · [Milestones](https://github.com/gambarini/racing/milestones)

## Where we are
Pre-production. The first goal is **M1 — Driving-feel prototype**: one car on a test pad with tarmac, gravel and mud patches, a custom tire model and a telemetry overlay. Everything else builds outward from a car that is fun to drive.

## Getting started (once M0 lands)
1. Install Godot **4.6.2.stable.official.71f334935** (`Godot --version` must print exactly this; pinned in `project/project.godot` as `config/godot_version`).
2. Install Git LFS: `brew install git-lfs && git lfs install`.
3. Clone, then open `project/project.godot` in Godot.
4. Models and animation are made in Blender (`art-source/`) and exported as `.glb` — see [Art Pipeline (Blender)](https://github.com/gambarini/racing/wiki/Art-Pipeline-Blender).

## Repository layout
See [Tech Architecture](https://github.com/gambarini/racing/wiki/Tech-Architecture).
