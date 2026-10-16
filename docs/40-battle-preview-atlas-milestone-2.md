# 40 — Battle screen, milestone 2 (previews at resolution): what was built and measured

Status: implemented on top of `623f453` (doc 38 section 10, milestone 2). Milestone 3 (round lifecycle) followed in doc 41; milestone 4 (strip /
badge content) is not started. Nothing in the layout, wallpaper, frame, badges, strips, `GameViewport`, `BattleSession`
or the preview tracks changed.

## 1. What now exists

```
BattleScreen (480x270 canvas)
├─ GameWindow → GameViewport (256x240)           the real game, unchanged
├─ PreviewAtlas: SubViewport 1337x1220, UPDATE_ALWAYS               ← the only preview render target
│  └─ BattlePreviewCell x34   187x240 texels each, 1:1 gameplay scale, clip_contents, NEAREST
│       draws BattleMiniGameRenderer (live, World 1-1) or BattlePlaceholderRenderer (fallback)
└─ BattleOpponentPane x34     32x41 logical, on the canvas (display resolution)
   ├─ Picture: TextureRect showing its own AtlasTexture region, ShaderMaterial = 4-tap footprint downsample
   └─ Overlay: frame, contestant number, level text, KO wash and cross (drawn at display resolution)
```

| File (`Scripts/Classes/Battle/` unless noted) | Role |
|---|---|
| `BattlePreviewAtlas.gd` | The shared `SubViewport`, plus the pure geometry (`CELL_PX`, `cell_rect(i)`, `size_px()`, `memory_bytes()`) |
| `BattlePreviewCell.gd` | One opponent's 187x240 picture (was the picture half of `BattlePreviewSurface`) |
| `BattleOpponentPane.gd` | One canvas pane: atlas region + shader, and the display-resolution overlay (the other half) |
| `Scenes/Parts/BattlePreviewDownsample.gdshader` | The downsample shader |
| `BattleMiniGameRenderer.gd` | `ZOOM = ACTOR_SCALE = 1.0`; camera and sprite positions are whole texels (the classic camera snaps too) |
| `BattleScreen.gd` | Builds the atlas, 34 cells and 34 panes; all 34 tracks are created; the dev view is now an atlas region |
| `BattlePreviewDriver.gd` | Removed `debug_all()` (all 34 are live now); `debug_full_view()` kept |
| `BattlePreviewAssets.gd`, `BattlePreviewSprite.gd` | No more mipmaps (nothing is minified at 1:1) |
| `BattlePreviewSurface.gd` | **Deleted**, replaced by cell + pane |

Unchanged: `BattleSession`, `BattleBotSimulator`, `BattleContestant`, `BattleCourse`, `BattleLevelSketch`,
`BattlePreviewResolver`, `BattlePreviewTrack`, `BattlePreviewFrame`, `BattleHudLayout`, the pause menu, and everything outside
`Scripts/Classes/Battle/` apart from the new shader file. Classic code is not touched.

## 2. Atlas

* Cell: **187x240** texels, which is the classic camera band (world y -208..32, 240 tall) at 1:1, 240 x the pane aspect (32/41).
  The pane aspect is matched to 0.1 %, so downsampling never distorts.
* Layout: **7 x 5** cells (34 used), **4 texels of padding** around each (2 on the outer edge).
  Atlas = 7 x (187 + 4) by 5 x (240 + 4) = **1337 x 1220**.
* Memory: colour target 1337 x 1220 x 4 B = **6.22 MiB** (RGBA8). Godot's own counter moved by about **+12.4 MB** when the
  atlas was added (the GL viewport also allocates a depth/stencil buffer, which is the likely second half; not verified).
* Rendered once per frame in one pass (`UPDATE_ALWAYS`); Godot draws child viewports before the root, so there is no frame of
  latency. Cells only re-record their draw commands when their picture changed (about 14 cells per frame at normal speed).
* No 34 viewports, no hidden `Level`/`Player` scenes: the screen contains exactly two `SubViewport`s (the game window and the atlas).

## 3. How a pane downsamples

A pane shows `AtlasTexture(atlas.get_texture(), region)` through a `ShaderMaterial` (one shared `Shader`, 34 materials, because
each carries its own region):

