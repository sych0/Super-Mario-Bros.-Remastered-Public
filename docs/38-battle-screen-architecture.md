# 38 — Battle Mode: screen composition, preview resolution, round lifecycle

Status: architecture revision, written against `6a74b47`. Milestone 1 is implemented: see doc 39. It replaces the screen-composition
parts of docs 36 and 37 (listed in section 1). The approach was checked with prototypes in
Godot 4.6 on the project's own renderer (Compatibility / GLES3). The pictures are in
`docs/battle-screen/` and can be reproduced with `tests/tools/battle_screen_spike.gd`. That
file is a prototype and is not wired into the game.

Three decisions, one per correction:

1. **The Battle screen is the root canvas.** It is 480×270 logical and renders at display
   resolution. The classic game runs unchanged inside a 256×240 `SubViewport`, shown as the
   centre window. During Battle the root viewport is never the game.
2. **Opponent previews are full-size pictures, scaled down.** Each one is drawn at the classic
   camera's 1:1 scale (187×240 texels) into one shared atlas, then downsampled into a
   display-resolution pane. Nothing is rendered at 26×33 any more. The preview simulation is
   unchanged.
3. **Battle owns a round lifecycle:** pre-round, playing, round over, results, next round.
   Losing never leads to the title screen. Only Quit does.

---

## 1. What the screenshot disproved

The current design makes the root viewport a 426×240 level and paints the side panels over
its edges. That is wrong in three ways. The first is visible; the other two are not.

| Problem | Evidence in the code | Effect |
|---|---|---|
| The level continues behind the panels | `BattleHud` is a `CanvasLayer` drawn over a 426-wide root | What the screenshot shows |
| **Battle does not run classic gameplay** | Classic code sizes things from the viewport. `CameraHandler.update_camera_barriers` puts the camera walls at ±`viewport_w / 2`, so ±213 instead of ±128. `Player.gd:1254`, `LevelBGNew` and `DropShadowRenderer` read the viewport size. 51 entity prefabs use `VisibleOnScreenNotifier2D`/`Enabler2D`. | Mario can walk about 85 px behind the left panel. Enemies wake up about 85 px early, while still hidden behind the right panel. |
| Previews are physically 26×33 pixels | Everything in the root is rasterised at 426×240 and then upscaled (`stretch/mode="viewport"`) | Milestone 1's mipmaps only chose *which* 26×33 pixels you got. Nothing inside a 426×240 framebuffer can look like the reference. |

**Superseded** (Sonnet should not preserve these):
- Doc 36: the last two rows of §1, §4.6 (the surface draws in slot space), R1 and R7 in §9, and
  the "draw over the centre" debug overlay in §10.7.
- Doc 37: §5 (1.6× zoom, 1.35× actors) and §6 (the pixel vs smooth discussion).
- The 426×240 geometry in `BattleHudLayout`.
- `BattleHud` as a root-level `CanvasLayer` that forces `RESOLUTIONS[2]`, and
  `BattleHud.resolution_index`.
- The Battle anchor branch in `GameHUD`, in its current form.
- `BattleHandler.end_match()` going to the title.
- The tests that encode all of this (section 9).

**Still valid and unchanged:** `BattleSession` (rules, event log, determinism),
`BattleBotSimulator`, `BattleContestant`, `BattleCourse`, `BattleLevelSketch`,
`BattlePreviewResolver`, `BattlePreviewAssets`, `BattlePreviewTrack`, `BattlePreviewDriver`
and `BattlePreviewFrame`. The whole "the session decides, the preview shows" pipeline stays.
Only where its pixels end up changes.

## 2. Target composition

