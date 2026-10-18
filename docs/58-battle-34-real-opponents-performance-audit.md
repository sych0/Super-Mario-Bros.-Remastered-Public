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
| 3 | Rendering strategy | DONE |
| 4 | Load / preload / hitch strategy | DONE |
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

## 3. Rendering strategy (DONE)

### 3.1 Measured (GL compatibility renderer on Mesa's software rasteriser under xvfb; 34 worlds; `battle_bot_cost_audit.gd ... render=1`)

Panes are rendered as `BattleBotDirector` does (`UPDATE_ONCE` on each world's `BattleBotViewport`); `every=2` renders half the worlds each
frame (each pane at 30 Hz, alternating halves). `draw` = wall time from `RenderingServer.frame_pre_draw` to `frame_post_draw`.

| Course | Panes | Frame | Draw | Draw calls per frame (per rendered pane) |
|---|---|---|---|---|
| 1-1 | not rendered | 47.3 ms | - | - |
| 1-1 | every frame | 95.0 ms | 52.2 ms | 329 (**9.7**) |
| 1-1 | every 2nd frame, staggered | 73.5 ms | 30.7 ms | 166 (9.8) |
| 1-1 | every frame, bot worlds' `physics_interpolation_mode = OFF` | 92.2 ms | 50.2 ms | 329 |
| 1-2 | not rendered | 128.5 ms | - | - |
| 1-2 | every frame | 180.2 ms | 64.3 ms | 392 (11.5) |

Reading: render cost is **linear in panes rendered per frame** (staggering by 2 halves it exactly), and a pane is only ~10 draw calls: the
2D batcher already merges a world's tiles and sprites, so a shared compositor has nothing left to batch. On this machine a pane costs
~1.4-1.9 ms, almost all of it the software rasteriser filling 256x240 (6x the canvas items on 1-2 add only 23 %: the canvas walk is ~0.1 us
per item here). On a GPU the fill is negligible; what remains per pane is the CPU walk of the world's canvas items (681 on 1-1, 4 071 on
1-2) plus ~10 draw calls: estimated 0.1-0.4 ms per pane on the Mac, **to be measured** (s9). Physics interpolation in bot worlds costs ~3 %
of the rendered frame: real but small.

### 3.2 The options