```
vec2 o = fwidth(UV) * 0.25;                       // 1/4 of this screen pixel's footprint in the atlas
COLOR = 0.25 * (tap(UV+(-o.x,-o.y)) + tap(UV+(o.x,-o.y)) + tap(UV+(-o.x,o.y)) + tap(UV+(o.x,o.y)));
tap(uv) = texture(TEXTURE, clamp(uv, region.xy, region.xy + region.zw))   // region = this cell, inset 0.5 texel
```

Four bilinear taps spread over the pixel footprint are about a box filter over up to 4x4 texels: smooth at any display scale
(0.68x at 1080p, 0.46x at 720p, 0.91x at 1440p) with no mipmaps (Godot 4.6 cannot make them for viewport textures). Bleed is
prevented twice: 4 texels of padding, and every tap is **clamped into the pane's own cell inset by half a texel**, so a neighbour
(or the padding) can never be read, whatever the scale. The frame, number, level text and KO marking are a separate `Overlay`
control above the picture, drawn in the canvas at display resolution; none of it is in the atlas image.

## 4. Live versus fallback

* All 34 contestants get a `BattlePreviewTrack`; each cell draws live while its frame is valid (it is on World 1-1).
* When a contestant's run leaves 1-1 (course 1 and later are not supported) the frame becomes invalid and **that cell** draws the
  placeholder in the same atlas region; the pane is unchanged. Previews off (`BattleScreen.live_previews = false`) puts all 34 on the
  placeholder.
* Counts (`seed=19`): 34 live at the start. Later, contestants that have cleared 1-1 fall back one by one: in
  `docs/battle-screen/12-m2-all34-live-1080p-tick90.png` nine panes are on the placeholder ("1-2") next to live 1-1 panes at the flagpole, and in the
  `speed=20` frame-time run 24 of 34 were still live at the end of the 500 frames.
* **KO:** the session's state is never delayed. The pane's red frame, the alive count and the rank follow it at once; the KO wash and cross
  wait for the picture's own death animation to finish (`BattlePreviewCell.marked()`), as before. No second simulation exists.

## 5. Dev view

`--battle-preview-debug` (after `--`, debug builds) shows opponent #1's atlas cell at its native **187x240** over the centre of the
window: a `TextureRect` whose `AtlasTexture` is the same atlas region the pane samples (`14-m2-debug-native-cell1-187x240-at-4x.png`).
It adds no viewport and no draw work to the atlas.

## 6. Measurements

Machine: the cloud sandbox. No GPU, so the rendered numbers use Mesa software GL (llvmpipe) and are **not representative of a real
GPU**. They are useful as a before/after comparison on the same machine. "Before" = `623f453`.

### Preview CPU (headless; driver update + recording every cell's draw commands, `tests/tools/battle_preview_bench.gd`)

| | before (34 live, old 26x33 cells) | after (34 live, atlas) |
|---|---|---|
| Normal speed | 0.61 ms/frame | **0.73 ms/frame** |
| Accelerated (`speed=20`) | 1.23 ms/frame | **1.46 ms/frame** |
| Previews off (placeholders) | 0.145 ms | 0.17 ms |

Where it goes at normal speed: preview driver update about 0.42 ms (was 0.37; the view is now the real 187 texels wide, so more enemies are
awake), cell draw recording about 0.12 ms (about 14.5 draws at about 8 us), the rest is the per-frame `refresh()` of 34 cells and 34 panes (integer
signatures, no string building). A GDScript draw call costs about the same as before; the pictures are simply drawn into a different surface.

### Rendered frame time and memory (software GL, 1920x1080 window, `tests/tools/battle_preview_frametime.gd`, 500 frames)

