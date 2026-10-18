# 58 — 34 real opponents: performance and architecture audit (handoff to local Hermes)

Status: **audit complete** (all ten sections DONE; written in checkpoints, each committed and pushed as it was finished). On top of `5815f87` (doc 57 s11 handoff). No gameplay code is changed
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
| 5 | Memory strategy | DONE |
| 6 | Architecture decision (stop/go) | DONE |
| 7 | Ordered implementation plan for Hermes | DONE |
| 8 | Cheap benchmark / spike tasks | DONE |
| 9 | Target-machine (Plex Mac) benchmark | DONE (to be run by Hermes) |
| 10 | Handoff state | DONE |

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

### 1.7 Spike: item 1 measured, not estimated

`battle_bot_cost_audit.gd ... course=1 spike=decor` switches off, in every bot world, the `_process` of each `SignalExposer` once its
first-frame setup is done (`no_moving == true`, not editing) and of each `BetterAnimatedSprite2D` whose `do_offset` is false (bricks set
`do_offset = false`, so their `_process` does nothing but cost the call). 870 callbacks per world on 1-2. No game code changed.

| 34 worlds on 1-2 | Before | With the spike |
|---|---|---|
| frame | 124.2-124.7 ms | **76.6 ms** (-38 %) |
| `_process` callbacks | 42-45 ms | 10.4 ms |
| idle total | 60-61 ms | 20.5 ms |
| physics nodes | 53.5-54.4 ms | 47.6 ms (less transform traffic) |
| all 34 frozen (KO'd) | 75.9 ms | 36.7 ms (459 nodes per world still process: item 3 is still needed) |

The remaining physics-node time is mostly the screen emulation (bot world's own step 0.89 ms per world): item 2 is next in size.

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

## 5. Memory strategy (DONE)

### 5.1 Measured (`battle_bot_cost_audit.gd`, `AUDIT memory`, headless `MEMORY_STATIC`, after 1 s of play)

| Course | 1 world (incl. shared resources) | 8 worlds | Per additional world | 34 worlds (projected) |
|---|---|---|---|---|
| 1-1 | 25.7 MB | 69.2 MB | **6.2 MB** (matches doc 56) | ~230 MB |
| 1-2 | 48.0 MB | 241.9 MB | **27.7 MB** | **~960 MB** |

Per-world memory is node data, not art: textures, `SpriteFrames`, scripts and `PackedScene`s are already shared (doc 56 s8; Godot shares loaded
resources; `ResourceSetterNew` caches per skin state; bot `TileSet` copies are per texture set, not per world). 1-2's ~430 block scenes at 16
nodes each (~64 KB per block with their script instances, physics bodies and canvas items) are the bulk. With the GL renderer, canvas items
cost more than in headless; the 34 viewports' render targets are small (256x240 RGBA: ~0.25 MB each, ~8 MB total).

Shared-resource audit for the per-frame writers: Mario's per-frame `shape.size` writes go to `resource_local_to_scene` shapes
(`Player.tscn`: Hitbox, BlockCollision) - per instance, so no cross-world contamination and no accidental sharing to fix.

### 5.2 Strategy

1. **Free a KO'd world's level** (s1 item 3, s4 item 5): its game is over; keep only the pane's last picture. Returns 6-28 MB per KO; with the
   reference's KO curve (10 out by 35 s, 20 by 95 s) most of the peak is transient.
2. **Lean derived block scenes** for bot worlds (s4 item 3): ~25 % fewer nodes per block (4 of 16 are editor-only).
3. **Never hold two full levels per world** except during a staged clear (s4 item 4), which is bounded by how many worlds are clearing at
   once; the previous level is freed at the cut (in slices).
4. **Do not duplicate resources per world.** Any new per-world copy (a material, a TileSet, a SpriteFrames) must be keyed by its content
   and shared, as `tileset_with` does. Check with `AUDIT memory` when adding one.
5. Budget: the peak is the round start with all 34 alive on the same early course; 1-1 is cheap (230 MB); a brick course is ~1 GB today and
   ~0.7 GB after item 2. Measure on the Mac (s9 prints it); if the target has 8 GB of unified memory shared with the GPU, item 2 matters.

## 6. Architecture decision (DONE)

### 6.1 Can REAL LEVEL SCENE + REAL PLAYER + REAL ENEMIES per opponent reach 34?

What the measurements say about where the cost is (s1.3, per world-frame, this CPU):

| | 1-1 | 1-2 |
|---|---|---|
| **the rules** (Mario's state machine + `Player.gd` + collision polygon + enemies) | ~270 us (26 %) | ~390 us (11 %) |
| the physics server step (the real collisions) | ~170 us (16 %) | ~200 us (6 %) |
| **not rules**: decoration / editor `_process`, screen emulation, transform traffic, spawner, background | ~330 us (32 %) | ~2 500 us (70 %) |
| brain | ~170 us (16 %) | ~100 us (3 %) |
| rendering a pane (s3) | per pane rendered; halves at 30 Hz | |

The rules are a minority of the cost, and the majority is fixable locally without touching a rule (s1.4 items 1-3, 8; s3; s4). After the
low-risk items a world costs ~0.7-1.05 ms on this 2.1 GHz cloud core (s1.5): 34 worlds ~24-36 ms of simulation on one thread here. A current
Apple-silicon performance core runs GDScript-heavy single-threaded work roughly 2-2.5x faster than this vCPU (an estimate, not a measurement:
s9 replaces it), which puts 34 worlds at ~10-16 ms on the Mac, plus the real player's game, the Battle screen and 17 pane renders a frame.
**Plausible at 60 fps on 1-1-like starts; tight on a brick course with all 34 alive; to be settled by s9.** KOs then lower the cost quickly
once their levels are freed (s5 item 1).

### 6.2 Would a deeper split (gameplay/rules state vs Godot presentation/node graph) pay?

* It would attack the 11-26 % that is rules, and at best halve it (GDScript rules in a tighter form, or C++): ~0.15-0.2 ms per world, ~5-7 ms
  for 34 on this CPU. The 70 % on brick courses is not rules and would remain.
* It means re-expressing `Player.gd` (1 778 lines), the state machine, every enemy and block, and the collision semantics of `move_and_slide`
  outside the node graph, and then running the **real player's game on it too** (otherwise the bots run a second engine: the facsimile doc 56
  rejected). That is the largest refactor in the project for a single-digit-ms gain.
* Its one strategic benefit would be thread safety (s2: host-neutral state could be stepped on the worker pool). It is not needed to reach 34.

### 6.3 Player.gd / enemies as host-neutral rules + thin adapters?

Not now. If a later measurement (s9, after R2) shows the rules themselves are what stops 34, the **minimum useful boundary** is narrow:
Mario's motion integration only - the `Normal` state's horizontal acceleration / deceleration, gravity selection, jump and bounce rules - as a
pure function of (position, velocity, input, power-state params, floor / wall / ceiling contacts) returning the new velocity, with
`move_and_slide` and every contact staying in Godot. Both `Player.gd` and the brain's `_sim` would call it (the brain would then predict with
the game's own rules instead of a model of them, a correctness win), and the hot path would stop resolving `physics_params` by string each
frame. Enemies stay as they are (they are 7-10 % of a world). Everything else (blocks, items, flags, pipes) stays node-based.

### 6.4 Decision

**GO: optimize the current architecture.** Do not prepare a simulation/presentation split.

* The real-opponent architecture stays exactly as accepted (real scenes, real Mario, real enemies, real physics, panes = the real worlds).
* R2 is the ordered plan of s7: the low-risk local items, render cadence, load spreading and cache warming, then the shared Player hot path,
  each measured with `battle_bot_cost_audit.gd`.
* **STOP-and-reconsider criterion** (the only condition that reopens 6.2/6.3): after s7 steps 1-8, the Mac benchmark (s9) still shows
  **simulation alone > 12 ms for 34 alive worlds** on the worst early course, *and* the audit's breakdown shows the rules (state machine +
  `Player.gd` + enemies) are more than half of it. Then do 6.3's narrow motion boundary first, not a full split.
* Threads stay off the worlds (s2).

## 7. Ordered implementation plan for Hermes / Sonnet (DONE)

Rules for every step: one step per commit; behaviour-identical unless the step says otherwise; measure before and after with
`battle_bot_cost_audit.gd` (34 worlds, `course=0` and `course=1`) and record the AUDIT lines in this doc (s10); run the Battle suites of doc 57
s8 (`battle_bot_world_test`, `battle_bot_screen_test`, `battle_bot_transition_test`, `battle_send_ghost_game_test`, `battle_bot_render_test`,
and the other headless / GL suites). Gate any change to a script the real player's game also runs behind `GameWorld.is_bot(self)` first; lift
the gate for the real game only in a separate step with its own before/after test. Default build stays 0 real opponents until R3.

| Step | What | Where | Risk | Expected gain (this CPU, 34 worlds) | Proof required |
|---|---|---|---|---|---|
| 1 | **Decoration `_process` off in bot worlds**: `SignalExposer` stops processing after its first-frame setup when it has no `TrackRider` connection and is not editing; `BetterAnimatedSprite2D` processes only when `do_offset` is true (`set_process(do_offset)` in `_ready`) | `SignalExposer.gd`, `BetterAnimatedSprite.gd` (gate: `GameWorld.is_bot` for SignalExposer; the sprite change is identical for every world) | low | **1-2: -47 ms (measured, s1.7)**; 1-1: ~-4 ms | determinism traces unchanged (`battle_bot_world_test`); pixels of `battle_bot_render_test` unchanged |
| 2 | **KO'd world releases its level**: at OUT, render the pane once more, remove the level from the viewport, free it in slices over the next frames; the cell keeps the last picture (viewport no longer updated) | `BattleBotWorld._go_out`, `BattleBotDirector` | low | frozen worlds -> ~0 (today up to 2.2 ms each on 1-2); memory -6 to -28 MB per KO | KO card still over the last picture (render test); no node of the old level left after N frames; session unaffected |
| 3 | **Screen emulation with a spatial index**: notifiers bucketed by x (e.g. 64 px columns) at adoption; per tick check only buckets overlapping the camera rect +/- 1 bucket, every notifier currently on, and every notifier under a moving body (CharacterBody2D / RigidBody2D ancestor, re-bucketed when its rect changes); a full sweep every N ticks in debug builds asserting nothing was missed | `BattleBotWorld._adopt_notifier`, `_update_screen` | low (our code) | 1-2: ~-28 ms; 1-1: ~-0.6 ms | **side-by-side equivalence test**: old and new algorithm on the same worlds, identical (notifier, on/off, tick) sequences for 60 s x 8 worlds x 3 seeds on 1-1 and 1-2 |
| 4 | **Pane render cadence**: director renders each live world every 2nd frame, staggered by id; once on OUT; once while frozen; `pane_every` field (1/2/3) | `BattleBotDirector._process` | low | pane rendering halves (s3: 52 -> 31 ms here) | simulation traces identical with render on/off/every=2; render test updated to wait 2 frames |
| 5 | **Bot worlds opt out of physics interpolation** (`physics_interpolation_mode = OFF` on `BattleBotWorld`) | `BattleBotWorld._init` | low | ~-3 % of a rendered frame | traces identical (interpolation is presentation only); render test |
| 6 | **Round-start creation spread + cache warming** (s4 items 1, 2): warm `PackedScene`s and themed resources at menu / LOADING (worker + polling, never a blocking wait); create worlds with a per-frame time budget from LOADING into PRE_ROUND; assert all exist and are first-framed before PLAYING | `BattleBotDirector.start`, `BattleScreen._ensure_driver`, `BattleBotWorld.packed_scene` | low | removes the ~2.5 s single-frame stall at round start | round-start frame-time trace (no frame > budget + one world's creation); transition / ownership tests unchanged |
| 7 | **Free old level in slices at the cut** (s4 item 5) | `BattleBotWorld._swap_scene` | low | removes the free part of the cut (measure) | transition test (old level gone after N frames, new one identical) |
| 8 | **Small Battle-side per-frame items**: `BattleIncomingSpawner` early-out when its target has no incoming / spawned rows; `LevelBGNew` in bot worlds repositions only on frames the pane renders (presentation); brain: cache `_foe_nodes()` once per tick (called several times a tick today) | `BattleIncomingSpawner`, `LevelBGNew` (gated), `BattleBotController` | low | ~-2 ms (1-1), more on 1-2 | traces identical (brain: same buttons tick for tick) |
| 9 | **Block creation cheaper** (s4 item 3): `ResourceSetterNew` fast path for a cached (json, skin state); lean derived block scenes in the bot `TileSet` copies (strip `SignalExposer`+`LineDrawer`, `EditorPropertyExposer`, `TrackJoint`) | `ResourceSetterNew.gd`, `BattleBotWorld.tileset_with` + a start-up builder | medium | first frame of 1-2 230 -> ~100 ms (estimate); -25 % nodes and memory on brick courses | block parity test in a bot world (bump, break, coin, item and 1-up blocks, P-switch); render test pixels; load probe before/after |
| 10 | **Mario's hot path, behaviour-identical** (doc 56 s18 item 2): memoise `physics_params` per (type, dict, key, power state, mults) with invalidation on power-state / character / theme change; `ScalableCollisionPolygon` rebuild only when its inputs change; `handle_invincible_palette` sets shader params only on change; `handle_step_collision` writes `disabled` only on change. Gated to bot worlds first | `Player.gd`, `ScalableCollisionPolygon.gd` | **medium** (the real player's code) | Mario -30 to -40 %: ~-3 ms (1-1) | identical traces (bot) over 3 seeds x 60 s; then, ungated, the real player's movement trace from a scripted input file identical before/after |
| 11 | **Stage the next course during the clear** (s4 item 4), only if the Mac still shows a visible hitch at the cut after 6, 7, 9 | `BattleBotWorld`, `GameWorld.bot_of`, `BattlePreviewCell` | medium | the cut frame back under budget | transition test rewritten for viewport swap; ownership checks |
| 12 | **Brain planning cadence / reuse**, only if s9 shows the brain matters on the Mac: reuse the last plan while its first frames still match; plan every 6 frames instead of 3 when nothing changed; optional WorkerThreadPool for `_sim` with an in-frame join | `BattleBotController` | low-medium (behaviour changes slightly: decisions are the brain's, not the game's) | brain -50 % | A8 metrics unchanged within noise |

After steps 1-8 re-run s9 on the Mac and apply the stop/go criterion of s6.4. Steps 9-12 are ordered by expected gain per risk and are taken
only as needed. Do not start R3 (all 34 real by default) before steps 1-6 and a Mac run that holds 60 fps at round start with 34 real.

## 8. Cheap benchmarks / spikes that reduce the remaining uncertainty (DONE)

Already run in this pass (keep as regression measurements): the probe breakdown (s1), the decoration spike (s1.7), the thread spike (s2), the
separate-physics-thread run (s2), the render cadence and interpolation runs (s3), the load probe (s4), the memory runs (s5).

Still open, cheapest first; each is a few lines in an existing tool or one test:

| # | Spike | Settles | How |
|---|---|---|---|
| K1 | **The Mac run** (s9) | every absolute number; the cloud->Mac factor; whether rendering or simulation dominates there | s9 |
| K2 | Is a Rapier addon installed on the Mac build? | whether s1's physics numbers apply | first line of any s9 tool: `rapier=` / `rapier_class=`. If true there, also run with it removed (determinism and cost differ) |
| K3 | Screen-emulation index equivalence | step 3 is exact | in `battle_bot_screen_test`: run old and new `_update_screen` side by side, compare (notifier, on/off, tick) sequences |
| K4 | What the remaining ~340 us/world of "other idle" on 1-2 is, after step 1 | whether area/body query callbacks or transform notifications need work | re-run `battle_bot_cost_audit.gd course=1` after step 1; if still large, bracket `physics_frame` vs the previous frame's end |
| K5 | Freeing a 7 000-node level in one frame vs in slices | steps 2 and 7 sizes | load probe: time `level.free()` of a 1-2 level |
| K6 | Lean block scene parity | step 9 is safe | build the derived scene, play bump / break / item blocks / P-switch in a bot world, compare with the full scene |
| K7 | Render thread (`--render-thread separate`) on the Mac | whether pane rendering can overlap simulation for free | s9 C with and without |
| K8 | `pane_every` 2 vs 3 visually, on the Mac | the cadence | look at the panes during a run; the reference updates every frame, so prefer the lowest cadence that holds 60 fps |
| K9 | Brain plan reuse rate | whether step 12 is worth it | count plans whose chosen take-off equals the previous plan's (the controller already counts plans) |
| K10 | A guard against O(N²) group scans | the latent `GameWorld.group` hazard (s1.3) | a test that fails if `GameWorld.group` / `call_group` is called more than K times per frame with 8 worlds |

## 9. Target-machine benchmark (Zack's Plex Mac) - exact procedure (DONE: to be run by Hermes)

Run from the repository root on the Mac, on the branch, with Godot 4.6 (the same major/minor as this audit). Close other heavy apps; plug in
power. Record everything printed (the AUDIT / BOTBENCH / LOAD / FRAMETIME / THREADSPIKE lines) into s10 of this doc under "Mac results", plus
the machine (`sysctl -n machdep.cpu.brand_string`, `sysctl -n hw.memsize`, macOS version) and the commit.

```
GODOT=/Applications/Godot.app/Contents/MacOS/Godot      # adjust to the local Godot 4.6
$GODOT --headless --path . --import                      # once, builds .godot/ if needed

# A. CPU only: per-world breakdown, 34 worlds (headless; the engine facts are its first line)
$GODOT --headless --fixed-fps 60 --path . -s tests/tools/battle_bot_cost_audit.gd -- n=34 course=0 warm=2 window=480
$GODOT --headless --fixed-fps 60 --path . -s tests/tools/battle_bot_cost_audit.gd -- n=34 course=1 warm=2 window=300
$GODOT --headless --fixed-fps 60 --path . -s tests/tools/battle_bot_cost_audit.gd -- n=34 course=1 warm=2 window=300 spike=decor

# B. scaling (frame_ms is the wall time per frame; ignore phys_ms / proc_ms, they are per-second maxima, s1.0)
$GODOT --headless --fixed-fps 60 --path . -s tests/tools/battle_bot_bench.gd -- n=1,8,17,34 seconds=20

# C. pane rendering on the real GPU (windowed, vsync off)
$GODOT --disable-vsync --fixed-fps 60 --path . -s tests/tools/battle_bot_cost_audit.gd -- n=34 course=0 window=300 render=1 every=1
$GODOT --disable-vsync --fixed-fps 60 --path . -s tests/tools/battle_bot_cost_audit.gd -- n=34 course=0 window=300 render=1 every=2
$GODOT --disable-vsync --fixed-fps 60 --path . -s tests/tools/battle_bot_cost_audit.gd -- n=34 course=1 window=200 render=1 every=1
$GODOT --disable-vsync --fixed-fps 60 --path . --render-thread separate -s tests/tools/battle_bot_cost_audit.gd -- n=34 course=0 window=300 render=1 every=1

# D. loads and the cut
$GODOT --headless --fixed-fps 60 --path . -s tests/tools/battle_bot_load_probe.gd -- others=33

# E. the whole Battle screen as a player sees it (title -> Battle; 30 s of play), baseline then real opponents
$GODOT --disable-vsync --fixed-fps 60 --path . -s tests/tools/battle_bot_screen_frametime.gd -- --battle-real-bots=0 seconds=30
$GODOT --disable-vsync --fixed-fps 60 --path . -s tests/tools/battle_bot_screen_frametime.gd -- --battle-real-bots=8 seconds=30
$GODOT --disable-vsync --fixed-fps 60 --path . -s tests/tools/battle_bot_screen_frametime.gd -- --battle-real-bots=34 seconds=30
```

How to read it:

* **Cloud -> Mac factor** = this doc's BOTBENCH `n=34 frame_ms` (34.5-36.8 ms, s2 / doc 56) divided by the Mac's. Multiply every cloud number
  in s1-s5 by 1/factor to project.
* **Simulation budget** (A, B): 34 worlds on 1-1 headless `frame_ms` <= ~10 ms leaves room for the screen and panes at 60 fps; > 16 ms means
  steps 1-8 are required before R3 (they are planned anyway); after them, apply s6.4's stop/go criterion (> 12 ms simulation on the worst
  early course with rules > half of it).
