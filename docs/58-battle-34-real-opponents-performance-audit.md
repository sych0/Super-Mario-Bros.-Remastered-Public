# 58 — 34 real opponents: performance and architecture audit (handoff to local Hermes)

Status: **audit in progress, written in checkpoints.** Each section below is either DONE (its conclusions are final for this pass) or
PENDING (not reached yet: the cloud session may have ended before it). On top of `5815f87` (doc 57 s11 handoff). No gameplay code is changed
by this pass; any measurement instrumentation lives under `tests/tools/` only.

Scope (from Zack): the cheapest technically sound path from a few correct real bot worlds (doc 56/57) to all 34 simultaneous real opponents at
acceptable performance, **without** reverting to a fake simulation. Not in scope: brain tuning, entity/course coverage, UI, gameplay semantics.

## Checkpoint table (resume from here)

| # | Section | State |
|---|---|---|
| 1 | Bottleneck ranking, with measurements | DONE (simulation; rendering in s3) |
| 2 | Threading verdict | DONE |
| 3 | Rendering strategy | PENDING |
| 4 | Load / preload / hitch strategy | PENDING |
| 5 | Memory strategy | PENDING |
| 6 | Architecture decision (stop/go) | PENDING |
| 7 | Ordered implementation plan for Hermes | PENDING |
| 8 | Cheap benchmark / spike tasks | PENDING |
| 9 | Target-machine (Plex Mac) benchmark | PENDING |
| 10 | Handoff state | PENDING |

Measurement environment for every number in this doc unless stated: the cloud container, 4 vCPU Intel Xeon @ 2.1 GHz, 16 GB, Godot
4.6-stable (`/tmp/claude-0/g46/`, not on PATH), no GPU (GL on a software rasteriser under xvfb). Physics engine: **GodotPhysics2D** (`project.godot`
names `Rapier2D`, but that GDExtension is not in the repo, so Godot falls back to its own server: s1.0), `physics_interpolation=true`, renderer
`gl_compatibility`. Cloud numbers are relative evidence;
absolute 60 fps on the target needs section 9.

## 1. Bottleneck ranking (DONE)

### 1.0 Two corrections to doc 56's measurements, found first

* **The physics engine is GodotPhysics2D, not Rapier2D.** `project.godot` names `Rapier2D` (an upstream commit, `2108c25`), but no Rapier
  GDExtension is in the repository (`.godot/extension_list.cfg` lists only discord-rpc and godotgif; `ClassDB.class_exists("RapierPhysicsServer2D")`
  is false), so Godot silently uses its built-in 2D server. Every measurement in docs 56-58 is GodotPhysics2D. Whether Zack's local build has a
  Rapier addon installed is unknown; the target benchmark (s9) prints it (`AUDIT engine ... rapier_class=`).
* **`Performance.TIME_PHYSICS_PROCESS` is the worst physics frame of the last second, refreshed once a second, not a per-frame average.** Doc
  56's `phys_ms` / `proc_ms` columns are therefore maxima; its `frame_ms` (wall time per frame) is correct and is what s17 of doc 56 relied on.
  This audit times everything with timestamps instead.

### 1.1 Method

`tests/tools/battle_bot_cost_audit.gd` (measurement only; new in this pass). It starts N worlds (34) on a course, lets them play 2 s, then times
each physics frame **in place** with probe nodes: a probe records `Time.get_ticks_usec()` when the SceneTree reaches it, and probes are inserted
before every child of each level and of each Mario, plus bands for the `_physics_process` priorities (-100 = `BattleBotWorld`, 0 = level nodes,
1 = `Player.gd` itself: `Player.tscn` sets `process_physics_priority = 1`, so Mario's own script runs after every level's nodes) and for
`_process`. Frame = physics node callbacks + physics "post" (server step, deferred calls, timers, frees) + idle (`_process`, area/body query
callbacks, rendering). The server step is isolated by switching `PhysicsServer2D` off for a 60-frame window. A probe costs 0.5-0.9 us
(subtracted). Plus a census of each world's nodes, micro-benchmarks of hot calls, and the cost of a frozen (KO'd) world. Commands:
`godot --headless --fixed-fps 60 --path . -s tests/tools/battle_bot_cost_audit.gd -- n=34 course=0` (1-1) and `course=1` (1-2).
Raw outputs of this pass: section 1.6.

