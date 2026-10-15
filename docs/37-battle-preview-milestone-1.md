# 37 — Battle Mode: opponent preview, milestone 1 (World 1-1, opponent #1)

> **Rendering superseded by `38-battle-screen-architecture.md`.** §5 (1.6× zoom, 1.35× actors)
> and §6 (pixel-perfect vs smooth) worked around 26×33-pixel cells that should not exist. The
> track, driver, sketch and assets described here are unchanged.

Implements milestone 1 of `36-battle-preview-architecture.md`: **one** opponent window
(opponent #1, World 1-1) looks like a small live Mario run. The other 33 windows, and any
level other than 1-1, still use `BattlePlaceholderRenderer`. This is a visual prototype of the
architecture, not a scale-up pass.

**Rule kept everywhere:** `BattleSession` / `BattleBotSimulator` stay the only simulation. The
preview reads authoritative state and events and never writes anything back.

All pictures are in `docs/battle-preview/`. **They were rendered in a sandbox with no ROM-derived
art**, so they use a tiny *stand-in* resource pack (flat colours, `tests/tools/make_standin_pack.py`)
painted over the repository's green template sprites. Level geometry, enemy positions,
animation frames and every code path are the real ones; the colours are not the game's real
art. `05-repo-template-art-only.png` shows the same frame with only the shipped template art.

## 1. What was added

| File (`Scripts/Classes/Battle/`) | Role |
|---|---|
| `BattleSession.gd` (+ small edits) | Additive event log (`HIT`, `POWER_UP`, `LEVEL_CLEAR`, `KO`), `snapshot()` for determinism checks |
| `BattleHandler.gd` (+ small edits) | Publishes `presentation_alpha` (display only); goal-script test moved to `BattleCourse` |
| `BattleCourse.gd` | Course numbering / scene path / the shared "what is a goal" test |
| `BattleLevelSketch.gd` | Read-only level decoder + walk line + planned jumps (see 2) |
| `BattlePreviewResolver.gd` | Small explicit-theme art resolver (see 3) |
| `BattlePreviewAssets.gd`, `BattlePreviewSprite.gd` | Baked, mipmapped, shared art |
| `BattlePreviewTrack.gd` | One opponent's visual reenactment (see 4) |
| `BattlePreviewFrame.gd` | Plain data handed to the renderer |
| `BattlePreviewDriver.gd` | Feeds session state/events to tracks, steps them, dev flags |
| `BattleMiniGameRenderer.gd` | Draws a frame (a few textured quads) |
| `BattlePreviewSurface.gd`, `BattlePreviewRenderer.gd`, `BattlePlaceholderRenderer.gd`, `BattleHud.gd` | Surface takes an optional live renderer + frame; falls back to the placeholder |

Dev tools: `tests/tools/battle_preview_capture.gd` (renders the real Battle screen),
`tests/tools/battle_preview_bench.gd` (CPU cost), `tests/tools/make_standin_pack.py`.
Tests: `tests/battle_preview_test.gd`.

### Event stream
`BattleSession.step()` diffs each bot before/after `step_bot` and logs
`{tick, id, type, a, b}`: `HIT` (power dropped, `a` = new power), `POWER_UP`, `LEVEL_CLEAR`
(`a` = levels cleared), and `KO` (in `_apply_kos`, `a` = `KoCause`). It reads state only. It
never calls the rng. **Verified:** for 14 seed/time points the match results are bit-identical
to the unmodified code at `6eb7562` (golden hashes in the test), and with all 34 previews
attached and updating every tick the full `snapshot()` including `rng.state` equals the run
without previews.

Note: with the current bot model a **HIT can never occur in 1-1** (bots start small and only
gain power on a level clear), so the shrink/blink path is exercised by synthetic event feeds in
the tests, not by real matches. `POWER_UP` does occur (on clear) and is shown as Mario
growing at the castle.

## 2. How real 1-1 data is reused (`BattleLevelSketch`)

Built from `PackedScene.get_state()` of `res://Scenes/Levels/SMB1/World1/1-1.tscn`. **No level,
`Player`, `TileMapLayer` or other scene node is instantiated.**

- **Terrain:** `tile_map_data` of the `Tiles` instance decoded cell by cell (format 0).
  Solidity is read from the real `TileSet`'s physics polygons (`Tiles.tscn`'s `tile_set`
  resource, also from SceneState), including one-way platforms.
