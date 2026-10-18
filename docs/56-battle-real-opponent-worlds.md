# 56 — Real opponent worlds: the architecture decision, and the vertical slice

Status: architecture decision plus a working vertical slice on top of `2480e30` (doc 55). The slice is **off by default** in this pass: a
build plays exactly as before unless `--battle-real-bots=N` (after `--`) or `SMB1R_BATTLE_REAL_BOTS=N` makes opponents 1..N play the real
game (section 14). Nothing of the accepted Battle presentation, the real player's game, the timer or coin economy, the results or SMB3 was
changed in behaviour (section 19).

## 0. The requirement, and the answer in one paragraph

Zack's requirement after physical testing: **the 34 opponents must actually be playing the game.** Not progress tracks, scripted walkers,
sketches, stand-in courses or preview simulations: if an opponent is in 2-1 its pane shows its real 2-1; it clears into the real next course;
it dies because the game killed it; an enemy sent to it changes its game. And not by running 34 full game instances.

**Decision: every opponent runs the game's own code.** An opponent's game is the real level scene of the course it is on, with its own real
Mario (`Player.tscn` and its state machine), its own enemies, blocks and items, in its own `World2D` (its own physics space), stepped by the
same SceneTree at the same physics tick as the real player's game. A brain presses the same buttons a person presses, through the same
`Global.player_action_*` calls a person's pad goes through. Everything the gameplay code used to take from process-wide state (the current
level, score, pause, sounds, the level-complete signal, the camera's static limits, the theme...) it now takes from **its own world** through
one seam, `GameWorld`, which is a pass-through for the real player's game. What is shared between worlds is only what never changes: scripts,
scenes, textures, sprite frames, tile sets, and a per-course map of solid cells. There is one process, one SceneTree, one renderer, one real
player's game and N light opponent worlds (no HUD, no audio, no menus, no transition screens; each renders only the pane's picture).
The preview pipeline of docs 36-55 (track, driver, stages, sketches, stand-ins, dice bots) becomes obsolete for every opponent that plays.

The slice proves it on the real 1-1 and 1-2 with up to 8 opponents in tests and 34 in the benchmark (sections 14-18). It also shows what it
costs, and where (section 17): the real `Player` script and real level loading are the expensive parts, both with identified causes.

## 1. Why the facsimile previews cannot meet the requirement

| Piece | What it is | Why it cannot be "the opponent playing" |
|---|---|---|
| `BattleBotSimulator` | an opponent is three numbers stepped once a second: `progress += speed x random`, a hazard roll that removes power or KOs, a power roll at each clear | the outcome is decided by dice before any picture exists; nothing in a level can kill or save it |
| `BattlePreviewTrack` | replays the session's outcomes 2 s late on a level sketch: a planned walk, no collision response ("NOT a game engine") | the picture is told what happened; it cannot be what happened |
| `BattleLevelSketch` / `BattlePreviewStages` | reads 18 of 32 levels; the walk planner, tuned on 1-1, crosses 5 cleanly; every other course is shown by a **stand-in** | after 1-1 most panes show a level the opponent is not on |
| `BattleAttackSystem.pressure` | an enemy sent to a bot multiplies its hazard roll | a sent enemy is a number, not an enemy |
| lag (doc 53) | panes run a median 3.5 s (up to 5.5 s) behind the session | a KO the pane has not reached yet is staged after the fact |

More sketch work cannot close the gap: making the previews faithful means re-implementing SMB1's rules entity by entity (Koopas, shells,
Piranhas, lifts, Lakitu, Bowser, water, pipes...) in a second engine that will always differ from the real one. That is the facsimile by
construction. The only representation that cannot diverge from the game is the game.

## 2. The architecture

```
 shared, immutable                 per opponent (BattleBotWorld)                                  observers
 ──────────────────                ────────────────────────────────────────────────────────       ─────────────────────────────
 level PackedScenes, scripts,  ──► BattleBotViewport (own World2D: physics space + canvas)    ──► pane: the world's own screen,
 textures, SpriteFrames,           └ the real level scene (Level root, TileMapLayers,               rendered by BattleBotDirector,
 TileSets (themed copies),           enemies, blocks, flag) + its real Player                       cropped 131x166 (BattlePreviewCell)
 BattleBotCourseMap (solid         per-world environment: score, coins, power, theme, time,  ──► session: progress, power, clear,
 cells of each level scene)        room, world/level, camera limit, cam lock, pipe state,          KO, kills (sends) - like the player
                                   level_complete_begin signal, freeze, screen (notifiers)    ◄── attacks: a BattleIncomingSpawner
                                          ▲ buttons                    │ state                     in its level makes them real enemies
                                   BattleBotPad ◄── BattleBotController (brain + traits) ◄──┘
                                   (Global.player_action_* reads it for player id 100+N)
```

