# 36 — Battle Mode: Opponent Preview Architecture

Status: proposal, written against `881e42b`. Nothing here is implemented yet.

Goal: each of the 34 opponent windows should look like a tiny live Mario run, like
Super Mario Bros. 35. It should do that without hidden game copies, without `Player` nodes
and without level scene trees. `BattleSession` stays the only simulation.

---

## 1. What the repository gives us (observed)

| Fact | Where | Consequence |
|---|---|---|
| Bots are stepped numbers at 1 Hz: `progress` (0..1), `levels_cleared`, `power` (0/1/2), `alive`, `ko_cause`, `time_left` | `BattleBotSimulator.step_bot`, `BattleContestant` | The session decides outcomes but not motion. Everything between ticks must be made up by the preview. |
| The real player's progress is `(x - start_x) / (goal_x - start_x)`, with the goal being the `EndFlagpole` or `CastleBridge` | `BattleHandler._report_progress` | Bot progress can mean the same thing. A bot's world x is `start_x + progress * (goal_x - start_x)` in the real level. |
| Level geometry is a `TileMapLayer` override `tile_map_data` (format 0, 12 bytes per cell: `int16 x, int16 y, u16 source, u16 atlas_x, u16 atlas_y, u16 alt`) on the `Tiles` / `DecoTiles` instance nodes of each level `.tscn` | `Scenes/Levels/SMB1/World*/*.tscn` | It can be read from `PackedScene.get_state()` (SceneState) **without instantiating the level**. Checked by decoding 1-1: 825 cells, x −17..207, pits at tile columns 53–54, 70–72 and 137–138. Those match the real 1-1. |
| Enemies, blocks, the flagpole, the castle and the player start are instanced child nodes with a `position` override (1-1: 16 Goombas, 1 Green Koopa, flagpole at x=2920, castle at 3016) | same | The enemy list, the goal and the start come straight from SceneState. |
| Theme, time and campaign are exported on the level root (`theme = "Underground"` in 1-2) | `LevelClass.gd` | Each bot's level carries its own theme. |
| Tileset: source 0 = terrain atlas (16 px cells), 1 = scene tiles (bricks/?-blocks), 2 = liquid, 3 = deco, 4/5 = conveyors. Textures are swapped in by `ResourceSetterNew` from JSON (`TerrainTiles.json`, …) per theme/campaign/resource pack. | `Scenes/Parts/Tiles.tscn` | Atlas coordinates in the cell data map directly onto the themed terrain PNG. |
| `ResourceSetterNew` picks the variant from **globals** (`Global.level_theme`, `theme_time`, `current_campaign`, `theme_override`). Its cache is keyed by JSON path only, and `force_properties` bypasses the cache. | `ResourceSetterNew.gd` | It cannot be pointed at "the Underground goomba" while the player is in 1-1 without mutating globals. The preview needs an explicit-theme resolver. |
| Sprite JSONs give the frame rects and animation speeds (`Goomba.json` Walk/Stomped; Mario `Small/Big/Fire.json` Idle/Move/Skid/Jump/Climb/Die/Grow/Swim…) | `Assets/Sprites/**.json` | The real animations can be reused frame by frame. |
| Stretch mode is `viewport`, and Battle forces 426×240. Cells are `floor(79/3)=26` × `floor(26/0.7818)=33` **framebuffer pixels**. The current surface maps a 240-tall logical view into them (scale ≈ 0.1375). | `project.godot`, `BattleHudLayout` | See risk R1. At default settings a 16 px Mario is about 2 px tall. The reference's cells (1080p) have about 20× more pixels. |
| The game already supports `CONTENT_SCALE_MODE_CANVAS_ITEMS` as a user "visuals" option | `WindowChanger.visuals_changed` | In that mode the same cells render at window resolution, with no code change in the preview. |

## 2. Core idea

> **The session decides *what happens*. The preview decides *how it looks*. The preview reads
> real level data, runs about 2 s behind the session, and so always knows the next outcome
> before it has to animate it.**

Four layers, with one-way data flow:

```
BattleSession (authoritative, 1 Hz)            unchanged rules + additive event log
      │ snapshots + events (per tick)
      ▼
BattlePreviewDriver (in BattleHud)             34 BattlePreviewTracks, fixed 30 Hz in session time
      │ reads shared, immutable
      ├── BattleLevelSketch (per level)        tiles → surfaces/pits/jumps, enemy spawns, goal, theme
      └── BattlePreviewAssets (per match)      themed strip textures + mini sprite frames
      │ BattlePreviewFrame (plain data)
      ▼
BattlePreviewSurface → BattleMiniGameRenderer  draw: 1 strip region + ≤10 sprites + overlays
```

Nothing below the session writes back into it. The preview owns no RNG that the session uses,
holds no nodes besides the 34 existing surfaces, and loads no level scene into the tree.

## 3. Authoritative vs derived state

### Authoritative (BattleSession, unchanged meaning)
`alive`, `ko_tick`, `ko_cause`, `levels_cleared` (course index), `progress`, `power`,
`time_left`, placements. Later also: kill counts, sent/received enemy queues, targets.

### New, still authoritative, additive: a per-tick event log
`BattleSession.step()` already sees every change. It records events by diffing each
contestant before and after `step_bot`, **without touching `rng`**, so existing seeds give
identical matches:

| Event | Emitted when | Data |
|---|---|---|
| `HIT` | `power` decreased without a KO | new power |
| `POWER_UP` | `power` increased | new power |
| `LEVEL_CLEAR` | `levels_cleared` increased | new course index |
| `KO` | contestant knocked out | cause |
| later `SENT` / `RECEIVED` | attack system | count, kinds, other contestant |

Storage: `session.events: Array` of small packed records `{tick, id, type, a, b}`, trimmed to
the last N ticks (the preview only needs the last ~3), or a `last_tick_events` array that the
driver consumes once per tick. Either is a few hundred bytes.

`BattleContestant` itself gains nothing that is visual-only.

### Derived (preview, never read by the session)
Mario's visual x/y, pose, animation frame, facing; camera x; active enemy instances and their
states; death/flag/transition phase; which course is *displayed*, which can trail the
authoritative course by up to the lag.

## 4. Components

All new code goes under `Scripts/Classes/Battle/`. No autoloads, and nothing outside Battle
changes except one shared goal-finding helper (see 4.1).

### 4.1 `BattleCourse` (static, pure)
- `scene_path(course_index) -> String`, the SMB1 order: course `i` → world `1 + i/4`, level
  `1 + i%4` → `res://Scenes/Levels/SMB1/World{w}/{w}-{l}.tscn`. Wraps or stops after 8-4,
  following whatever the player's own Battle progression does. The player and the bots must
  use the same mapping. The surface's `world_level_text()` moves here.
- `find_goal(...)`: the EndFlagpole/CastleBridge rule that `BattleHandler` uses today. It is
  factored out so player progress and bot progress share one definition.

### 4.2 `BattleLevelSketch` (RefCounted, immutable, shared by every bot on that level)
Built by `BattleLevelSketch.load(scene_path)` from `PackedScene.get_state()` only:

- `theme`, `theme_time`, `campaign` (root node properties).
- `bounds` (tile range); `top_y = vertical_height` (−208) through 32. This is the band the
  real camera shows.
- `solid: PackedByteArray` (one byte per tile, `w*h`, ~3.4 KB for 1-1) from `Tiles`
  source 0 plus the scene tiles that are solid (bricks, ?-blocks), plus block **nodes**
  (`QuestionBlock`, `BrickBlock`, …).