- **Blocks:** scene-collection cells (source 1) mapped through the TileSet's scene ids
  (brick / `?`; invisible, coin and death-pit cells ignored) plus `Blocks/*` nodes.
- **Enemies:** `Enemies/*` instances by scene path (Goomba, Green Koopa; unknown kinds are
  counted and dropped). 1-1 gives 16 Goombas + 1 Koopa.
- **Start / goal / castle:** `Player`, `EndFlagpole` (x=2920), `EndSmallCastle` (x=3016); the
  castle's tile picture comes from `SmallCastleVisual.tscn`.
- **Theme:** root `theme` / `theme_time` / `campaign` (defaulting like `LevelClass`).
- **Walk line + jumps:** per tile column the standing surface Mario would use, pits
  (tile columns 53-54, 70-72, 137-138), and for every rise / pit a ballistic jump, each
  **validated against the solid grid at build time**. Landing is exact by construction.

## 3. How art is reused (`BattlePreviewResolver`, `BattlePreviewAssets`)

`ResourceSetterNew` cannot be reused: it is a `Node` and reads `Global.level_theme`,
`theme_time`, `current_campaign`, `world_num`, `level_num`, the player's character and mutates
`Global` overrides. I therefore wrote a deliberately small resolver that repeats only its two
pure rules: **resource-pack precedence** (first pack in `Settings.file.visuals.resource_packs`
that has the file wins, `res://Assets` mirrored under `<config>/resource_packs/<pack>`) and the
**walk down a JSON's `variations`** (theme -> time -> campaign -> World1/Level1 ->
`RoomType:` -> `GameMode:` -> `Character:`) with the theme passed in explicitly.
**Limitation:** `config:`, `flag:`, `Metadata`, `choices` and `sequence` variation keys are not
interpreted; a JSON needing them fails to resolve and the preview falls back to the placeholder.
The tests check it against the real JSONs (Underground Goomba rect, time-of-day deco, a temp
resource pack overriding base art, and that `Global.level_theme` is ignored).

`BattlePreviewAssets` bakes once per (level, theme, time, campaign) and shares the result:
one 3696x288 RGBA **strip** (deco, castle, flagpole, terrain, blocks via `blend_rect`), the
parallax hills, and ~40 cropped Mario/Goomba/Koopa frames, all with **mipmaps**. The 34
previews would share the same objects (`build()` returns the cached instance; test-checked).
Sprite frame rects come from the real sprite JSONs. Cache is dropped when the HUD leaves.

## 4. How the preview avoids becoming a second Mario engine (`BattlePreviewTrack`)

- It owns **no gameplay outcome**. Inputs are the session's keyframes and events only.
- Mario's horizontal motion is a one-sided follower of the bot's authoritative position
  (`start + progress * (goal - start)`, 2 s behind). There is no input, collision response,
  pathfinding or physics of Mario's own: y comes from the precomputed walk line, and jumps
  are scripted parabolas validated against the grid.