* **`GameWorld`** (`Scripts/Classes/GameWorld.gd`): a node's world is its viewport. `bot_of(node)` is the node's `BattleBotWorld` or null.
  Every environment access the gameplay code makes goes through it: `level()`, `players()`, `first_player()`, `group()`, `call_group()`,
  `set_paused()`, `sfx()` / `music_override()` / `kill_sfx()` (silent in a bot world), `add_score()` / `add_coins()` / `add_lives()`,
  `level_complete()` / `emit_level_complete()`, `transition_to_scene()`, the camera limit / cam lock / pipe statics, the stored power state and
  character, `on_screen()`. In the real player's game each one is exactly the old expression; while no bot world exists (`bot_worlds == 0`)
  the old code path is the only one taken.
* **`BattleBotWorld`**: one opponent's game. Loads the course's real scene into its `BattleBotViewport` (256x240, the classic screen, so the
  real camera, its walls and enemy activation see the same screen as the player's game), leaves out what only presents the player's game
  (the drop-shadow renderer, Mario's on-screen timer HUD), gives Mario its pad, and runs the flow: playing; at the flagpole the slide, the
  0.27 s hold and the 6-frame fade of doc 55, then the real next course; a death (the game's) is the KO at once and the card after the
  animation; the session's time-out kills its Mario (`Player.time_up`) as BattleHandler does for the player.
* **Screen without a renderer**: a world never renders by itself. Each physics tick it works out which `VisibleOnScreenNotifier2D` /
  `VisibleOnScreenEnabler2D` are on its camera's screen and does what the renderer does in the player's game (switch the enemy on/off, send
  `screen_entered/exited`). Its simulation therefore does not depend on rendering, runs identically headless, and is deterministic.
* **`BattleBotPad`** + `Global.player_action_pressed / just_pressed / just_released`: a bot's Mario has player id `100 + contestant id`;
  those calls read its pad instead of the InputMap. "Just pressed" is true on the physics tick the button went down, like a real press.
* **`BattleBotController`** (section 6) writes the pad each tick before Mario moves (`process_physics_priority = -100`).
* **`BattleBotDirector`**: owns the round's worlds in the Battle screen, freezes them with the game window (pre-round, win hold) and the
  SceneTree's pause, stops them at ROUND_OVER, renders each world's screen for its pane every frame.

## 3. What the real game provides, reused unchanged

The whole of gameplay: `Player.gd`'s physics parameters and movement rules, the `Normal`, `Dead`, `FlagPole`, `LevelExit`, `Pipe` states,
`move_and_slide` and the physics engine, the camera handler's scrolling and walls, the death-pit rule, power-ups and damage; Goomba, Koopa,
shell, `BasicEnemyMovement`, `EnemyPlayerDetection` (stomp vs hit), Piranha plants; question blocks, bricks, coins, mushrooms; the
TileMapLayer terrain and its collision; `EndFlagpole`; every level scene as authored (one inline script in 1-2 now asks GameWorld for its
player). On the Battle side: the session's rules, the attack system and targeting, `BattleIncomingSpawner` / `BattleSpawnPlacer` /
`BattleEnemyFactory` (now aimed at any real game), the whole presentation (reticle, lines, WATCH OUT!, incoming bar, ghosts and bursts, KO
card, the freeze). Godot shares every loaded resource between instances by itself.

## 4. What had to change: the gameplay code's environment becomes per world

Each row is a process-wide thing the gameplay code reached that two simultaneous games would fight over. "Slice" = changed in this pass for
the 1-1 / 1-2 entity set; the rest is listed in section 11.

| Process-wide access | What went wrong with two games | Now | Files |
|---|---|---|---|
| `get_tree().get_nodes_in_group("Players")` | the real camera followed whichever Mario in the tree was furthest right; blocks dispensed an item per Mario in the tree | `GameWorld.players / first_player` | CameraHandler, BlockClass, PipeArea, CameraRightLimit, PiranhaPlant, BasicEnemyMovement, 1-2's inline script |
| `"StepCollision"` group | each Mario toggled **every** Mario's foot shapes (a latent multiplayer bug) | its own feet | Player |
| `call_group("Enemies", "flag_die")`, `"EntityGenerators"`, `"CastleNPCs"`, `"EndCastles"` | a bot's flag cleared the real player's screen of enemies | `GameWorld.group / call_group` | EndFlagpole, LevelExit |
| `Global.current_level` | pit line, camera limits, score notes, gibs, persistence keys all resolved to the real player's level | `GameWorld.level` | Normal, CameraHandler, ScoreNoteSpawner, GibSpawner, BlockClass, LevelPersistance, Checkpoint, LevelBGNew |
| `get_tree().paused` | a bot's death or power-up froze the whole game | `GameWorld.set_paused`: the bot freezes only its own level | Player, CameraHandler |
| `Global.level_complete_begin` | any flag released every Mario waiting on a flagpole and started every castle | the world's own signal | EndFlagpole, FlagPole, EndCastle |
| `Global.score / coins / lives / time / can_pause / can_time_tick / p_switch / death_load`, `Level.first_load / can_set_time` | bots' stomps, coins and deaths reached the real HUD; a bot in a pipe stopped the real timer | per-world counters, or left alone | Player, Coin, SpinningCoin, BrickBlock, ShellClass, SuperMushroom, EndFlagpole, EndCastle |
| `AudioManager` (sfx, music overrides, the sfx map) | bots' sounds played at the real player's coordinates, cut the player's own sounds of the same name, and switched the music (flag, death, star) | silent in a bot world | Player, Normal, WallSlide, Goomba, KoopaTroopa, ShellClass, Enemy, BlockClass, PowerUpItem, SuperMushroom, Coin, SpinningCoin, ScoreNoteSpawner, GibSpawner, EndFlagpole, PlayerMoveEffects |
| `Global.transition_to_scene` from a pipe | a bot entering a pipe would load the bonus room into the real game | the world swaps its own level | Player |
| statics: `Player.camera_right_limit`, `CameraHandler.cam_locked`, `PipeArea.exiting_pipe_id / can_enter`, `Player.pipe_cutscene`, `EndCastle.is_transitioning` | one game's camera limit, pipe exit or cutscene moved the other's | per world | CameraHandler, CameraRightLimit, PipeArea, Player, Normal, EndCastle |
| `Global.player_power_states[player_id]`, `player_characters[player_id]` | 4 slots; a bot id indexes out of range | `GameWorld.stored_power / character_index` | Player |
| `Level._enter_tree` | each bot level set `Global.current_level`, the time, the theme (re-skinning everything), the world/level numbers, the window resolution | a bot level reports to its world only | LevelClass |
| themed resources (`ResourceSetterNew`) resolved from `Global.level_theme / theme_time / room / world / level`, re-resolved on every theme change | bot worlds were skinned with the real player's theme, and re-skinned (all their setters) whenever the player changed level | a bot world's setters resolve with its own theme (its values pushed into Global's override fields for the call, then restored) and never follow the player's theme; caches are kept per theme state | ResourceSetterNew, LevelBGNew |
| `TilesetTextureSetter` retextures the TileSet **shared by every Tiles.tscn instance** | a bot underground would re-texture the real player's overworld terrain, and every retexture made every TileMapLayer in the process rebuild its block and coin tiles (0.1-2.7 s hitches, growing with live levels, section 17) | a bot world uses a themed copy per texture set (shared between bot worlds); the real game's setter only writes a texture that changed | TilesetTextureSetter |
| `LevelPersistance.active_nodes`, `Checkpoint.passed_checkpoints` | a bot's used blocks would show used in the real player's level | not recorded for bot worlds | LevelPersistance, Checkpoint |
| `WarpPipeArea` | resets the real game's values and moves the real game to another world | closed to bots in this pass (section 11) | WarpPipeArea |
| `VisibleOnScreenEnabler2D` | needs a renderer; headless or off-screen worlds never wake their enemies | worked out from the world's camera each tick | BattleBotWorld, Enemy (`flag_die`) |
| input | `Input.is_action_pressed("jump_" + id)` | the bot's pad for ids 100+ | Global, Player (fireball angle) |
| Battle: kill attribution, sends, incoming | every native kill counted as the real player's; incoming enemies existed only in the player's level | a kill reports the world's contestant; the spawner serves any real game (`target`); the session treats world-driven opponents like the player (no dice, no timer expiry, real outcomes) | Enemy, BattleSession, BattleAttackSystem, BattleIncomingSpawner, BattleContestant |

35 game files, nearly all one- or two-line substitutions. Two of them fix real bugs that affect the real player's game today: the
StepCollision group and the shared-TileSet retexturing.

## 5. Components that become obsolete

For every opponent that plays a real game: `BattleBotSimulator` (dice), `BattlePreviewTrack`, `BattlePreviewDriver`, `BattlePreviewStages`
(stand-ins), `BattleLevelSketch`, `BattlePreviewFrame`, `BattleMiniGameRenderer`, `BattlePreviewInvader`, the placeholder renderer, the
session's `pressure`, and the 2 s presentation lag. In this pass they stay for the opponents that do not play yet (all 34 by default; 3..34
with `--battle-real-bots=2`), and are deleted when all 34 play (section 13, milestone R3). Kept, as rendering infrastructure only:
`BattlePreviewAtlas` and `BattlePreviewCell` (a cell now draws its world's screen) and `BattleOpponentPane`. `BattlePreviewAssets` keeps
only the enemy art the attack presentation draws (icons, ghosts).

## 6. The brain (`BattleBotController`, `BattleBotTraits`)

It reads its own game (Mario's real position, velocity, floor contact, state and power; the course map; the world's awake enemies) and
writes buttons. It never moves Mario.

* **Default**: hold right; run or walk by its pace (traits); occasional short stops; stop under a `?` block it wants and hit it.
* **Planning** when something is near (a step or wall, a gap, a drop, an enemy): it plays candidate button plans forward 64 frames with
  `_sim`, a model of Mario's own movement built from the real Mario's parameters (`physics_params`: jump speed by run speed, jump and fall
  gravity, the jump-release divide, ground and air accelerations, deceleration, max fall, bounce speed) against the course map and the
  enemies' current motion. Plans: carry on; take off after its reaction time, 5 or 10 frames later; a hop or a full jump. Each is scored
  (distance, death = rejected, stuck against a wall, in the air over nothing at the end, stomps for a stomper) and jump is pressed only when
  the best plan's take-off is now. With nothing safe it stops, or backs off from an enemy.
* **In the air** it holds jump as planned; coming down by an enemy or onto the edge of a gap or a step it presses jump again inside the
  game's jump buffer, so the game jumps on landing (and holding jump on a stomp gives the high bounce).
* **Recovery**: no progress for `patience` frames: a jump; three in a row: back off for a run-up.
* **Traits** (stable per round: the round seed and the contestant id; `skill` is the session's own draw): reaction 2-9 frames, timing jitter
  (precision), run share, hesitation at gaps (braking-aware), stomp bias, block interest, idle rate, patience. Everything random comes from
  the bot's own stream: no global RNG, no other world's draws.

Behaviour measured on the reference (the table below; the slice's bots against it in section 16) is the calibration target, not a script:
no trajectory is copied.

| Reference opponents (doc 56 measurement) | Value |
|---|---|
| pane update | every 60 fps frame, all panes on the same frames |
| pane picture | a **1:1 crop** of the opponent's screen, 131 x 166 game px (rows 66-231), Mario at about x 90 while scrolling |
| speed (Mario's own) | still 34 %, slow 18 %, walk 25 %, run 17 %, moving left 6 %; mean 48 px/s |
| camera stills | median 1.3 s; 3.7 stills of 2 s+ per pane-minute (mostly hitting blocks, waiting on platforms) |
| jumps | 0.45 per second; median airtime 0.83 s; 64 % at least 3 blocks high |
| first course | 20 of 34 cleared it; median 55 s (45-64 s), fastest 33 s; later courses median 53 s |
| KOs (opponents out) | 10 by 35 s into the match, 20 by 95 s, 26 by 195 s, 33 by 495 s; 41 % before finishing course 1 |
| other | many play as Fire Mario and shoot; they take warp zones (5 of 8 that reached 1-2) |

## 7. Mutable state per opponent

The level instance (its node tree, physics bodies, the TileMapLayer's own cell data and block nodes), its Mario, its enemies and items, its
camera; and in `BattleBotWorld`: course, scene, phase, fade, death record, power carried between courses, score, coins, theme / time / room /
world / level, camera right limit, cam lock, pipe exit id and pipe permission, freeze, the screen state of each notifier, its enemy list; the
pad's buttons; the brain's state and random stream; the session's row (`world_driven`, progress, power, clears, KO) and its attack queue;
its incoming spawner.

## 8. Shared, immutable

Scripts; level `PackedScene`s (`BattleBotWorld.packed_scene` caches one per path for all worlds); textures, `SpriteFrames`, materials,
audio (unused); `TileSet`s (the real one for the real player's game; one themed copy per texture set for all bot worlds);
`ResourceSetterNew`'s resolved resources (per theme state); `BattleBotCourseMap` per level scene (solid cells, `?` blocks, side pipes).

## 9. Rendering

The pane shows the world's **own screen**: its `BattleBotViewport` is rendered by `BattleBotDirector` (`UPDATE_ONCE` every frame, as the
reference updates every pane every frame) and the atlas cell draws the measured 131 x 166 crop of it, which the pane then downsamples as
before. It is the real sprites, the real palette shader, the real tiles and background of that world, never a sketch. Notifiers in a bot world
are hidden so rendering can never change its simulation. Cost and the cheaper alternative (attaching each world's canvas to the one atlas
viewport, one render pass) are in section 17. Rendering every pane every frame is a presentation choice that can be decimated without
touching any game.

## 10. Synchronisation with the session and the attack system

* The session's 1 Hz clock is unchanged. A world-driven contestant (`BattleContestant.world_driven`, set by `BattleBotDirector.configure`
  in `BattleHandler.start_match` before the first tick) is stepped like the real player: its timer runs, nothing is rolled. Its game reports
  `report_bot_progress` (every tick, from its start to its flagpole), `report_bot_power` (HIT / POWER_UP), `report_bot_level_complete`
  (at the cut), `report_ko` (at the death).
* Kills: `Enemy.report_battle_defeat` reports the contestant of the world the enemy died in. A kill by that world's Mario is its defeat and
  sends like the player's, its target pick drawn from a stream of its own (`BattleAttackSystem.rng_for`), so the simulated bots' fixed-rate
  stream is untouched.
* Incoming: an attack on a world-driven opponent never expires by timer; it waits ACTIVE until its game resolves it, exactly as for the real
  player. The world's own `BattleIncomingSpawner` (target = its id) spawns the real enemy at a safe spot of its screen, and its fate
  (stomped, pit, left behind) resolves it; leaving a level resolves the spawned ones (LEVEL_TRANSITION).
* Freeze and pause: worlds run while the game window runs (frozen through the pre-round and a win hold), pause with the SceneTree (the
  pause menu, and the real player's death or power-up freeze - the same rule as the session's clock), and stop where they are at ROUND_OVER.
  KO cards come after the death animation, with no presentation lag.

## 11. Complexity and risk

| Risk | Where it stands | What it takes |
|---|---|---|
| **Coverage of the remaining entities** | the seam is in the code reached on 1-1 and 1-2 (Goomba, Koopa, shell, Piranha, blocks, coins, mushroom, flag, pipes) | the same substitutions in the rest: CastleBridge / Bowser and the X-4 castles, Lakitu / Spiny, Hammer Bros, Bullet Bill cannons, Cheep Cheeps, Blooper, Podoboo, fire bars, lifts and platforms, springboards, vines, water, warp zones, coin heavens, `PipeCutscene`. The inventory: 90 `"Players"` group lookups in 35 files, 89 `Global.current_level` reads in 45 files, ~250 `AudioManager` calls in 118 files (most outside gameplay), 193 statics. Mechanical, but every file must be read |
| **CPU** | section 17 | the real `Player` script is most of a world's cost; measured hot spots below |
| **Level loading** | section 17 | a cold `ResourceSetterNew` resolve per node; 1-2 has 426 brick nodes |
| **Determinism** | tested: same seed, same game, tick for tick; a world plays identically with or without others | entities that use the global RNG (`pick_random`, `randf`: Lakitu, Hammer Bros, Bowser) need a per-world RNG; `ResourceSetterNew` calls `randomize()` on every resolve |
| **Brain quality** | plays 1-1 through and into 1-2; faster, jumpier and more often dead in pits than the reference's people (section 16) | calibration (idling, block hunting, pit judgement); 1-2's lifts and Koopas, all other courses, power-ups (fire), warp zones, coin hunting, reacting to sent enemies specifically |
| **Physics fidelity of the brain's model** | the model only chooses buttons; Mario still moves by the real physics | a wrong prediction is a real mistake, never a cheat |

## 12. Vertical-slice plan (built)

1. The seam and the per-world environment for the 1-1 / 1-2 entity set.
2. `BattleBotWorld` + pad + screen emulation; the real 1-1 loads, Mario moves by the real physics.
3. The brain (planning, traits).
4. Death, flag clear, the cut into the real next course (1-2, its real scene and theme).
5. Session integration (world-driven contestants), kills that send, attacks that spawn into a bot world.
6. Battle screen wiring behind a flag; panes show the worlds' screens.
7. Tests, the benchmark, this document.

## 13. Acceptance criteria, and the plan from here

| # | Criterion | Measured by | Slice |
|---|---|---|---|
| A1 | an opponent's pane is its own real game's screen (no sketch, no stand-in) | `battle_bot_render_test`, `battle_bot_screen_test` | met for opponents with a world |
| A2 | its Mario moves only by real physics from pad buttons | `battle_bot_world_test` (pad, trace) | met |
| A3 | deaths are the game's (enemy, pit, time-out), the KO is immediate, the card follows the animation | `battle_bot_world_test` | met |
| A4 | a flagpole clear is a LEVEL_CLEAR and the world enters the real next course | `battle_bot_world_test` | met for 1-1 -> 1-2 |
| A5 | an opponent's stomp sends; an enemy sent to it is a real enemy in its level | `battle_bot_world_test` | met |
| A6 | worlds are independent and deterministic | `battle_bot_world_test` (identical traces alone / with others / rerun) | met |
| A7 | the real player's game, its HUD, audio and every accepted presentation are unchanged | all existing suites; isolation checks | met (section 19) |
| A8 | competence: clears / KOs / course times within the reference's ranges | metrics over seeds (section 16) | not yet: 1-1 is cleared about as often, but twice as fast and with nearly twice the early KOs |
| A9 | 34 worlds hold 60 fps on the target machine | `battle_bot_bench` | not yet (section 17) |
| A10 | every course loads without a visible hitch | `battle_bot_bench` (transition load) | not yet (section 17) |

Milestones: **R1** the seam for the remaining entity set (section 11), with a per-world RNG; **R2** performance (section 17's list) until
A9 / A10 hold; **R3** all 34 opponents play by default, the preview pipeline is deleted; **R4** the brain on every course and calibrated to
the reference (A8), including power-ups, warp zones and coins (with the coin economy, when that pass comes).

## 14. What the slice implements

| File | What it is |
|---|---|
| `Scripts/Classes/GameWorld.gd` | the seam (section 2): a node's world, and every environment access of the gameplay code, per world |
| `Battle/BattleBotWorld.gd` | one opponent's game: loads and swaps its real level scenes, runs the flow (play, flag, hold, fade, cut; death, KO, card; time-out), owns the per-world environment and theme context, emulates its screen, reports to the session |
| `Battle/BattleBotViewport.gd` | its `SubViewport`: 256 x 240, its own `World2D`, no 3D, no audio listener, never renders by itself |
| `Battle/BattleBotPad.gd` | the virtual pad `Global.player_action_*` reads for player ids 100+ |
| `Battle/BattleBotController.gd`, `BattleBotTraits.gd` | the brain and its seeded traits (section 6) |
| `Battle/BattleBotCourseMap.gd` | the solid cells, `?` blocks and side pipes of a level scene, built once per scene and shared |
| `Battle/BattleBotDirector.gd` | the round's worlds in the Battle screen: creation, freeze / pause / stop with the game window, a screen render per frame |
| the 35 game files of section 4; `BattleSession`, `BattleAttackSystem`, `BattleIncomingSpawner`, `BattleContestant`, `BattleHandler`, `BattleScreen`, `BattlePreviewCell` | the seam's call sites; world-driven contestants; attacks on any real game; the pane drawing a world's screen |
| `tests/battle_bot_world_test.gd`, `battle_bot_screen_test.gd`, `battle_bot_render_test.gd`, `tests/tools/battle_bot_bench.gd` | section 19 |

**Turning it on.** `godot --path . -- --battle-real-bots=N` (or `SMB1R_BATTLE_REAL_BOTS=N`; since doc 57 also without the `--`, which this
pass silently read as 0): in Battle, opponents 1..N play the real game
from 1-1 and their panes show it; 0 (the default) is the build of `2480e30` exactly - no world, no pad, `GameWorld.bot_worlds == 0`, every
seam call the old expression. N = 34 runs, at the cost of section 17.

**Not in the slice** (section 11): entities beyond the 1-1 / 1-2 set (an opponent that reaches a course with Lakitu, lifts, castles... meets
code that still reaches the real player's game: not safe yet, hence off by default), warp zones (closed to bots), the brain beyond 1-1 / 1-2,
fire, the performance work of R2.

## 15. The real course transition, demonstrated

`battle_bot_world_test` runs 8 opponents on the real 1-1 (attacks off, so the only question is the course): within 75 s one has reached the
flag; its Mario rode the real flagpole (the game's `FlagPole` state, the `EndFlagpole` slide), the world's flow ran the 0.27 s hold and
the 6-frame fade of doc 55, and at the cut: the session logged its `LEVEL_CLEAR` (1 course), the world's level is the real
`World1/1-2.tscn`, a fresh real Mario stands in it, 1-2 is skinned as its own underground level (not as the real player's overworld), and the bot plays on in it (x -208 ->
189 from the entrance). The real player's level, level number and score are untouched. The render test shows the fade blackening the cell;
the cell shows the new course after the cut because it is that world's screen.

In the benchmark (8 opponents, seed 11, 45 s): 5 opponents cleared 1-1 and entered 1-2. Only 1-1 -> 1-2 is demonstrated: 1-2's
exit pipe to its outdoor end, and everything after, need the R1 entity set.

## 16. Bot behaviour, demonstrated and measured

What the tests show: Mario moves only from pad buttons by the real physics (860 px in 6 s; 7 jump presses and 339 frames of run); enemies
wake as the bot's camera reaches them and not before; the game's own collision kills it (a Goomba, at x 72, tick 133) and the
game's own pit rule (`Normal.handle_death_pits`); a real stomp in bot 1's game sends to bot 2, where the enemy appears in bot 2's level by bot
2's own spawner; the same seed plays tick for tick the same, alone or beside other worlds, and another seed plays differently.

Measured against the reference (section 6) over 32 opponents: 8 worlds x seeds 7, 11, 23, 31, 60 s each, attacks on (the 26 dice
opponents send too), 1-1 then 1-2. Speed classes are Mario's own `velocity.x` while in the Normal state: still < 6 px/s, slow < 60, walk <
105, run above; left < -5.

| Measure | Reference (people) | Slice bots |
|---|---|---|
| still / slow / walk / run / left | 34 / 18 / 25 / 17 / 6 % | 20 / 15 / 34 / 29 / 2.5 % |
| take-offs per second | 0.45 | 1.04 (stomp bounces included) |
| airtime | median 0.83 s | mean 0.68 s (airborne 71 % of the time) |
| first course cleared | 20 / 34 (59 %), median 55 s (45-64), fastest 33 s | 16 / 32 (50 %) within 60 s, in 22-35 s (median 26 s) |
| KO'd by 35 s | 10 / 34 (29 %) | 16 / 32 (50 %); 18 within 60 s |
| causes | - | pit 12, Goomba 3, Green Koopa 1, an unnamed runtime-spawned body (a kicked shell or a sent enemy) 2 |

Reading it: the bots play the real course to the flag about as often as the reference's people, but like confident speedrunners - they rarely
stand, run more, jump twice as often, clear 1-1 in half the time, and are KO'd early nearly twice as often (50 % against 29 % by
35 s), mostly in pits. The reference's people hunt blocks, wait on platforms (3.7 stills of 2 s+ a minute) and play Fire Mario. A8 is not met;
the levers are traits that exist (idle rate, block interest, hesitation, stomp bias) plus pit judgement, and the work is calibration
(milestone R4), not architecture. Every one of those deaths and clears is the game's own outcome.

## 17. Benchmark results

All measured in this container: 4 vCPU Intel Xeon @ 2.1 GHz, Godot 4.6, no GPU (GL runs on a software rasteriser under xvfb).
`battle_bot_bench` adds N worlds on 1-1 to a bare SceneTree and plays them (the dice opponents' sends off, so no enemy arrives at random);
frame time is the wall time of each 1/60 s frame, which with `--fixed-fps` is pure CPU.

Headless, seed 7, 20 s:

| N | frame ms | per world | worst frame ms | brain ms / world | memory MB (per world) | nodes | create ms (first frame ms) |
|---|---|---|---|---|---|---|---|
| 1 | 1.24 | 1.10 | 6.6 | 0.144 | 26.5 (the shared resources load with the first) | 1 294 | 401 (71) |
| 2 | 2.29 | 1.08 | 7.0 | 0.176 | 11.9 (5.96) | 2 588 | 90 (64) |
| 4 | 3.85 | 0.93 | 10.1 | 0.188 | 24.3 (6.08) | 5 176 | 135 (138) |
| 8 | 7.56 | 0.93 | 18.3 | 0.180 | 49.2 (6.15) | 10 352 | 284 (286) |
| 16 | 15.39 | 0.95 | 35.8 | 0.192 | 97.4 (6.09) | 20 704 | 569 (578) |
| 34 | 36.77 | 1.08 | 71.0 | 0.215 | 209.4 (6.16) | 43 996 | 1 245 (1 257) |

Cost is linear: about 1 ms of CPU per world per frame, 6.2 MB and 1 294 nodes per world. A plan (6-7 simulated button plans of 64 frames)
takes 1.05-1.19 ms; the brain averages 0.2 ms per world-frame because it plans every 3 frames, and only near something.

Where a world's frame goes (profiled on 1-1, before the brain existed): the real `Player` is 0.36-0.43 ms of it (its state machine's
`Normal.handle_movement` 65 us, `handle_animations` + `get_animation_name` 24 us, the script's own `_physics_process` 36 us, about 30
`physics_params` lookups a frame at 2.3-2.7 us each - string scans - and a `ScalableCollisionPolygon` rebuilt every frame); the rest of the
level (enemies, blocks, camera, physics) 0.14 ms. Memoising `physics_params` and skipping unchanged polygon rebuilds took the Player from
0.42 to 0.36 ms with no change of behaviour (the patch was measured and reverted from this pass: it is the real player's hot path and belongs
in R2 with its own tests).

Course transitions (8 worlds, seed 11, 45 s, 5 transitions to 1-2): the swap itself (free 1-1, instance 1-2, theme it) takes up to 230 ms,
and the worst frame of the run, at a transition, took 793 ms: the swap plus 1-2's first frame in the tree (its 426 brick nodes setting
up their themed resources cold, section 11). Before the shared-TileSet fix of section 4 the same transition cost 0.1-2.7 s, growing with
every live level.

Rendering (GL compatibility renderer on the software rasteriser, 10 s; the same process without rendering for comparison):

| N | frame ms, simulation only | frame ms, + each world's screen rendered | rendering per world |
|---|---|---|---|
| 0 (process baseline) | 4.6-4.8 | - | - |
| 4 | 8.82 | 15.67 (worst 26.0) | 1.71 ms |
| 34 | 43.27 | 98.65 (worst 167.4) | 1.63 ms |

The whole Battle screen (the real player's 1-1, the HUD, 34 panes and the atlas, 1920 x 1080), 10 s into the round, with N opponents on
real worlds and the rest on the doc 36-55 previews:

| N real | frame ms | worst | physics ms | memory MB | nodes |
|---|---|---|---|---|---|
| 0 (the build of `2480e30`) | 66.1 | 99.8 | 1.9 | 155 | 7 990 |
| 4 | 73.9 | 122.3 | 7.8 | 185 | 13 054 |
| 34 | 140.3 | 191.3 | 38.8 | 377 | 51 381 (27 worlds still alive) |

On this machine even the existing build runs at 15 fps, because the software rasteriser draws the 1080p screen: the absolute frame times here
say nothing about a GPU machine. What carries over is the difference: replacing all 34 previews by real worlds adds 74 ms of this CPU per
frame (2.2 ms per opponent: its simulation, about 1.1 ms, and its screen's render pass and cell draw, the rest), 222 MB and 43 000 nodes. The
cell itself is one cropped texture draw into the existing atlas; it was not separable from the world's render pass in this measurement.

## 18. Projection for 34 opponents

On this CPU, 34 real worlds cost **37 ms of simulation per frame** (one thread) against a 16.7 ms frame, before the real player's game and
the Battle screen (in the whole screen they add 74 ms, their render passes on the software rasteriser included), plus a 2.5 s start
(creation + first frame) and up to 0.8 s hitches at course changes. Memory (210-220 MB) is fine. It is not
prohibitive - nothing in it grows faster than linearly, and the costs have known causes - but it is about **4x** away from 34 at 60 fps on
this machine (the target machine was not measured here; a current desktop core is likely faster than this cloud Xeon, which would narrow it, but the
plan should not rely on it). KOs help only after the fact (an OUT world is frozen and costs almost nothing; the reference has 10 out by 35 s,
20 by 95 s): the start of the round, with all 34 alive, is the frame that must hold.

The minimum work to get there (R2), in order of what it buys, none of it a change of rules:

1. **Run the worlds in parallel.** They share no mutable state by construction (that is what `GameWorld` is), so Godot 4's processing
   thread groups (`process_thread_group = SUB_THREAD` per world) can run their scripts on the worker pool: up to ~3x on 4 cores. To verify
   first: `move_and_slide` and area queries from worker threads against the 2D physics server (`physics/2d/run_on_separate_thread`), and
   the few remaining process-wide writes (section 11's statics).
2. **The Player's hot path**, identical rules: memoise `physics_params` per frame, rebuild collision polygons only on change (measured -14 %),
   skip presentation work (animation name resolution, palette, move effects) on frames whose pane is not drawn. Target: 0.2 ms.
3. **The brain**: reuse the previous plan while it holds, simulate in 2-frame steps, reject early. Target: under 0.07 ms per world-frame.
4. **Loading**: build the next course during the flag slide and hold (from the touch to the cut), time-sliced across frames, and give
   `ResourceSetterNew` a fast path for an already-resolved state; create the round's worlds during the pre-round (A10).
5. **Rendering**: one canvas pass for all panes (each world's canvas attached to the atlas viewport, cropped by transform) instead of 34
   viewport passes; or render panes at 30 Hz - a presentation choice that never touches a game.

If 1-3 together still miss, the next step is still exact, not an approximation: a bot-world variant of `Player.tscn` without its presentation
children, which needs `Player.gd`'s rules split from its presentation (a substantial refactor of a 1 778-line script, which is why it is last).

## 19. Tests

| Suite | Result |
|---|---|
| `battle_bot_world_test` (headless, new) | 41 / 41 |
| `battle_bot_screen_test` (headless, new) | 18 / 18 |
| `battle_bot_render_test` (GL, new) | 5 / 5 |
| the 19 existing headless suites (arrival, attack x4, hud, incoming x3, preview x3, round x2, screen, send ghost, session, targeting, ui) | 1 875 / 1 875 |
| the 5 existing GL suites (arrival, attack, incoming, preview, screen render) | 200 / 200 |

Two findings while testing, neither caused by this pass: `battle_attack_screen_test` fails one of its 131 checks about one run in three on
`2480e30` too (an unseeded round; with a fixed seed the outputs of `2480e30` and this pass are identical, 131 / 131), and a stomped Goomba
emits `killed("Hello")` which `GibSpawner.summon_gib` cannot convert (a script error on `2480e30` as well). Neither is fixed here.

## 20. Commit

The commit that adds this document, on `claude/youthful-tesla-99o9hl` over `2480e30`.