| Build | speed 1 | speed 20 | texture mem |
|---|---|---|---|
| before, placeholders only | 21.8 ms | 23.6 ms | 30.3 MB |
| before, default (opponent #1 live) | 21.0 ms | 22.4 ms | 36.1 MB |
| before, 34 live (old 26x33 cells) | 27.3 ms | 29.7 ms | 36.1 MB |
| after, placeholders only (atlas rendered) | 30.5 ms | 33.7 ms | 42.7 MB |
| **after, 34 live** | **38.4 ms** | **40.8 ms** | **48.6 MB** |

Draw calls per frame: 249 before, 287-326 after (34 pane draws + their overlays, plus the atlas pass).

**Reading it honestly:** relative to the previous default build (one live preview) the all-34 atlas build is about 17 ms slower per
frame under software GL, about 11 ms slower than the previous 34-live build. About 9 ms of that is a fixed cost that is paid even with
placeholders only: the 1.6-megapixel atlas is cleared and redrawn every frame and 34 panes run a 4-tap shader. A CPU rasteriser pays per
pixel for all of it; a GPU pays almost nothing for 1.6 Mpx of flat quads, so I would not expect this to show on a real GPU, but I could not
measure that here. **If a regression shows on the Plex machine, run the frame-time tool there.** The obvious (not applied) mitigation is to
re-render the atlas only on frames where a cell changed; it only helps while nothing moves (paused, results), because live cells change nearly
every frame.

## 7. Tests

| File | What | Command |
|---|---|---|
| `tests/battle_preview_atlas_test.gd` (new, headless) | cell size 187x240; atlas 1337x1220; 34 unique, non-overlapping regions with >= 4 texels padding; tap-clamp rect inside each cell; `ZOOM == ACTOR_SCALE == 1.0`; 34 panes map to 34 unique regions of the one shared atlas; exactly 2 `SubViewport`s, no `Player`/`Level` nodes in the preview machinery; all 34 live on 1-1; an unsupported course falls back to the placeholder in the same region; previews off = all placeholders; **authoritative Battle state is bit-identical with previews on and off** (ticks, alive, winner, snapshot, rng state, ranking, with external KOs); the dev view is an atlas region and adds no viewport; Classic has no atlas | `godot --headless --fixed-fps 60 --path . -s tests/battle_preview_atlas_test.gd` |
| `tests/battle_preview_render_test.gd` (new, GL) | at **1080p (4x)**, **720p integer (2x, letterboxed)** and **720p fractional (2.67x)**: every pane matches a software downsample of its own atlas cell (worst mean error 0.036 / 0.042 / 0.056), is closer to its own cell than to another, has >= 6 distinct colours; 34 flat-coloured cells come out exactly (worst channel difference 0.002) at every pane edge and corner = **no bleed** | see the header of the file |
| `tests/battle_preview_test.gd` | now expects all 34 live and a dev view; the mipmap check became "no mipmaps"; determinism and track tests unchanged | headless |
| `tests/battle_hud_test.gd`, `tests/battle_screen_test.gd`, `tests/battle_session_test.gd` | unchanged logic; renamed `surfaces` to `panes` | headless |
| `tests/battle_screen_render_test.gd` | one adaptation: its "no level sky around the window" probe no longer samples inside the opponent pane columns, which legitimately show sky | GL |

Classic is unaffected: `battle_screen_test.gd`'s Classic checks and the new "no atlas, one Player" check pass, and
`battle_screen_render_test.gd` leaves the user's `settings.cfg` byte-identical.

## 8. Screenshots (`docs/battle-screen/`, real project, GL Compatibility, sandbox stand-in art)

| File | |
|---|---|
| `10-…-1080p-tick14.png`, `11-…-tick40.png`, `12-…-tick90.png` | the whole screen at 1080p, all 34 live, early / middle / late in a match |
| `13-m2-all34-live-720p-integer-2x.png`, `18-…-720p-fractional-2.67x.png` | 720p with integer (letterboxed) and fractional scaling |
| `14-m2-debug-native-cell1-187x240-at-4x.png` | opponent #1's atlas cell at native resolution, shown at 4x (the debug view) |
| `15-…-left-panel-1080p.png`, `16-…-left-panel-720p.png` | the left panel close up |
| `17-m2-bleed-test-34-flat-colours-1080p.png` | the bleed test: 34 flat colours, no mixing at any edge |

Compared with the accepted composition (`07-m1-composition-1080p.png`) and `reference.jpg`: the layout is identical to milestone 1 (same
rectangles); the panes are portrait 32x41, 3 columns x 6 rows per side, with the corner badges, and now each shows a real full-height crop of the
level with a recognisable Mario, terrain, pipes, bricks, question blocks and Goombas. As in doc 39 the art is the stand-in pack and the HUD text is an
untranslated locale key in this environment.

## 9. Still different from the reference / not done

* The reference's panes are slightly larger relative to its canvas and have no ids or level text; ours keep them (display-resolution overlay).
* The previews show World 1-1 only. A contestant that has cleared 1-1 shows the simple placeholder (and "1-2" in its level text) until
  further courses are added (out of scope here).
* No target brackets, no incoming-attack display, no moving hazards in the previews (out of scope).
* GPU cost is unmeasured (section 6).