* **Rendering** (C): `draw_ms` with every=1 vs every=2 vs the separate render thread; pane cost per pane = (draw_ms(every=1) - draw_ms of
  the empty main window) / 34. If 34 panes at every=2 cost < ~3 ms, rendering is not the problem.
* **Loads** (D, E): the first frame of 1-2 and the cut frames; target after step 6/7/9: no frame above ~50 ms at a cut; round start spread
  over PRE_ROUND with no frame above ~100 ms.
* **E** is the acceptance view of A9/A10: `phase=PLAYING p95` <= 16.7 ms and `over33.3` near 0 with 34 real opponents.

Taken twice (before step 1, and after step 8) it measures what R2 bought on the machine that matters.

## 10. Handoff state (DONE; kept current - newest facts at the end of each list)

### 10.1 The 14 audited costs, classified

| Cost (brief) | Measured (this CPU, per world-frame unless stated) | Class | Plan step |
|---|---|---|---|
| 1. `Player.gd` hot path | 50-69 us own script; `physics_params` 1.1-2.4 us x ~30 | medium-risk optimization (shared with the real player) | 10 |
| 2. player state machine | 122-143 us (`Normal`: movement + `move_and_slide`) | should not be touched (the rules); memoisation in 10 helps it | 10 |
| 3. per-world physics processing | server step 162-196 us; post 45-100 us | should not be touched (it is the physics) | - |
| 4. enemy / node counts | enemies 67-114 us; nodes 1 293 (1-1) / 7 214 (1-2), 16 per block | low-risk (lean blocks, KO release) / leave enemies | 2, 9 |
| 5. SceneTree overhead | 0.12 us per GDScript callback; ~900 decoration callbacks per 1-2 world = the cost | low-risk local optimization | 1 |
| 6. SubViewport cost | ~10 draw calls per pane; software GL 1.4-1.9 ms per pane; Mac TBD | can reduce render frequency | 4 |
| 7. rendering cadence | linear in panes per frame | can reduce render frequency (30 Hz staggered) | 4 |
| 8. pane compositing | the cell's crop of the world texture: not separable, small | leave (no compositor) | - |
| 9. world creation | 1-1 warm ~45 ms + first frame 32-50 ms; 34 in one frame today | can be amortized / staggered; cache warming | 6 |
| 10. course-transition hitch | 0.35-0.5 s single frame (block scene tiles built on the first frame) | amortize + cheaper blocks; staging if needed | 7, 9, 11 |
| 11. theme / resource setter cost | inside creation: ~0.1 ms per setter warm, cold much more; `randomize()` per resolve | low-risk cache / fast path | 6, 9 |
| 12. duplicated mutable resources | none found per frame (Mario's shapes are local-to-scene by design); per-world memory is nodes | leave; keep new copies content-keyed | - |
| 13. shareable immutable resources | already shared (scenes, textures, SpriteFrames, TileSet copies per texture set, setter caches per skin state, course maps) | cache/share (done); warm early | 6 |
| 14. bot brain / planner | 100-170 us (planning 44-97 us; 880-920 us per plan) | can be amortized; threading possible but unnecessary | 8, 12 |

### 10.2 Refactors explicitly deferred

* Simulation / presentation split of the gameplay (s6.2): not needed; reopened only by s6.4's criterion.
* Host-neutral `Player.gd` rules (s6.3): at most the narrow motion-integration boundary, and only after s6.4 says so.
* Worker-thread worlds (s2): rejected on Godot 4.6's own guards.
* Shared pane compositor (s3): rejected.
* Rapier / physics engine change: out of scope; first find out whether the Mac even has it (K2).

### 10.3 State of the repository

* **Branch** `claude/youthful-tesla-99o9hl`. Code HEAD unchanged since `b397b28` (doc 57): **this pass changed no game code.** Its commits are
  documentation and measurement tools only: `840b5d1` (skeleton), `84e4afe` (s1 + `battle_bot_cost_audit.gd`), `6b78824` (s2 +
  `battle_bot_thread_spike.gd`), `bdec3c5` (s3), `51dccd5` (s4 + `battle_bot_load_probe.gd`), `595771e` (s5, s6), `050adf5` (s7, s1.7 spike),
  `555ed25` (s8, s9 + `battle_bot_screen_frametime.gd`), and the commit adding this section. All pushed to `origin`.
* **New tools** (all under `tests/tools/`, measurement only): `battle_bot_cost_audit.gd` (probe breakdown, census, micro, memory, render,
  `spike=decor`, `interp=0`), `battle_bot_thread_spike.gd`, `battle_bot_load_probe.gd`, `battle_bot_screen_frametime.gd`.
* No temporary instrumentation left in game code; no `override.cfg` left behind (it was created and deleted for the s2 run).
* Doc 57 s11 remains the Battle status document and points here.

### 10.4 Next action for Hermes

1. Run s9 (A-E) on the Plex Mac **before changing anything**, and record the results in a "Mac results" subsection here.
2. Implement s7 step 1 (decoration `_process`), measure with `battle_bot_cost_audit.gd course=1` (expect s1.7's numbers), run the Battle
   suites, commit. Then steps 2-8 in order, one commit each, measuring each.
3. Re-run s9 after step 8 and apply s6.4.
4. Outstanding from doc 57, unchanged: Zack's physical confirmation of doc 57's two fixes (1-1 -> 1-2 real worlds; the real player's send
   ghost).

### 10.5 Mac results

(empty: to be filled by the s9 run)