### 1.2 What a world is made of (census, per world)

| | 1-1 | 1-2 |
|---|---|---|
| nodes | 1 293 | **7 214** |
| nodes with a live `_physics_process` (script) | 18 | 47 |
| nodes with a live `_process` (script) | 91 (SignalExposer 46, BetterAnimatedSprite 40) | **885** (SignalExposer 435, BetterAnimatedSprite 434) |
| internal process (AnimationPlayer, AnimatedSprite2D...) | 69 | 471 |
| canvas items | 681 | 4 071 |
| collision objects (areas / bodies) | 103 (38 / 65) | 556 (94 / 462) |
| `VisibleOnScreenNotifier2D`/`Enabler2D` | 47 | **448** (one `VisibleOnScreenEnabler2D` per brick) |
| `ResourceSetterNew` nodes | 113 | 539 |
| Mario's subtree | 78 nodes, 11 script callbacks, 9 internal | same |

The brick (`BrickBlocks/BrickBlock.tscn`, an `AnimatableBody2D`) carries a `BetterAnimatedSprite2D` with a `ResourceSetterNew`, a
`VisibleOnScreenEnabler2D`, and a `SignalExposer` (the level editor's wiring gizmo) whose `_process` is `PROCESS_MODE_ALWAYS`.

### 1.3 Where a world's frame goes (34 worlds, all alive, headless, this CPU)

Microseconds per world per frame. 34 worlds: 1-1 frame 37.9-40.2 ms wall (1.03 ms per world after the tool's own 2.9 ms); 1-2 frame
124.2-124.7 ms (3.55 ms per world after the tool's 3.9 ms).

| Cost | 1-1 | 1-2 | What it is |
|---|---|---|---|
| **Screen emulation** (`BattleBotWorld._update_screen`) | 27 | **880** (250 when one world is timed alone, cache warm) | GDScript scan of every notifier each tick: `get_global_transform() * rect`, intersect, compare. Linear in notifiers: 47 vs 448 |
| **`_process` callbacks** (idle) | 190 | **1 320** | 1-2: 435 `SignalExposer._process` (writes `global_scale = ONE` every frame) + 434 `BetterAnimatedSprite._process` (writes `position.y` from the frame texture every frame); plus internal AnimationPlayer (443) / AnimatedSprite2D (496) processing; Player / StateMachine / PlayerMoveEffects `_process` |
| other idle (area/body query callbacks, transform notifications, input) | ~70 | ~340 | grows with the per-frame transform writes above |
| **Mario: StateMachine** (`Normal.physics_update`: movement, gravity, `move_and_slide`) | 122 | 143 | the real player's rules |
| **Mario: `Player.gd` own `_physics_process`** | 50-55 | 65-69 | ~30 `physics_params` lookups (1.1-2.4 us each: string scans of `"WALK" in type` etc.), `handle_collision_shapes` (6-7 us: shape writes every frame), step collision |
| Mario: `ScalableCollisionPolygon` | 27 | 61 | rebuilds the collision polygon every frame |
| Mario: other children (areas, raycasts, camera) | ~20 | ~25 | |
| Enemies | 67-79 | 114 | Goomba / Koopa / Piranha scripts + `move_and_slide` |
| **Physics server step** (GodotPhysics2D) | 162-173 | 196 | broadphase / pairs of the world's own space (66 pairs per world on 1-1, 230 on 1-2) |
| physics post minus step (deferred calls, physics timers, frees) | ~45 | ~100 | e.g. `set_deferred("disabled")` on Mario's feet every frame |
| Brain (`BattleBotController`) | ~170 (planning 97) | ~100 (planning 44) | planning = 0.05-0.11 plans per world-frame x 880-920 us per plan; the rest is per-frame scans (`_foe_nodes` 14 us, `_foes` 13 us, called several times a frame) |
| `BattleIncomingSpawner` | 27 | 36 | per-frame session read + plan advance + watch, even with nothing incoming |
| `LevelBGNew` | 21 | 26 | background (presentation) repositioning every physics frame |
| PipeArea / WarpZone / Elevator / flag / tiles | ~25 | ~120 | gameplay; tiles 55 on 1-2 |
| **Frozen world** (a KO'd world: `set_frozen(true)`) | **200** | **2 200** | not near zero: `PROCESS_MODE_ALWAYS` overrides the frozen level, so 101 (1-1) / 895 (1-2) nodes keep processing |

Micro-benchmarks (this CPU): an empty GDScript `_physics_process` costs the SceneTree 0.12 us per node; a node without a callback costs
nothing per frame. `physics_params()` 1.1-2.4 us; `GameWorld.bot_of` 0.3-0.65 us; `Global.player_action_pressed` (bot) 0.9 us;
`handle_invincible_palette` 3.1-3.4 us (8 `set_shader_parameter` calls, every `_process`); `GameWorld.group(..)` with 34 worlds **233-320 us**
per call (it scans every member of the group in every world: O(total) per call, so any per-frame use is O(N²); today only
`Player.apply_active_flingers` calls it per frame, on the empty `PlayerFlingers` group, so it costs ~1 us - a latent hazard, not a cost).

### 1.4 The ranking

Ranked by what they cost 34 worlds at the start of a round (the frame that must hold), on the courses measured. "Class" uses the categories of
the brief.

| # | Bottleneck | 34 worlds, 1-1 / 1-2 (ms per frame, this CPU) | Class | Why this class |
|---|---|---|---|---|
| 1 | Per-frame `_process` of level decoration: `SignalExposer` (editor gizmo, `ALWAYS`), `BetterAnimatedSprite` offset polling, idle animation players | 6.5 / **45** (+ ~12 of the transform traffic they cause) | **low-risk local optimization** | both scripts recompute a value that changes only on an event (frame / animation / sprite-frames change; the editor's own gizmo state); event-driven code gives the same values. Presentation only, no rule involved |
| 2 | Screen emulation scans every notifier every tick | 0.9 / **30** | **low-risk local optimization** (our own code) | a spatial index (notifiers bucketed by x; only buckets near the camera, plus every moving notifier, plus every notifier currently on) gives the same on/off sequence; prove it with a side-by-side equivalence test |
| 3 | KO'd / frozen worlds keep processing (`ALWAYS` nodes) | 6.8 / **75** when all are out | **low-risk local optimization** | an OUT world's game is over: take its level out of the tree (keep the pane's last picture) or free it. No rule is involved after the KO |
| 4 | Mario's own rules: state machine + `Player.gd` + collision polygon | 8.4 / 9.4 | **medium-risk optimization** (shared with the real player) | `physics_params` memoisation per frame, polygon rebuild only on change (doc 56: -14 %), palette shader params only on change, `set_deferred` only on change. Same rules, but it is the real player's hot path: behaviour-identical tests required. Expected -30 to -40 % of Mario |
| 5 | Physics server step | 5.9 / 6.7 | **should not be touched** (now) | it is the physics; per-world spaces are what keep games independent. Rapier (if it were installed) is a separate decision with its own determinism risk |
| 6 | Brain | 5.8 / 3.4 | **can be amortized** (cadence, plan reuse, cache per-frame scans) | already cheap; threading not needed (s2) |
| 7 | Enemies' scripts + physics | 2.6 / 3.9 | should not be touched | gameplay |
| 8 | `BattleIncomingSpawner` + `LevelBGNew` per frame | 1.6 / 2.1 | **low-risk local optimization** | spawner: early-out when the target has nothing incoming; background: presentation, can follow the pane's render cadence |
| 9 | Physics post (deferred calls etc.), other gameplay nodes | 1.5 / 4 | leave | small, spread |
| - | Rendering the panes | s3 | s3 | measured separately |

**Reading.** On 1-1 the cost is spread (Mario 25 %, brain 17 %, physics step 16 %, decoration `_process` 18 %...): the "Player is most of a
world" picture of doc 56 holds only there. On a brick course the cost is dominated by things that are **not gameplay at all** - the editor's
gizmo processing every frame, sprite-offset polling, and our own screen emulation - each linear in brick count and each fixable locally. Items
1-3 together take 1-2 from 3.55 ms to roughly 1.1-1.3 ms per world without touching a rule. KOs do not save what doc 56 assumed (item 3) until
that is fixed.

### 1.5 What 34 costs after the low-risk items (estimate, this CPU, simulation only)

| | 1-1 | 1-2 |
|---|---|---|
| now (per world) | 1.03 ms | 3.55 ms |
| after items 1-3 and 8 | ~0.80 ms | ~1.15 ms |
| after item 4 too | ~0.70 ms | ~1.05 ms |
| 34 worlds, simulation, after 1-4 | ~24 ms | ~36 ms |

Still above a 16.7 ms frame **on this 2.1 GHz cloud Xeon, single thread**, before the real player's game, the Battle screen and rendering. The
target Mac's single-thread speed decides how far that is (s9); s2 decides whether threads can close the rest.

### 1.6 Raw measurements kept

The AUDIT lines this section rests on (two runs per course, 2026-10-18, commit `840b5d1` + the tool):

```
1-1: AUDIT probed frame wall_ms=37.85 = physics nodes 19.74 + physics post 7.03 + idle 11.08 (of which _process callbacks 6.19)
1-1: AUDIT probed levels_ms=12.83 (0.377 per world) bot_world_own_ms=6.60 (0.194 per world)
1-1: AUDIT probed Player.gd own 49.6-55.0 us; physics server step ~5.49-5.89 ms; brain plans=0.11/world-frame, 880 us per plan
1-1: AUDIT frozen all worlds frozen: frame 6.86 ms vs 36.43 running; nodes still processing per frozen world=101
1-2: AUDIT probed frame wall_ms=124.20 = physics nodes 53.47 + physics post 9.55 + idle 61.18 (of which _process callbacks 41.96)
1-2: AUDIT probed levels_ms=19.48 (0.573 per world) bot_world_own_ms=32.97 (0.970 per world)
1-2: AUDIT micro one extra world step (all 34 worlds): 897.4 us per world, of which _update_screen 880.4 us
1-2: AUDIT brain plans=0.05/world-frame, 920 us per plan -> planning 43.5 us; physics server step ~6.66 ms
1-2: AUDIT frozen all worlds frozen: frame 75.94 ms vs 150.99 running; nodes still processing per frozen world=895
segments 1-1 (us/world-frame): Player subtree 190, StateMachine 122, Enemies 67-79, Collision polygon 27, IncomingSpawner 27, LevelBG 21, PipeArea 12
segments 1-2: Player subtree 268, StateMachine 143, Enemies 114, Collision polygon 61, Tiles 55, IncomingSpawner 36, LevelBG 26, PipeArea 19, WarpZone 16
```

## 2. Threading verdict (DONE)

### 2.1 Measured (`tests/tools/battle_bot_thread_spike.gd`, 8 worlds on 1-1, 5 s, same seed)

| Run | Frame | Engine errors in 5 s | Games |
|---|---|---|---|
| main thread (as built) | 7.81 ms | 0 (start-up noise only) | reference traces |
| each `BattleBotWorld` in its own processing thread group (`process_thread_group = SUB_THREAD`: its subtree's callbacks on the WorkerThreadPool) | **14.20 ms** (slower) | **~39 000**: 7 200 x `Condition "!Thread::is_main_thread()" ... Returning: nullptr` + `Parameter "dss" is null` (the physics direct space state - every RayCast2D / ShapeCast / intersect query - is main-thread only); thousands of `set_visible()` / `hide()` / `set_position()` / `BotViewport.set_canvas_transform()` "can only be accessed from the main thread" (CanvasItem visibility, the camera); 2 400 more main-thread guards returning false | **all 8 differ** from the main-thread run (raycasts fail, so feet, ice, step walls and ledges are wrong); two worlds produced the same trace (broken) |
| main thread, `physics/2d/run_on_separate_thread=true` (via a temporary `override.cfg`) | 34 worlds: 34.5 ms vs 35.9 ms without (-4 %, within run-to-run noise) | 16 x `Parameter "body->get_space()" is null` | 1 of 8 worlds plays differently |

### 2.2 Answers

| Question | Answer |
|---|---|
| What can run off the main thread today | Pure computation over data the main thread snapshotted: the brain's plan search (`BattleBotController._sim` over the immutable `BattleBotCourseMap` and a copy of Mario's / the foes' numbers); building a course's `BattleBotCourseMap`; **loading** a level `PackedScene` (`ResourceLoader.load_threaded_request`) and **instantiating** it as a detached node tree (allowed: a tree not in the SceneTree belongs to no thread group). Nothing that touches a node in the tree |
| What cannot | Any gameplay node's callbacks: they set visibility, positions, the camera's canvas transform, and query the physics space; Godot 4.6 guards all of those to the main thread (measured above). `add_child` into the live tree, `queue_free`, signals to main-thread objects (`BattleSession`, `Global`, the director) |
| SceneTree operations | Not safe from worker threads except inside a node's own sub-thread group, and the gameplay code calls across groups everywhere (`Global`, `BattleSession`, `GameWorld` statics, `AudioManager` guards). Detached trees are fine |
| Physics queries / body movement | `move_and_slide` did not raise in the spike, but the direct space state (every raycast) is main-thread only, so a world cannot play off the main thread. The separate physics thread gives no measurable gain here and perturbs results (above) |
| SubViewport / render work | Canvas item state is main-thread guarded; the supported parallelism is the engine's own render thread (`rendering/driver/threads/thread_model`), which overlaps the RenderingServer's work with the next frame's simulation without touching gameplay. Worth measuring on the target (s9), not in this container (software GL) |
| Full bot-world simulation on worker threads | **Not realistic in Godot 4.6.** It fails on the engine's own guards before any question of our shared state; making it work means deferring every visual change and every physics query in ~120 gameplay scripts. **Rejected.** |
| Only the AI planning layer | Feasible and safe (pure computation on a snapshot; join inside the same frame so it stays deterministic), but small: planning is 1.5-3.3 ms for 34 worlds on this CPU, and cadence / plan reuse cuts most of it without threads. **Later, only if s9 says the brain matters on the Mac** |
| Another parallelization | (1) **threaded level loading** + detached instancing (s4): removes load hitches, safe; (2) **the render thread** (thread_model = separate) for the 34 pane renders: a project setting, measure on the Mac; (3) separate physics thread: measured, rejected; (4) one OS process per group of bots: rejected (34 x the engine, IPC for panes and attacks, the opposite of doc 56's single-process decision) |

**Verdict.** Do not thread the worlds. Keep every world's simulation on the main thread and make it cheaper (s1.4, items 1-4). The only thread
work worth planning: loading on a worker (now), the engine's render thread (measure), and brain planning on the pool (only if needed). If the
project ever wants simulation parallelism, it needs the rules state separated from Godot nodes first (s6), and that is not on the critical path.