- Enemies only walk left, fall into pits and die when told; there are no enemy-vs-enemy rules.
- Outcomes are **staged, not simulated**: a HIT/hazard KO makes a scripted Goomba walk in (or
  Mario's pit jump falls short; or it "just happens" if nothing believable can reach him); a
  time-out KO dies in place; a LEVEL_CLEAR runs to the pole, slides, walks to the castle and
  fades. Mario can never die or get hurt on his own.
- It never writes to the session, never uses the session rng (own RNG seeded from
  `(seed, id, course)`), steps at a fixed 30 Hz of *session* time, and snaps instead of
  chasing when it falls behind, so fast sim speeds and hitches stay valid (test-checked).
- Authoritative HUD state (alive count, KO status/border, rank) is never delayed; only the
  picture and its own KO marking trail by `LAG = 2 s`.

## 5. Rendering

`BattlePreviewSurface` keeps its job; opponent #1 gets `live_renderer` + `frame`. Whenever the
frame is invalid (not opponent #1, an unsupported course, or after the 1-1 clear finishes) the
`BattlePlaceholderRenderer` draws, using authoritative state. No SubViewports, no level or
`Player` nodes, no per-bot trees. Drawing is: sky rect, hills (a few quads), **one region draw
of the strip**, flag, <=~10 sprites, fade. The view is a 1.6x zoomed, ground-anchored crop of the
classic camera and actors are drawn 1.35x larger, so they stay readable in a 26x33 cell.

Dev switches (debug builds, after `--` or env var): `--battle-preview-debug`
(`SMB1R_BATTLE_PREVIEW_DEBUG=1`) also draws opponent #1 at 256x240 over the centre;
`--battle-preview-all` (`SMB1R_BATTLE_PREVIEW_ALL=1`) puts all 34 windows on the live renderer.
`BattleHud.live_previews = false` turns previews off (baseline).

## 6. Pixel-perfect vs smooth

Battle is **not** forced into either. The two captures use only a window switch
(`content_scale_mode` + 2D snapping, mirroring `WindowChanger.visuals_changed`); the saved
setting is untouched. See `03-left-panel-pixel-vs-smooth.png`, `03-cell1-pixel-vs-smooth.png` and
the two full screens. In short: pixel-perfect gives a 26x33 framebuffer cell where small Mario
is ~5 px tall and a Goomba a ~4 px smudge (still readable as "Mario running, enemy ahead" but
soft); the smooth presentation renders the same cell at 104x132 and Mario, blocks, pipes, Goombas
and the pit are crisp. The preview code is identical in both.

## 7. Cost (34-preview stress mode)

Measured with `tests/tools/battle_preview_bench.gd` under Xvfb + software GL (so **CPU
only**: the GPU is not measured), emulating 60 fps, CPU of the preview-related work per frame:

| | HUD process (of which driver) | draw recording | total |
|---|---|---|---|
| previews off (placeholders) | 125 us | 7 us | 0.13 ms |
| normal: opponent #1 live | 173 us (41) | 18 us | 0.19 ms |
| stress: 34 live, 1x speed | 591 us (446) | 129 us (14.5 draws x 9 us) | 0.72 ms |
| stress: 34 live, 4x sim speed | 1271 us (1127) | 184 us | 1.45 ms |

One-time bake at HUD creation: sketch ~0.2 s (first load) and art ~0.15 s; memory: strip
~4.2 MB (+ mips), sketch tens of KB. These are within doc 36's "< 2 ms CPU per frame" target.

## 8. Tests

`godot --headless --path . -s tests/battle_preview_test.gd` covers: decoded pits / goal / castle /
start / enemy counts and types; solid and pit facts; every planned jump terrain-free;
resolver rules; asset bake and sharing; event consistency; **identical match results with and
without previews and against the pre-change code**; across 80 seeds Mario never overlaps solid
terrain, is never over a pit except leaping or dying, never passes the pole before the clear,
every KO and clear plays to its end; the same under 5 s / 25 s update gaps; synthetic
HIT / KO / time-out / POWER_UP staging; two identical runs give identical frames; only opponent
#1 live and the other 33 on the placeholder in the real HUD; HUD state not delayed.
The existing `battle_session_test.gd` and `battle_hud_test.gd` still pass.

## 9. Known limits of this milestone

- Only World 1-1, opponent #1; after the 1-1 clear plays out, the window goes back to the
  placeholder (authoritative course) for the rest of the match.
- No clouds, no moving hazards, no item/coin/block-bump effects, no pipes/warps.
- The bot's authoritative pace (~35 px/s) makes the run a slow walk with quick leaps; this is
  deliberate (the preview must not change outcomes).
- Koopa shells slide away after a stomp; no other enemy interactions.
- Only the stand-in pack was available when rendering here; real ROM art has not been seen.