```
root Window ─ Battle canvas: 480×270 logical, CONTENT_SCALE_MODE_CANVAS_ITEMS, aspect KEEP
│             (rendered at display resolution; 1920×1080 is exactly 4×)
└─ BattleScreen (Control) ─ the SceneTree's current_scene for the whole Battle; PROCESS_MODE_ALWAYS
   ├─ wallpaper, gold frame, strips, badges, status text            canvas, display resolution
   ├─ GameWindow: SubViewportContainer at (112,3), 256×240, NEAREST
   │  └─ GameViewport: SubViewport 256×240, PROCESS_MODE_PAUSABLE, 2D audio listener
   │     └─ <current game scene: LevelTransition, 1-1, 1-2, …>      classic code, unchanged
   ├─ OpponentPane ×34   atlas region → 32×41 pane, downsampled; frame, id and KO at display res
   ├─ PreviewAtlas: SubViewport, 7×5 cells of 187×240, UPDATE_ALWAYS
   │  └─ PreviewCell ×34 → BattleMiniGameRenderer / BattlePlaceholderRenderer at 1:1
   ├─ AudioListener2D (root world) that follows the game camera
   └─ Overlays: CanvasLayer (layer 90): pre-round banner, round results
Global (autoload, tree unchanged)
   ├─ GameHUD (CanvasLayer): stays in the canvas, CENTER_TOP plus offset.y onto the window
   └─ Transition (CanvasLayer): custom_viewport = GameViewport, so it fades only the window
```

Rules:
- **Inside the window** is the classic game's own 256×240 space. Only classic code draws there,
  plus `Global`'s `Transition` fade. **Around and on top of the window** is the canvas.
  Battle UI can sit over the window (banner, results) because canvas items and higher
  `CanvasLayer`s draw after the `SubViewportContainer`. That is the "Battle UI on top" layer.
- Godot renders child viewports before their parent, so `GameViewport` and `PreviewAtlas`
  are finished before the root samples them. There is no frame of latency.

Evidence: `01-target-composition-1080p.png` and `02-target-composition-720p.png` show the real
1-1 running in the window, 34 live previews, badges and strip placeholders. The art is the
sandbox stand-in pack, and the `HUD_WORHDD_TIME` text is an untranslated locale key in this
environment, not a layout bug.

## 3. Why this composition (the alternatives were tried)

| Option | Outcome |
|---|---|
| **A.** Keep the root as the game at 256×240. Attach a second, full-resolution canvas viewport to the screen behind it with `RenderingServer.viewport_attach_to_screen`, and move the root's screen rect. | Moving the root's rect works. Stacking does not work on the Compatibility renderer: the prototype shows only the game, with black where the canvas should be (`06-rejected-two-screen-viewports-gles3.png`). That fits GLES3 blitting each screen-attached viewport in its own pass and clearing the window before any blit that does not cover it. GL also measures the rect from the bottom-left corner. **Rejected.** |
| **B.** The root is the canvas and the level lives in a `SubViewport`. | Works (`01`, `02`): camera, physics, input and enemies behave normally, and the level reports a 256×240 visible rect. **Chosen.** |
| **C.** A mirror `SubViewport` that shares the root's `World2D`. | The level would still live in a wide root and render twice, and gameplay sizing would stay wrong. **Rejected.** |
| **D.** Shrink the game window inside a 426×240 canvas to make room for the strips. | The pixel art would be scaled by a non-integer factor, and the panes would still be 26×33 pixels. **Rejected.** |

## 4. The Battle canvas: 480×270, not 426×240

The correction asked for a 426×240 canvas. Once the game is a contained 256×240 surface drawn
at 1:1, a canvas 240 px tall leaves **0 px** for the strips. The only way to fit them would be to shrink the game by a
non-integer factor. 480×270 is the reference's own canvas:

- 1920×1080 is exactly 4× of it.
- The reference's game window is about 1026 px wide, which is 256×4.
- The reference's cells are about 130×166 px, which is 32.5×41.5 logical.

So 480×270 gives the strips 27 px, the cells 32×41, and the game window an integer 4× scale at
1080p (426×240 is 4.5× there). It is one constant, `BattleHudLayout.CANVAS`. Since the canvas
is no longer the gameplay resolution, it does not need to be in `Global.RESOLUTIONS`.

The user's scaling setting still applies. "Integer" maps to `CONTENT_SCALE_STRETCH_INTEGER`
(1280×720 becomes 2×, letterboxed). "Fractional" gives 2.67×. The game window always uses the
same scale as the canvas.

Geometry, in logical px (this is what the prototype uses):

