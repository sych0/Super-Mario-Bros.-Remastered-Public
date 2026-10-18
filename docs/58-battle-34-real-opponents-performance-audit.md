# 58 — 34 real opponents: performance and architecture audit (handoff to local Hermes)

Status: **audit in progress, written in checkpoints.** Each section below is either DONE (its conclusions are final for this pass) or
PENDING (not reached yet: the cloud session may have ended before it). On top of `5815f87` (doc 57 s11 handoff). No gameplay code is changed
by this pass; any measurement instrumentation lives under `tests/tools/` only.

Scope (from Zack): the cheapest technically sound path from a few correct real bot worlds (doc 56/57) to all 34 simultaneous real opponents at
acceptable performance, **without** reverting to a fake simulation. Not in scope: brain tuning, entity/course coverage, UI, gameplay semantics.

## Checkpoint table (resume from here)

| # | Section | State |
|---|---|---|
| 1 | Bottleneck ranking, with measurements | PENDING |
| 2 | Threading verdict | PENDING |
| 3 | Rendering strategy | PENDING |
| 4 | Load / preload / hitch strategy | PENDING |
| 5 | Memory strategy | PENDING |
| 6 | Architecture decision (stop/go) | PENDING |
| 7 | Ordered implementation plan for Hermes | PENDING |
| 8 | Cheap benchmark / spike tasks | PENDING |
| 9 | Target-machine (Plex Mac) benchmark | PENDING |
| 10 | Handoff state | PENDING |

Measurement environment for every number in this doc unless stated: the cloud container, 4 vCPU Intel Xeon @ 2.1 GHz, 16 GB, Godot
4.6-stable (`/tmp/claude-0/g46/`, not on PATH), no GPU (GL on a software rasteriser under xvfb). Physics engine: **Rapier2D** (GDExtension,
`project.godot` `[physics] 2d/physics_engine`), `physics_interpolation=true`, renderer `gl_compatibility`. Cloud numbers are relative evidence;
absolute 60 fps on the target needs section 9.
