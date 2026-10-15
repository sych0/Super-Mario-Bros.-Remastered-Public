# 39 — Battle screen, milestone 1 (composition): what was built and what it taught

Status: implemented on top of `534e2b3`. Follows doc 38 (milestone 1 of section 10). Milestones 2-4 are
not started.

## 1. What now exists

```
480×270 BattleScreen (Control, the SceneTree's current scene)       Scripts/Classes/Battle/BattleScreen.gd
├─ Wallpaper (gold, whole canvas) → Frame → StripA / StripB          geometry: BattleHudLayout (pure)
├─ GameWindow: SubViewportContainer (112, 3, 256, 240), NEAREST
│  └─ GameViewport: SubViewport 256×240, PAUSABLE, 2D audio listener
│     └─ the real LevelTransition / PipeCutscene / 1-1 / 1-2 …        classic code, unchanged
├─ 34 opponent panes (32×41, the existing BattlePreviewSurface), badges, TIME / RANK text
├─ AudioListener2D (root world) following the game camera
└─ Overlays (CanvasLayer 90): the interim match-result card, over the window
```

Screenshots: `docs/battle-screen/07-m1-composition-1080p.png` (the real project, Godot 4.6, GL
Compatibility, 1080p), `08-…-left-wall`, `09-…-fade-confined`. The art is the sandbox stand-in pack, and
the `HUD_WORHDD_TIME` text is the same untranslated locale key as in doc 38.

### Scene routing

`Global.transition_to_scene` (about 80 callers) is the only place that changes scenes:

```gdscript
if BattleScreen.routes(scene_path):               # Battle mode + a BattleSession + not the title
	await BattleScreen.load_game_scene(scene_path)
else:
	…change_scene_to_file / _to_packed…; await get_tree().scene_changed
```

* First Battle transition (title → LevelTransition): `change_scene_to_node(BattleScreen.new())`, wait for
  `scene_changed`, then the instantiated scene goes into `GameViewport`.
* Every later one: the old scene is removed (so its exit handlers run first, as `change_scene` does), the
  new one is added. The same BattleScreen lives on; `game_scene_changed` is emitted.
* Leaving Battle is an ordinary transition to the title. Before its fade starts `Global` calls
  `BattleScreen.release_transition()` so that fade covers the whole screen; the scene change then frees the
  screen and everything in it.

### Window ownership

`BattleScreen._enter_tree` snapshots the root's content scale (size, aspect, mode, stretch) and applies
480×270 / KEEP / CANVAS_ITEMS, stretch and pixel snapping from the user's scaling / visuals settings.
`Level.apply_resolution_enforcement` and `Level.reset_resolution` return early while
`BattleScreen.owns_window()`. A per-frame comparison re-applies the canvas if the pause menu's settings moved
the root. On exit the snapshot is restored exactly; if the user changed size / scaling / visuals during
Battle, the new values are applied by the same rules as `WindowChanger` / `Level.reset_resolution` instead.

### Global UI

* GameHUD stays in the canvas: `BattleScreen.is_active()` selects its CENTER_TOP layout and the layer's
  `offset.y` is `GAME_RECT.y` (3), which puts its 256-wide strip exactly over the window.
* `Transition.custom_viewport = GameViewport`, and `Freeze.stretch_mode = KEEP` (the frozen frame is a 256×240
  picture shown 1:1). `freeze_screen()` captures whichever viewport the fade is currently drawn into.
* `Global.get_game_viewport()` (the root outside Battle, `GameViewport` during it) is used by the 1-up sound,
  `AudioManager.play_global_sfx`, `ScreenShaker` and `DropShadowRenderer`.

## 2. Findings that correct or extend doc 38

1. **`CanvasLayer.custom_viewport = null` does not work in Godot 4.6.** It prints
   `Cannot set viewport to nullptr` and keeps the old value. The way back to "the default viewport" is to assign
   the root window. Doc 38 5.3 says "set it back to null"; `BattleScreen._release_transition` assigns the root.
2. **The game's pipe cutscene is part of 1-1 → 1-2.** 1-2 is entered through `LevelTransition` and
   `PipeCutscene`, three game scenes in a row, all routed into the same `GameViewport`.
3. **`VisibleOnScreenNotifier2D` / `Enabler2D` report nothing without a renderer** (`--headless` uses the dummy
   one), so the enemy-activation check is a render test (`battle_screen_render_test.gd`), not a headless one.