| Option | Verdict | Why |
|---|---|---|
| 1. 34 SubViewports rendered every frame (today) | keep the mechanism, not the cadence | correct and simple; cost linear in panes |
| 2. Simulation at 60 Hz, panes at 30 Hz | **yes** | simulation never depends on rendering (doc 56: notifiers are emulated, worlds never render themselves), so gameplay is identical at any pane rate; halves render cost |
| 3. Staggered pane rendering across frames | **yes, with 2** | same total as 2 but an even load per frame (17 panes a frame instead of 34 every other frame) |
| 4. Shared atlas / compositor (all worlds' canvases attached to one viewport) | **no** | no per-canvas clipping (each world's canvas would draw over its neighbours' cells), camera transforms to re-implement, and nothing to batch (10 draw calls a pane already) |
| 5. Selective rendering of only the pane's visible content | **no gain worth it** | Godot already culls per canvas item; the 256x240 viewport must stay (the real camera and its limits use the viewport size); the crop is free on a GPU |
| 6. Freeze rendering for KO'd / inactive worlds | **yes** (OUT already skipped); add: frozen pre-round = render once; a fading world keeps rendering | free |
| 7. Others | `physics_interpolation_mode = OFF` on each `BattleBotWorld` (bots render at the physics rate; -3 %, low risk); the engine's render thread (`thread_model`) - measure on the Mac; adaptive cadence (2 -> 3 when the frame budget is exceeded) | |

### 3.3 Recommendation

1. `BattleBotDirector` renders each live world every **2nd** frame, staggered by contestant id (`(id + frame) % 2 == 0`); a world renders
   once more on entering OUT (so the pane keeps the death's last picture) and once while frozen (pre-round), never again until it changes.
2. Make the cadence a director field (`pane_every`, default 2) so the Mac benchmark can try 1, 2 and 3; consider adaptive 2->3 only if s9
   shows the panes still cost too much.
3. Bot worlds opt out of physics interpolation (`physics_interpolation_mode = OFF` on the `BattleBotWorld`).
4. Do not build a compositor. Do not shrink the viewports.

Expected: pane rendering halves (on this machine 52 -> 31 ms for 34 panes; on the Mac, half of whatever s9 measures). Gameplay unchanged by
construction (the world's simulation is identical with or without rendering: doc 56 s2, `battle_bot_world_test`'s determinism checks).

## 4. Load, preload and transition hitches (DONE)

### 4.1 Measured (`tests/tools/battle_bot_load_probe.gd`, headless, this CPU)

One world created at a time with nothing else running (two runs; ranges):

| Course | Nodes | Scene load | `instantiate()` | `add_child` (enter tree + `_ready`, incl. `ResourceSetterNew`) | **First frame** | 2nd / 3rd frame |
|---|---|---|---|---|---|---|
| 1-1 cold (first world of the process) | 1 291 | 145-196 ms | 20-24 ms | 142-204 ms | 62-84 ms | 4-6 / 2-3 ms |
| 1-1 warm | 1 291 | 0 (cached) | 8-12 ms | 28-49 ms | **32-50 ms** | 2 / 1-2 ms |
| 1-2 cold (its themed resources not resolved yet) | 7 212 | 31-47 ms | 10-14 ms | 167-188 ms | **512-523 ms** | 18 / 3 ms |
| 1-2 warm | 7 212 | 0 | 11-17 ms | 39-63 ms | **191-271 ms** | 3-5 / 3 ms |

**Where the first frame goes.** All of it is before the physics callbacks (1-2 warm: 247 ms "before physics nodes", 2.5 ms physics nodes, 0.8
ms post). It is the `TileMapLayer`'s deferred internal update: SMB1's bricks, `?` blocks and coins are **scene tiles** of `Scenes/Parts/Tiles.tscn`
(a `TileSetScenesCollectionSource`), so the level scene holds only cells, and the engine instantiates every block scene (16 nodes each: body,
`BetterAnimatedSprite2D` + `ResourceSetterNew`, collision, `BlockAnimations`, `EditorPropertyExposer`, `PSwitcher`, `TrackJoint`,
`LevelPersistance`, `VisibleOnScreenEnabler2D`, `SignalExposer` + its `LineDrawer`) and runs their `_enter_tree` / `_ready` on the level's
first frame, on the main thread. ~0.55 ms per block on 1-2 warm. This is why `instantiate()` is cheap and the first frame is not.

**A real cut while 33 other worlds play 1-1** (the bot's own `_finish_course`): the cut itself (free 1-1, instantiate 1-2, enter tree) 68-71 ms,
then the next frame **275 ms** (1-2 cold for this process) and **439 ms** for the second world's cut. Base frame 31 ms. (This run also printed
out-of-range errors from the probe's own contestant ids above 34, which inflate the base frame a little; the cut costs are the probe's own
timestamps.) So a course change today is a **~0.35-0.5 s single-frame stall** on this CPU, dominated by block-scene instancing.

**Threads.** `PackedScene.instantiate()` of 1-2 on a `WorkerThreadPool` task **deadlocks** if the main thread blocks in
`wait_for_task_completion` (measured: hung at 0 % CPU); with the main thread polling `is_task_completed` each frame it completes (14.5 ms on
the worker; main frames unaffected, 0.16 ms) and the detached level then enters the tree on the main thread in 55 ms. But that moves only
the cheap part: the block scenes are made later, in the tree, by the `TileMapLayer`.

**Round start today.** `BattleScreen._ensure_driver` creates all 34 worlds in one process frame (`bots.start(real)`): on this CPU about
34 x (10 + 35-50) ms of creation plus 34 x 32-50 ms of first frames in the next frame (doc 56: 1.25 s + 1.26 s for 34). PRE_ROUND lasts 5.25 s
with the game window frozen, so there is room to spread it.

### 4.2 Recommendations (simplest safe first; none changes course progression: the cut still happens on the same tick, after the fade, into a
fully built level)

1. **Warm caches before the round** (low risk): at the Battle menu or LOADING, load the `PackedScene`s of 1-1 and 1-2 into
   `BattleBotWorld._packed` (on a worker, polled - never a blocking wait), and resolve the themed resources of their themes once (create one
   throwaway bot world per theme in a hidden viewport and free it after its first frame). Removes the cold penalty: 1-2's first frame
   512 -> ~230 ms here, 1-1's first world 400 -> ~80 ms.
2. **Spread round-start creation** (low risk): the director creates worlds over several frames with a time budget (e.g. stop for this
   frame once 8 ms are spent; at least one world per frame), starting at LOADING and finishing inside PRE_ROUND; every world must exist and
   have had its first frame before PLAYING (assert it). Worlds are frozen until PLAYING, so a partial set is harmless; nothing about a
   world's game changes. On this CPU that is ~34 frames of ~75 ms during the countdown; on the Mac roughly a third (measure, s9). If the
   countdown's frame drops are visible, start earlier (the LOADING / transition screen).
3. **Make blocks cheaper to create** (medium risk, biggest lever on load *and* per-frame cost of brick courses):
   * a `ResourceSetterNew` fast path when the resolved resource for (json path, skin state) is cached: skip `load(json)`, the pack walk and
     `randomize()` (the latter also stops reseeding the global RNG on every resolve, doc 56 s11);
   * **lean derived block scenes for bot worlds**: bot worlds already use their own themed `TileSet` copies (`BattleBotWorld.tileset_with`);
     give those copies' scene collection sources a derived `PackedScene` per block built once at start-up from the real prefab with the
     editor-only nodes removed (`SignalExposer` + `LineDrawer`, `EditorPropertyExposer`, `TrackJoint`; `LevelPersistance` already does
     nothing in a bot world). Same block script, collision, animations and P-switch: the real block, minus the level editor. One source of truth
     (the real `.tscn`), a list of stripped node names, and a parity test (bump, break, coin, P-switch, item blocks) in a bot world.
   Expected: block creation 2-3x cheaper; with s1 item 1 the per-frame cost of bricks also drops.
4. **Stage the next course during the clear** (medium risk; only if 1-3 leave the cut above budget on the Mac): from the flagpole touch to the
   cut there are ~1.3-1.5 s (slide, 0.27 s hold, 6-frame fade). At the touch, instantiate the next level on a worker (polled); then add it,
   `process_mode = DISABLED`, to a second `BattleBotViewport` the world owns (its own World2D, so it never meets the playing level), let its
   first frame build the blocks there; at the cut, make that viewport the world's active one (enable it, point the cell at its texture, free
   the old one). Needs: `GameWorld.bot_of` to treat the staging viewport as "not yet this world's game" (no enemy adoption, no notifier
   adoption until promoted), and doc 57's transition assertions changed from "same viewport RID" to "the cell shows the world's active
   viewport". The cost still lands in one frame, just earlier and off the cut; the real fix for the spike is item 3.
5. **Free old levels in slices** (low risk): at the cut / KO, remove the old level from the tree at once (the game is over for it) and free its
   subtrees over the next frames (e.g. one top-level child per frame), so a 7 000-node free never lands in one frame. A KO'd world's level is
   freed the same way (s1 item 3); its pane keeps the last rendered picture (the viewport is not re-rendered).
6. **Do not** build level node trees on worker threads beyond `instantiate()` (the in-tree block instancing cannot move), and never block the
   main thread on a worker that touches resources (deadlock, measured).