- `cells`: the raw decoded cells (source, atlas coord), kept only until the strip is baked.
- `route`: a precomputed walk line over the level. For each tile column, the standable surface
  Mario uses, chosen by a greedy left-to-right pass that prefers the surface nearest the
  current height within jump reach (this handles 1-3's floating platforms and stairs). Plus
  `jumps: Array` of `{x0, x1, apex}` wherever the route rises, drops more than 2 tiles, or
  crosses a gap. Plus `pits: Array` of tile ranges with no surface.
- `spawns: Array` of `{kind, x, y}` for known entity scenes (`Goomba`, `GreenKoopaTroopa`,
  `RedKoopaTroopa`, `BuzzyBeetle`, `PiranhaPlant`, …), mapped by instance `resource_path`.
  Unknown kinds are dropped, so new content degrades instead of breaking. The
  `ChallengeModeNodes` subtree is skipped.
- `start_x` (the `Player` node), `goal_x` and `goal_kind` (flag / bridge), `castle_x`.

It is pure data. It can be tested headless and costs roughly 10–50 KB per level.

### 4.3 `BattlePreviewAssets` (RefCounted, owned by BattleHud, lives for the match)
- **Explicit-theme resolution.** `resolve(json_path, theme, time, campaign) -> {texture,
  rect, animations}`. It applies the same resource-pack precedence as `ResourceSetterNew`
  (`get_resource_pack_path` over `Settings.file.visuals.resource_packs`) and walks the JSON
  `variations` with the *given* theme/time/campaign instead of globals. Try a detached
  `ResourceSetterNew` with `force_properties` first; keep a small dedicated resolver as the
  fallback (see R3).
- **Strip bake.** One **opaque, mipmapped** `ImageTexture` per level, holding the whole level
  at logical resolution (1-1 is about 3600×240): sky colour, background hills/bushes/clouds
  from the LevelBG textures for that theme (tiled without parallax), terrain/deco atlas cells
  copied with `Image.blit_rect`, blocks, pipes, the flagpole and the castle. Baked once per
  level and shared by all bots on it, with an LRU of about 4 levels.
- **Mini sprites.** Every Mario/enemy frame the renderer can draw is copied out of its sheet into
  its own small `ImageTexture` **with mipmaps**: Mario Small/Big/Fire × Idle/Move/Jump/Skid/
  Climb/Die/Grow/Swim, plus Goomba/Koopa/shell/Piranha/… for that theme. There are about 100
  textures, each 16×16 or 16×32.

Mipmaps are the point. Drawing at about 0.14× with `TEXTURE_FILTER_LINEAR_WITH_MIPMAPS`
on the surface gives a stable, readable thumbnail that scrolls without shimmer. Drawing raw
16 px tiles with the project's nearest filter at that scale aliases badly.

### 4.4 `BattlePreviewTrack` (RefCounted, one per bot): the only "game-like" code
A small state machine in session time, stepped at a fixed 30 Hz. It is not an engine.

Inputs: a queue of keyframes `{tick, course, progress, power, alive}` plus that tick's events.
Shared `sketch`, plus its own `RandomNumberGenerator` seeded from
`hash(session.seed, id, course)`.

State: `phase ∈ {RUN, HIT_BLINK, DYING, KO, FLAG, CASTLE, TRANSITION}`; Mario `{x, y, vx,
air_t, anim, frame, facing, power, blink}`; `camera_x`; `enemies: Array` (only the active
ones, at most about 8); `displayed_course`.

Rules (the whole "physics"):
1. **Target.** `target_x(t)` = linear interpolation between the lagged keyframes, mapped
   through `start_x + p*(goal_x - start_x)`. `LAG = 2` ticks.
2. **Follower.** Mario steers toward the target with an acceleration limit and walk/run speed
   caps. If he falls more than about 1 screen behind (high `sim_speed`, or a stall), he snaps.
   Animation fps scales with |vx|. Skid when the target is reached and he stops.
3. **Ground and jumps.** `y` comes from `sketch.route`. Reaching a `jumps` entry starts a timed
   parabolic arc, and he keeps at least walking speed while airborne. He can never be over a
   pit except mid-arc or while dying.
4. **Enemies.** A spawn activates when it comes within camera right edge + 1 tile (the real
   game's rule, approximately). Walkers move left at their real speed, follow
   `route`/`solid`, turn at walls and fall into pits. Piranhas bob on a timer. Each bot
   tracks which spawns are dead, so a stomped Goomba stays dead.
5. **Outcomes are scripted, not physical.** Mario never "accidentally" dies.
   - An enemy ahead within about 1.5 tiles with no pending HIT/KO: auto-jump and stomp it
     (squash frame, then removed). A Koopa leaves a still shell.
   - `HIT` pending: the next active enemy in front is chosen as the cause and Mario walks into
     it, then shrink (the `Grow` animation reversed) and about 1 s of blinking. If no enemy is
     in reach, the next real spawn within about 2 screens is activated early. Failing that,
     a Goomba is injected at the right edge. That is the same primitive incoming enemies
     use (§7).
   - `KO HAZARD`: if a pit is within reach of this interval, Mario falls in (the jump falls
     short). Otherwise he dies to an enemy, as for HIT. `KO TIME`: `Die` in place.
   - Then `DYING` (the classic hop-and-fall, about 1.5 s), then `KO`.
6. **Level clear.** A `LEVEL_CLEAR` event splits the interval: run to `goal_x`, then `FLAG`
   (slide on the pole with `Climb`), then walk to `castle_x` and fade, then `TRANSITION`
   (about 0.6 s black, the tiny world card), then load the next course's sketch and restart
   at its `start_x`. The follower then catches up to the new level's live progress. Castle
   courses: run to the axe and fade (the bridge collapse can wait).
7. **Power.** The sprite set follows the *displayed* power. `POWER_UP` currently only happens
   on a level clear, so it simply appears on the next level. If the session later produces
   mid-level power-ups, bump the nearest ?-block ahead, show the item and play `Grow`.
8. **Camera.** `camera_x = clamp(mario_x - 0.4*view_w, left, right - view_w)` and it never
   decreases within a level (`can_backscroll` is false in SMB1). `view_w = 240 * cell_aspect`
   (about 189 logical px, already computed by the surface). Vertical framing is fixed to the
   level band (−208..32), like the real camera.
9. **Variety.** Small per-bot style values drawn from the track RNG and skill: run vs walk
   bias, extra hop chance, stomp eagerness. At match start, 34 Marios in 1-1 should not move
   in lockstep.

Output: `frame()` returns `BattlePreviewFrame`. It is plain data: camera, Mario sprite id,
position and flags, up to about 10 sprite draws, a fade value, a KO flag, and the
`displayed_course` for the label.

### 4.5 `BattlePreviewDriver` (owned by BattleHud)
- Each `_process`: if `session.tick_count` advanced, push that tick's keyframes and events
  into each alive track (KO'd tracks still receive their KO).
- Visual time: `t = session.tick_count + BattleHandler.presentation_alpha - LAG`.
  `presentation_alpha = accumulator / step_seconds` is published by the handler. It is
  presentation-only; the session stays pure. When the game pauses, the handler stops, alpha
  freezes and the previews freeze, even though the HUD is `PROCESS_MODE_ALWAYS`.
- Each track then fixed-steps up to `t` in 1/30 s units of **session time**, capped per frame,
  and snaps beyond the cap. This makes visuals deterministic given the tick timeline and
  makes `--battle-sim-speed` work without changes.
- `surface.set_frame(frame)` → `queue_redraw()` only when the frame changed.
- It warms assets: the course-0 sketch and strip are built at HUD build. Later, the next course
  is prefetched with `ResourceLoader.load_threaded_request` plus a `WorkerThreadPool` image
  bake when the leading bot passes progress 0.5.

### 4.6 Surface and renderer changes
- `BattlePreviewSurface` keeps owning the frame, the id, the W-L label and the KO overlay. The
  label and the KO overlay are driven by the **frame** (displayed course, KO after the death
  animation) instead of the raw contestant. That keeps them in sync with the lagged picture.
  It sets `texture_filter = TEXTURE_FILTER_LINEAR_WITH_MIPMAPS` on itself only.
- `BattlePreviewRenderer.draw(canvas, frame, logical_size)`: the input changes from
  `BattleContestant` to `BattlePreviewFrame`. `BattleMiniGameRenderer` draws one
  `draw_texture_rect_region` of the strip, then enemies, then Mario (`ACTOR_SCALE`, see R1),
  then the fade. `BattlePlaceholderRenderer` stays as the fallback for any course whose
  sketch or assets fail.

## 5. What is reused, and what is deliberately not

Reused:
- Level `.tscn` files as **data** through SceneState: tiles, deco, blocks, enemy spawns,
  flag/castle, start position and theme.
- Themed terrain/deco/background PNGs and sprite sheets through the resource-pack and JSON
  rules, so ROM assets and resource packs apply to previews too.
- Real animation frame rects and speeds from the sprite JSONs.
- The progress definition (start → goal) shared with the real player.

Not reused, on purpose:
- No `Level`, `Player`, `Enemy` or `TileMapLayer` nodes in the tree. No physics, no collision
  shapes, no `ResourceSetterNew` nodes, no reliance on `Global.level_theme`.
- No item boxes, coins, block bumping or particles (except an optional power-up bump later).
- No pipes/vines/sublevels/warp zones. Bots always take the main route.
- No moving hazards at first: firebars, lifts, Lakitu, Bowser, Hammer Bros, Podoboos and
  Bloopers are added later as closed-form-in-time actors where they matter.

## 6. Cost estimate (34 previews)

| Item | Cost |
|---|---|
| Track logic: 34 × (Mario + ≤8 enemies) × 30 Hz | about 10k tiny GDScript updates/s; well under 1 ms/frame |
| Drawing: 34 × about 12 draw commands, recorded at ≤30 Hz | about 400 commands per redraw; same textures, so they batch; under 0.5 ms CPU |
| GPU | 34 small quads of a mipmapped strip plus about 300 tiny sprites; negligible |
| Strip textures | 1-1 RGB8 3600×240 ≈ 2.6 MB, about 3.5 MB with mips; LRU of about 4 levels ≈ 14 MB |
| Sketches | about 10–50 KB per level |
| Mini sprites | under 1 MB |
| Per-track state | under 2 KB each; about 70 KB total |
| Level load + bake | SceneState read plus about 800 `blit_rect`s: roughly 10–50 ms. Fine at HUD build for course 0; later courses are prefetched or threaded |

No SubViewports. The rejected alternative, one SubViewport per window with real tilemaps, means
34 render targets and passes plus hundreds of nodes. Drawing tiles live per frame means about
5k draw calls and nearest-filter aliasing.

## 7. Incoming / sent enemies (later, same system)

- The session owns the attack rules: kills, sends, targets, queues. It emits
  `SENT`/`RECEIVED`.
- A track receiving `RECEIVED(kinds)` calls `inject_enemy(kind)` at the camera's right edge,
  flagged `incoming` and drawn with an outline or tint. This is the same primitive the HIT
  fallback uses.
- If kills become authoritative, the track's stomp choice simply has to show at least that
  many stomps. The track picks which enemies, using the same scripting rule as §4.4 (5).
- Attack lines between windows (SMB35's arrows) belong to a separate HUD overlay that reads
  surface rects and events. They are not part of a track.
- Optional, later, and the only place the session may consult level data: a level-aware bot
  model where hazard and kill rolls are weighted by `sketch` density over
  `[x0, x1]` this tick. It uses data only, never visuals. That keeps one simulation and
  makes outcomes and pictures agree. It must go through an injected provider so session tests
  can stub it.

The reference's strip below the playfield (incoming queue roulette) would read the same
session queues. Nothing here blocks revisiting the strips above and below the playfield.

## 8. Determinism

- Session outcomes depend on `seed` only, as today. The event log is derived from state
  diffs and never calls `rng`. Test: the same seed gives the same `snapshot()` with the
  driver attached or detached.
- Previews depend on `(seed, id, course)` RNGs plus the session tick timeline. They step in
  fixed session-time units, so the same match gives the same pictures. Test: run a session
  headless, drive the tracks, and assert identical frame data on two runs.

## 9. Risks

- **R1: pixel budget (largest).** At default "pixel-perfect" visuals the cells are 26×33
  framebuffer px, so terrain is about 2 px per tile and Mario is about 2 px. Mitigations:
  mipmapped strip and sprites (§4.3); `ACTOR_SCALE` (try 1.5–2×) so actors stay legible;
  the same code automatically looks like the reference under `CANVAS_ITEMS`. **Decide
  early:** A/B screenshot the milestone at 1080p in both modes. If Battle should force
  `CANVAS_ITEMS` while active (the HUD already forces resolution and restores it on exit),
  that is a one-line presentation decision outside the preview architecture.
- **R2: SceneState parsing.** Only overridden properties are stored (default position
  (0,0)). Nested instances and per-level oddities exist. SMB1 only; custom/editor levels use
  a different format and are out of scope. Per-level QA is needed.
- **R3: theme resolution.** `ResourceSetterNew` reads globals, and `Global.theme_override`
  beats `force_properties`. The cache is keyed by path alone. Validate the detached-resolver
  approach in the milestone and keep a dedicated resolver as the fallback. ROM-generated
  textures must be readable with `get_image()`; this is fine for ImageTexture, and imported
  lossless CompressedTexture2D works too.
- **R4: route heuristics** on 1-3/4-3 lifts, 2-2/7-2 water, and the 4-4/7-4/8-4 mazes. Fallback
  per course: "flat run" (straight line at the start height with placeholder ground) and a
  per-course override table.
- **R5: lag vs HUD.** The alive count and rank are immediate while the window shows the KO
  about 2 s later. Acceptable (SMB35 has similar delays). The window's own label and overlay
  follow the frame.
- **R6: hitches** loading other levels mid-match. Prefetch and thread (step 4 of §11).
- **R7: snap settings.** With `snap_2d_vertices_to_pixel`, scrolling moves in whole
  framebuffer pixels. That is unavoidable at 26 px, and trilinear UVs still keep it free of
  shimmer.

## 10. Milestone 1: one convincing 1-1 window

**What Sonnet builds:**

1. `BattleCourse` (path mapping plus the shared goal finder; `BattleHandler` switched to it,
   with no behaviour change).
2. `BattleLevelSketch.load()` for `SMB1/World1/1-1.tscn`, and generically where it is free:
   tiles, deco, blocks, spawns (Goomba, Green Koopa), start, flagpole/castle, theme, route,
   jumps, pits.
3. `BattlePreviewAssets` for the Overworld/Day/SMB1 terrain, deco and LevelBG hills/bushes/
   clouds: strip bake with mipmaps; Mario Small/Big/Fire mini frames; Goomba and Koopa mini
   frames. Includes the explicit-theme resolver spike (R3).
4. The session event log (`HIT`, `POWER_UP`, `LEVEL_CLEAR`, `KO`) plus
   `BattleHandler.presentation_alpha`.
5. `BattlePreviewTrack` with all of §4.4 except moving hazards. Course 0 only. After the
   track's `LEVEL_CLEAR` transition (or for any course other than 0), it reports "no sketch"
   and the surface falls back to the placeholder renderer.
6. `BattlePreviewDriver` plus `BattleMiniGameRenderer`. **Only contestant #1's window** uses the
   new renderer; the other 33 keep the placeholder.
7. A debug-only aid (gated like `sim_speed`, e.g. `--battle-preview-debug`): draws track #1
   additionally at 1:1 (256×240) over the centre, so the motion can be judged at full size,
   and a second flag that puts all 34 windows on the new renderer to measure cost.
8. Headless tests (`tests/battle_preview_test.gd`):
   - 1-1 sketch: pit columns 53–54/70–72/137–138, `goal_x == 2920`, 16 Goombas plus 1 Koopa,
     no route surface over a pit.
   - Track invariants over a full simulated match: Mario is never inside `solid`, never over
     a pit unless airborne or dying, `x` never exceeds `goal_x` before `LEVEL_CLEAR`, `KO`
     phase reached for every KO event.
   - Determinism: two runs give identical frames; session results are identical with and
     without the driver.

**Acceptance (visible):** with `--battle-sim-speed=1`, window #1 shows 1-1 scrolling
(ground, the pipes, the pits, the ?-blocks, the stairs, the flagpole and the castle).
Mario walks and jumps over pipes and pits. Goombas walk in from the right, fall into pits
and get stomped. Big and fire Mario show when the bot has power. A HIT shows a shrink and
blink, and a KO shows a pit fall or a Goomba death followed by the KO overlay. A clear shows
the flag slide and the castle. Classic mode is untouched. All 34 on 1-1 cost under 2 ms CPU
per frame (measured and written down). The A/B screenshots for R1 are attached to the PR.

**What waits:** courses beyond 1-1 and other themes; underground/castle/water specifics; moving
hazards; prefetch and threading; incoming/sent enemies and attack lines; KO feed; level-aware
bot risk; the strips above and below the playfield.

## 11. Implementation sequence after the milestone

1. **All 34 on the new renderer; World 1 sweep** (1-2 Underground theme, 1-3 platforms, 1-4
   castle with bridge goal). Add a per-course override table for route fixes.
2. **Worlds 2–8**: water route mode (swim animation, mid-height path), castle mazes as a
   straight path, the flat-run fallback wherever QA fails.
3. **Moving hazards** as closed-form actors: firebars, lifts, Podoboo, Bowser idle, Lakitu
   overhead. Visual only.
4. **Asset streaming**: threaded sketch and strip prefetch for the next course; LRU eviction.
5. **Attack system** (session first): `SENT`/`RECEIVED`, then track injection, then the
   attack-line overlay, then the bottom-strip queue if that presentation is revisited.
6. **Optional level-aware bot model** (§7) once the pictures are trusted.