4. A `-s` script is compiled before the autoloads exist. Tests reach `BattleScreen` / `BattleHandler` through
   `load()`, never by class name.
5. `--fixed-fps 60` makes every frame one 1/60 s step, which makes the physical checks (Mario against the
   walls, a real flagpole clear) deterministic and fast.
6. In 1-1 a pipe at x ≈ 190 blocks a straight run, so the right-wall check locks the camera at the level start
   (`Player.camera_right_limit`, what a locked-camera section does) and runs over the clear stretch.
7. `Settings.on_window_resized` saves the settings file on every `Window.size_changed`, and changing the content
   scale (which Battle does) counts. That is harmless for a player, but a test that changes settings or the window
   rewrites the user's file with its in-memory state. The tests and the capture tool therefore snapshot the file
   and put it back byte for byte (and restore the window size first).

## 3. Behaviour that is deliberately unchanged until later milestones

* A KO, Quit or the end of the match still shows the old result card (now over the window) and then goes to
  the title (`BattleHandler.end_match`). Doc 38 section 7 replaces this in milestone 3.
* Opponent #1 still has the milestone-1 (doc 37) live preview at 32×41 with mipmapped filtering; the other 33
  panes keep the placeholder. Doc 38 section 6 (atlas, 187×240 cells) is milestone 2.
* The strips are colour blocks; the badges are as before.

## 4. Where it still differs from `reference.jpg`

Measured on the 1920×1080 reference against the 1080p render.

| | reference | now |
|---|---|---|
| Playfield | about 1026×900 px, so 256×225 logical (a crop of the classic 240 rows) | 1024×960 px, the whole classic 256×240 |
| Playfield top | y 30 px (7.5 logical) | y 12 px (3 logical) |
| Strips | two of about 12.5 logical each, y 943-1046 px | two of 11, y 980-1072 px |
| Panes | thin orange borders, no ids, red target brackets on the first one | id and level text, KO cross, no target brackets |
| Course badge | "COURSE" caption over "1-1" | "1-1" only (a caption does not fit 32 px) |
| Alive badge | Mario icon over one large "35/35" | red square over stacked "35" and "/35" |
| HUD | SMB35's coin counter and round timer | the existing classic HUD; its long locale key overruns the window on the right in this sandbox (doc 38 R4) |
| Extra surfaces | attacker-target selector and item box over the window | none yet |
| TIME / RANK text | none | kept from the earlier milestone, in the corners |
| Colours | wallpaper (252,185,36)-ish with a darker lower edge | flat approximations |

The first two rows are a geometry decision, not a bug: showing 225 of the 240 rows would change what the
player sees from Classic. Every number is in `BattleHudLayout`, so a later pass can move or resize the window,
the strips and the frame without touching `BattleScreen`.

## 5. Tests

| File | What | Command |
|---|---|---|
| `tests/battle_hud_test.gd` | pure layout; data binding on a standalone screen; result overlay | `godot --headless --fixed-fps 60 --path . -s tests/battle_hud_test.gd` |
| `tests/battle_screen_test.gd` | composition, 256×240 sizing, Mario against both walls, GameHUD, fade redirect, pause, root-versus-game-viewport call sites, a real 1-1 → 1-2, window ownership, settings drift, Quit restores, Classic unaffected | `godot --headless --fixed-fps 60 --path . -s tests/battle_screen_test.gd` |
| `tests/battle_screen_render_test.gd` | wallpaper behind the window, window = exactly 256 classic columns, HUD over the window, enemy activation (+96 px awake, +190 px asleep), Mario at the wall, the fade stays inside the window; saves screenshots | see the header of the file (Xvfb + GL Compatibility) |
| `tests/battle_preview_test.gd`, `battle_session_test.gd` | unchanged logic; the HUD integration test now drives a standalone BattleScreen | as before |

Removed (they encoded the 426×240 overlay design): "Battle forces the native 16:9 resolution", "all 34 slots are
on screen and outside the gameplay area", `center == Rect2(85, 0, 256, 240)`, "HUD survives a scene change",
"leaving Battle returns to title" after a KO.

Mutation checks done by hand (each makes exactly the intended test fail): removing the `Level` resolution
guard, putting `DropShadowRenderer` back on the root viewport, putting `AudioManager.play_global_sfx` back on
the root viewport.