| Element | Rect |
|---|---|
| Game window | (112, 3, 256, 240) |
| Gold frame around it | (108, 0, 264, 268) |
| Strip A (progress, later the incoming queue) | (112, 245, 256, 11) |
| Strip B (coins / item, later) | (112, 257, 256, 11) |
| Panels | x 0..108 and 372..480 |
| Opponent cells | 32×41 (the reference's 129:165 aspect), gap 2, 3 columns × 6 rows, grid top 12, x0 = 4 on the left and 376 on the right. The inner top cell on each side is a badge, which leaves 17 panes per side. |
| Course badge | (72, 0, 32, 30) |
| Alive badge | (376, 0, 32, 44) |
| TIME / RANK | one line each in the 12 px above the grid, beside the badges |

## 5. The game window

### 5.1 Scene routing (the one hook into scene changes)

During Battle, `current_scene` is `BattleScreen`. Game scenes never go through
`change_scene_to_file` while Battle is running. The game's only `change_scene_*` calls are
inside `Global.transition_to_scene`, which has about 80 callers (death reloads,
`reload_level`, `LevelTransition`, level clears), so a single hook covers them all:

```gdscript
# Global.transition_to_scene, replacing the change_scene_* lines + `await get_tree().scene_changed`
if BattleScreen.routes(scene_path):
	await BattleScreen.load_game_scene(scene_path)
else:
	...existing change_scene_to_file / change_scene_to_packed...
	await get_tree().scene_changed
```

- `routes(path)` is true when the game mode is Battle, a `BattleSession` exists, and `path` is a
  String that is not the title scene.
- `load_game_scene` handles the first case and every later one:
  - **First Battle transition** (from the title): create the screen with
    `get_tree().change_scene_to_node(BattleScreen.new())` (Godot 4.5+, verified in 4.6), wait
    for `scene_changed`, then add the instantiated scene to `GameViewport`.
  - **Later transitions:** free the old game scene and add the new one.
- **Leaving Battle** is an ordinary transition to the title. `change_scene` frees `BattleScreen`
  together with everything inside it. The "static HUD under root that frees itself when Battle
  ends" goes away.

### 5.2 Who owns the window

- `BattleScreen` sets the root's content scale on enter: size 480×270, aspect KEEP, mode
  `CANVAS_ITEMS`, stretch from the scaling setting, 2D snap from the visuals setting. On exit it
  restores the user's values, using the same rules as `WindowChanger` and
  `Level.reset_resolution`.
- `Level.apply_resolution_enforcement()` and `Level.reset_resolution()` return early while
  `BattleScreen.owns_window()` is true. This replaces `BattleHud.resolution_index`. The
  prototype shows the problem: loading a level puts the canvas back to 256×240.
- If a setting is changed from the Battle pause menu, `BattleScreen` re-applies the canvas
  whenever the root has drifted (a cheap per-frame comparison). The new setting takes effect
  when Battle ends.
- The game window is always pixel-perfect: 256×240 upscaled with nearest filtering. Supporting
  the "smooth visuals" option there would need the `SubViewport` at window resolution with
  `size_2d_override`. That is deferred.

### 5.3 Global UI

- **GameHUD stays in the canvas**: the existing Battle `CENTER_TOP` branch (now keyed on
  `BattleScreen.is_active()`) plus `offset.y = game_rect.y`. Redirecting it with
  `custom_viewport` does draw it inside the window, but Godot still anchors the Controls to the
  node-tree viewport, which is the root's 480×270 rect. The HUD then comes out shifted and cut
  off (`04-gamehud-redirected-into-window.png`).
- **Transition: `custom_viewport = GameViewport`.** It is a full-rect block, so anchors do not
  matter, and level fades stay inside the window (`05-transition-confined-to-window.png`). Set
  it back to `null` on exit, and before the fade into the title starts, so that one covers the
  whole screen.
- **`freeze_screen()`** captures `Global.get_game_viewport().get_texture()`. The root texture is
  now the whole Battle screen.
- The pause menu (inside GameHUD) appears over the centre of the canvas, which is fine.

### 5.4 Code that finds "the game camera" through the root

Add `Global.get_game_viewport() -> Viewport`. It returns the root normally and `GameViewport`
during Battle. Use it at the four places that would otherwise break in Battle:

| Call site | Today, in a Battle with the new composition |
|---|---|
| `Global.gd:116` (1-up sfx when coins reach 100) | `get_viewport().get_camera_2d()` is null: a **crash** |
| `AudioManager.play_global_sfx` | returns early: **silent** |
| `ScreenShaker` (a child of Global) | the shake silently stops |
| `DropShadowRenderer` (`current_scene.get_viewport()`) | reads the root: no drop shadows |

Outside Battle the helper returns the same viewport as today, so nothing changes there.

### 5.5 Audio

- `AudioManager` creates its sfx players under the autoload, in the root's world, at level
  coordinates. The root's listener is now the canvas, so with the default 2D panning strength
  (0.5) sounds would pan further right as Mario moves right. `BattleScreen` therefore keeps an
  `AudioListener2D` in the root world at the game camera's screen centre, updated every frame.
- `GameViewport.audio_listener_enable_2d = true`, for the 2D players inside the level.
- Remaining difference: the pan width is measured against the root's 480 px rather than 256 px,
  so panning is about half as wide. This is acceptable and is noted as a risk.

### 5.6 Pause, input, processing

- `GameViewport` is set explicitly to `PROCESS_MODE_PAUSABLE`, because `BattleScreen` is
  `ALWAYS`. `get_tree().paused` freezes the level. The handler's `presentation_alpha` then
  freezes too, and the previews stop with it.
- Gameplay input is polled through `Input` (`Global.player_action_*`), so it does not depend on
  the viewport. In the prototype Mario moves under simulated input. `SubViewportContainer`
  forwards key events to `_input` handlers inside the level.

## 6. Opponent previews at full resolution

```
BattlePreviewDriver / Track (unchanged) ──► BattlePreviewFrame
   ──► PreviewCell, in PreviewAtlas: renderer.draw at 1:1 into 187×240 texels
   ──► OpponentPane, in the canvas: atlas region drawn into 32×41 logical (≈128×164 px at 1080p),
       linear filter + footprint shader; frame, id, W-L and KO marking drawn at display res
```

- **Internal size:** 240 tall, which is the classic camera band (world y −208..32), by
  240 × cell aspect = 187 wide. That is the gameplay coordinate space the previews were
  already designed around.
- **`ZOOM` and `ACTOR_SCALE` go back to 1.0.** They only existed to survive 26×33 pixels. The
  driver is created with `view_w = 187`, so enemies appear at the real edge of the picture.
- **Downsampling:** linear filtering plus a 4-tap footprint shader (in the prototype). The
  scale factors are 0.68 at 1080p, 0.46 at 720p, 0.91 at 1440p and 1.37 at 4K. Without the
  shader 720p shimmers slightly. Godot 4.6 cannot generate mipmaps for viewport textures (checked
  in its class reference), which is why the shader is needed. Atlas cells have 4 px of padding
  so taps do not bleed between cells.
- **Atlas:** 7×5 cells, about 1337×1220 RGBA (about 6.5 MB of VRAM), rendered once per frame in
  one pass. Each cell issues the same draw commands milestone 1 measured (34 live:
  0.72 ms CPU per frame). Re-measure after the change. Rendering only cells that changed is a
  later optimisation.
- The **placeholder renderer** draws into the same cells, because its art is already in
  240-space.
- **All 34 cells are live on 1-1** by default. Milestone 1 limited it to one cell for scope,
  not cost. Other courses fall back to the placeholder per cell, as before.
- **Debug full view:** a `TextureRect` showing atlas cell #1 at 187×240 logical over the window.
  It is the same image, not a second render.
- `BattlePreviewSurface` is split in two:
  - `BattlePreviewCell` (atlas; the picture only; keeps the cost counters).
  - `BattleOpponentPane` (canvas; texture region plus frame, id and W-L text; the KO marking
    follows the frame and the session as it does today).

Evidence: `03-left-panel-before-and-target.png` (left: today's 26×33 cells; right: the same
match at full resolution).

## 7. Round lifecycle

The state machine is owned by `BattleScreen`. Its logic lives in a pure `BattleRound`
(`RefCounted`) so it can be tested headless.

```
 title ─► LOADING ─► PRE_ROUND ─► PLAYING ─► ROUND_OVER ─► RESULTS ─┐
            ▲                                                       │ jump / 10 s
            └───────────────────── next round ──────────────────────┘
 Quit (pause menu, any state) ─► title
```

- **LOADING.** `BattleRound.begin()`:
  1. Reset player state with one shared function, also used by `TitleScreen.start_battle`:
     `Global.clear_saved_values()`, world/level 1-1, `Global.reset_values()`,
     `PipeCutscene.seen_cutscene = false`, `Global.death_load = false`,
     `get_tree().paused = false`.
  2. `BattleSession.begin(new seed)`.
  3. Transition to 1-1 through `LevelTransition`, as today. The transition plays inside the
     window.
- **PRE_ROUND.** Entered when a `Level` enters `GameViewport` for a new session.
  - `GameViewport.process_mode = DISABLED`: the level is visible but frozen.
  - The session does not tick, because the handler is not processing. The previews show their
    starting positions.
  - A "READY" then "GO" banner shows over the window for about 2.5 s (a dev flag skips it).
  - Then `PAUSABLE` again, and the state moves to PLAYING.
- **PLAYING.** As today.
- **ROUND_OVER.** Entered in one of three ways:
  - **The player dies.** The KO is registered **at the moment of death** (`BattleHandler` sees
    `player.is_dead` and calls `session.report_ko(PLAYER, HAZARD)`), so placement reflects when
    they actually died. Today it is registered about 3 s later, after the death jingle.
  - **Time runs out.** The session KOs the player for time, and the handler forces `time_up`,
    as today.
  - **The player is the last one standing.**

  The classic death animation plays in the window. The Battle branch of `Player.death_load`
  calls `BattleScreen.round_over()` instead of `end_match()`. `session.resolve_to_end()`
  finishes the placements.
- **RESULTS.** An overlay over the window shows placement, cause, winner, levels cleared and
  opponents left, with "PRESS JUMP FOR NEXT ROUND". It stays up for at least 1 s and
  advances automatically after 10 s, then the state moves to LOADING.
- **Quit** (pause menu): `BattleSession.clear()`, game mode NONE,
  `Global.transition_to_scene(TITLE)`. There is no results screen for a forfeit.
- **No path from a loss to Game Over, Time Up or the title.** `Player.death_load` already
  checks the game mode before lives and time; only the Battle entry's target changes.
- **Nothing carries over between rounds** except a round counter (and later, Battle stats).
  Everything that belongs to one match lives on the `BattleSession`, which is recreated each
  round.

## 8. Class and file map

| Now | Becomes |
|---|---|
| `BattleHud` (`CanvasLayer` under root, static instance, forces 426×240) | `BattleScreen` (`Control`, current scene; owns the window settings, canvas, `GameViewport`, atlas, overlays and round) |
| `BattleHudLayout` (426 geometry) | `BattleHudLayout` with `CANVAS = 480×270` and the section 4 geometry (still pure) |
| `BattlePreviewSurface` | `BattlePreviewCell` + `BattleOpponentPane` |
| `BattleHandler.end_match` / `quit_battle` going to the title | `BattleScreen.round_over()` / `quit()`. The handler only drives the clock and reports to the session. |
| `BattleHud.resolution_index` (in `Level`) | A guard in `Level`: `BattleScreen.owns_window()` |
| `GameHUD` Battle anchor branch | The same branch via `BattleScreen.is_active()`, plus the offset |
| — | `Global.get_game_viewport()`; the `Global.transition_to_scene` hook |
| `BattleMiniGameRenderer` | Unchanged except `ZOOM = ACTOR_SCALE = 1.0` |
| Session, bot simulator, contestant, course, sketch, resolver, assets, track, driver, frame, placeholder renderer | Unchanged |

Changes outside `Scripts/Classes/Battle/` (all have no effect outside Battle):
- `Global.transition_to_scene`, `freeze_screen`, line 116, and the new `get_game_viewport`
- `AudioManager.play_global_sfx`
- `ScreenShaker`
- `DropShadowRenderer`
- The resolution guard in `LevelClass`
- `GameHUD` anchors and offset
- The Battle entry in `Player.death_load`
- `TitleScreen.start_battle` (calls the shared reset)
- The `BattlePauseMenu` quit handler

## 9. Tests

**Delete** these, because they encode the disproven design. Their existence is not a reason to
keep it. All are in `battle_hud_test.gd`:
- "Battle forces the native 16:9 resolution" (426×240)
- "all 34 slots are on screen and outside the gameplay area" (426 geometry)
- `test_layout`'s `center == Rect2(85, 0, 256, 240)`
- "HUD survives a scene change" (root-level HUD)
- "leaving Battle returns to title" after a KO

**Keep**, pointed at `BattleScreen`: data binding (alive, time, rank, KO propagation), no Battle
UI in Classic, Classic resolutions unchanged after Battle.

**Add:**
- **Layout:** canvas 480×270; game rect (112, 3, 256, 240) on whole pixels; 34 panes, 17 per
  side; no overlaps between panes, window, frame, strips and badges; the strips fit under the
  window.
- **Composition invariants:**
  - During Battle, `current_scene` is `BattleScreen`.
  - `Global.current_level.get_viewport()` is a 256×240 `GameViewport`, and the level's
    `get_viewport_rect().size == (256, 240)`. This is the gameplay-sizing invariant.
  - The root has no current `Camera2D`, and its content scale is 480×270 `CANVAS_ITEMS`.
  - Loading a level during Battle does not change the root.
  - After Quit, the user's size, mode, stretch and snap are restored exactly.
- **Routing:** a level-to-level transition keeps the same `BattleScreen` instance, replaces the
  game scene, and emits `transition_finished`.
- **Lifecycle:**
  - Player KO → ROUND_OVER → RESULTS → dismiss → a new session with a different seed, 1-1
    loaded in the window, mode still Battle, and TitleScreen, GameOver and TimeUp never loaded.
  - The time-out and win paths do the same.
  - Quit → title, no session, window restored.
  - Five consecutive rounds keep the node count stable (no leaked sessions or screens).
- **Previews:** atlas cells are 187×240; a pane draws its own region; `ZOOM == ACTOR_SCALE ==
  1`. The existing determinism and track tests in `battle_preview_test.gd` stay as they are.
- **Root lookups:** reaching 100 coins during Battle plays the 1-up without an error.
- `battle_preview_capture.gd` is rewritten to capture the window through
  `DisplayServer.screen_get_image`. Its `scene=1` mode becomes the default.

## 10. Milestones for Sonnet (in this order)

1. **Composition.** No visual polish yet.
   - Work: `BattleScreen` as the current scene, the canvas window settings, `GameViewport` and
     scene routing, the `Level` guard, the GameHUD offset, the Transition redirect,
     `get_game_viewport` and its four call sites, and the audio listener. Re-lay the existing
     panes and badges on 480×270, drawing placeholders directly in the panes (no atlas yet).
   - Acceptance: play 1-1 into 1-2 in Battle. The level is inside the window and the camera
     walls are at ±128. Quitting restores Classic exactly. The composition and routing tests
     pass.
2. **Previews at resolution.**
   - Work: atlas, cells, panes, downsample shader, `ZOOM` and `ACTOR_SCALE` at 1, pane frame
     and text at display resolution, all 34 live on 1-1, the debug view as atlas cell #1.
   - Acceptance: the quality of `01-target-composition-1080p.png` at 1080p and of
     `02-target-composition-720p.png` at 720p, with the cost table re-measured.
3. **Round lifecycle.**
   - Work: `BattleRound`, the pre-round banner, KO at the moment of death, results then next
     round, and Quit.
   - Acceptance: a loss goes to the results and then a fresh 1-1 round, without passing
     through the title or Game Over. The lifecycle tests pass.
4. **Strip and badge content.**
   - Work: strip A shows the player's course progress (later the incoming queue). Strip B is a
     coins / item placeholder. The badges stay as they are.

Milestone 1 comes first because everything else hangs off `BattleScreen`.

## 11. Risks

- **R1: other code that assumes the root is the game.** Section 5.4 lists everything a grep
  finds (`get_viewport().get_camera_2d()` in autoloads, `current_scene`, `root.add_child`).
  Anything missed would misbehave only during Battle. Add a debug-build check: during Battle,
  log if a `Camera2D` ever becomes current in the root.
- **R2:** `change_scene_to_node` needs Godot 4.5 or later. The project targets 4.6.
- **R3: fractional scales.** At 1440p (5.33×) the game window has uneven pixels, exactly as
  with any fractional setting today. Integer mode letterboxes instead.
- **R4:** GameHUD lives in the canvas, so very long HUD strings can run past the window edge.
- **R5:** a resolution or visuals change from the pause menu during Battle must be re-applied
  (section 5.2). This needs a test.
- **R6:** panning is about half as wide (section 5.5).
- **R7: limits of the prototype.** It ran under Xvfb with Mesa's software GL, so GPU cost was
  not measured. The art is the stand-in pack, because no ROM-derived art was available.
