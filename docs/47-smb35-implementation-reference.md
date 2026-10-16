# 47 — SMB35 Battle Mode Implementation Reference

Status: research and specification only. No gameplay code, scene, test, balance or targeting change was made while
writing this document. It is the authoritative build specification for bringing Battle Mode closer to Super Mario
Bros. 35 (SMB35). Implementation happens in later sessions, one milestone at a time (section 18), starting from the
handoff in section 19.

Baseline compared: branch `battle-mode`, commit `fa88f68` (M6a, doc 46). Docs 35–46 are the history of that
baseline; where this document and an earlier doc disagree about *what SMB35 does*, this document wins. Where they
disagree about *what Battle should do*, nothing changes until Zack approves (every such case is marked
**ZACK APPROVAL**).

## 0. How to read this document

### 0.1 Evidence source and privacy boundary

* Source: `reference.mp4` in the repository root (a recorded SMB35 playthrough, 1920×1080, 60 fps, AV1,
  1115.8 s). It is **local-only**: it is excluded through `.git/info/exclude` (a local, uncommitted rule), it is never
  committed, and it is never uploaded. Frame extraction for analysis stayed in local scratch or workspace
  folders outside the repository. Nothing in this document reproduces imagery or audio: it records only
  measurements, timings, counts and short descriptions.
  *(Update: the video is public, `https://www.youtube.com/watch?v=AUcFTEfFp58`; for that video alone, frames and short contact
  sheets may be viewed when building the Battle UI, and the video is still never committed or redistributed. This does not
  extend to any ROM or ROM-derived asset. See `tools/reference/README.md`.)*
* The video has two complete matches, both won by the recording player:
  * **Match 1 (M1)**: a time-limited *Special Battle* event (34 players, starts on 1-2). Match start at about t=20 s,
    GO at t≈25 s, won at t≈412 s.
  * **Match 2 (M2)**: a standard *35-Player Battle* (35 players, starts on 1-1). "Here we go" at t≈499.5 s, GO at
    t≈505.25 s, won at t≈1072 s. The results report a play time of 09:18.
  * Special-Battle values (M1) can differ from standard ones. Where M1 and M2 disagree, **M2 is the standard
    reference**, and an M1-only value is marked as such.
* Timestamps are seconds from the start of `reference.mp4`, written `t=NNN`. Values sampled at 1 fps are ±0.5 s. Values
  found by frame-change detection at 30 or 60 fps are ±0.03 s.
* Geometry is measured in 1080p pixels and given in **logical px** (÷4), which is the Battle canvas unit
  (`BattleHudLayout.CANVAS = 480×270`, doc 38).
* Method: local frame sampling, pixel-run and colour-class measurement, and frame-difference change detection on HUD
  regions. In the first research session, sampled frames were also inspected visually. The working notes and the
  local helper scripts (text output only) are in `~/.hermes/profiles/zack/workspace/research/smb35/` (not in the repo).

### 0.2 Field meanings

Each requirement block has these fields:

* **REFERENCE**: what SMB35 visibly does, with timestamps.
* **CURRENT**: what `fa88f68` does. The status is one of *matches*, *partial*, *differs* or *missing*.
* **TARGET**: the behaviour to build.
* **NOTES**: implementation notes, naming the systems and classes involved where they are known.
* **ACCEPT**: acceptance criteria a developer or tester can check.
* **PRIORITY**:
  * P0: required for SMB35-like function.
  * P1: important fidelity or usability.
  * P2: visual polish.
  * P3: optional.
* **CONFIDENCE**:
  * *Confirmed*: measured, or seen more than once.
  * *Strongly inferred*: one observation, or a consistent but indirect pattern.
  * *Unknown*: needs more evidence. Do not build behaviour marked Unknown beyond what the block says.

### 0.3 Scope that this document does not change

These decisions stay in force:

* 1 real player and 34 simulated bots, with no networking (doc 35 §1).
* The 480×270 canvas with the classic game in its own `SubViewport` (doc 38).
* `BattleSession` decides; presentation only reads (docs 42–46).
* Real incoming enemies are the game's own prefabs (doc 46).

SMB35's opponents are real people. Ours are `BattleBotSimulator` records, and that stays. Whatever SMB35 shows about
an opponent must be produced from bot state.

## 1. Executive Summary

### 1.1 Major systems observed in SMB35

1. **Screen**: a centre game window (256×224 visible game px at 4×) framed in gold. 17 live opponent panes sit on each
   side (3×6, with the inner-top slot used by a badge). Two strips run under the window: the incoming bar, then a
   status strip with "WATCH OUT!", the chest bonus and an eye counter.
2. **HUD inside the game window**: a coin counter, an item box (20 coins, X button), a four-way targeting selector, and
   a large timer with a clock icon. The classic SMB1 score/world/time row is absent.
3. **Targeting**: four modes (Lowest Time, Random, Most Coins, Attackers) and a red four-corner reticle on the current
   target's pane. Each defeat sends that enemy to the target. The reticle's flight from the game window to the target
   pane *is* the send animation.
4. **Incoming**: enemies sent to the player travel right-to-left along a coloured bar and are released into the level
   at a jagged boundary. Thin red lines connect attacking panes to the player's bar, and "WATCH OUT!" appears. In the
   level, released enemies appear with a pale palette.
5. **Timer economy**:
   * A low starting time (about 35 s in a standard match). It is refilled by defeats (+1…+5), by the flagpole (+15)
     and by a KO credit (filled to 400).
   * It is capped at 400.
   * It ticks at 1 Hz, then at **2 Hz once 5 or fewer are alive**.
   * It is frozen during the flag and castle walk.
6. **Coins and items**: coins buy an item roulette for 20. The roulette spins for about 3 s while play continues, holds
   for about 2 s, then applies Mushroom, Fire Flower, Star or POW. A chest bonus accumulates and is awarded at the end.
7. **Courses**: a non-linear course sequence with remixed warp zones. Course changes have no "WORLD x-y" card: a 0.5 s
   fade, then play resumes within about 2 s.
8. **Elimination**: KO'd panes become in-place blue "KO + placement" cards with a pop/smoke animation. An opponent the
   player KO'd gets a distinct orange card. The alive badge reads "N/total".
9. **Match flow**: matchmaking → "Here we go…" → Ready → 3 → 2 → 1 → GO! → play → win medal → bonus count-up → Level
   Up → Ranking → Results → Main Menu / Rematch.

### 1.2 Major differences from Battle at `fa88f68`

| Area | SMB35 | Battle now |
|---|---|---|
| Timer | about 35 s start, kill/flag/KO bonuses, cap 400, 2 Hz at ≤5 alive, frozen at flag | flat 600 s per contestant, 1 Hz, no bonuses |
| Window | 256×224 visible, HUD drawn by SMB35 inside the window | 256×240, classic GameHUD row in the window |
| Targeting | 4 modes, persistent visible target, reticle | random survivor per send, invisible |
| Send visual | reticle flies window→pane in about 0.25 s | gold line with an enemy head over 0.55 s, plus a yellow pane tint |
| Bot→bot traffic | not shown | faint white lines between panes |
| Incoming UI | moving icon bar, red attacker lines, WATCH OUT!, eye count | static "INCOMING" icon list with ACTIVE/QUEUED counts |
| Incoming in level | pale palette, right screen edge | native look (doc 46 decision), right edge ≥80 px ahead |
| Re-send | every defeat sends (M1: defeated 215 = sent 215) | incoming enemy deaths never send (rule R0) |
| Coins/items | coin economy, 20-coin roulette, chest bonus | none |
| Courses | non-linear, remixed warps, about 0.5 s transitions | linear 1-1→8-4, classic transition card |
| Previews | every opponent shows their own live course | live only on 1-1; placeholder elsewhere |
| KO | in-place blue card with placement and pop animation; orange for player KOs | dark-red X overlay, red frame, id label |
| Start | Ready (about 1.5 s), 3, 2, 1 (1 s each), GO! | READY 2.5 s, GO! 0.8 s |
| Results | medal, bonus, Level Up, Ranking, Results, Main Menu/Rematch | one text card that auto-advances to the next round after 10 s |

### 1.3 Highest-priority gaps

1. **B35-TARGET-001…004**: a persistent, visible current target with the reticle and its send flight. P0, no conflict
   with accepted decisions, so this is milestone 1.
2. **B35-TIMER-001…009**: the SMB35 time economy for the player *and the bots*. P0 but **ZACK APPROVAL**: it replaces
   the 600 s model and changes balance.
3. **B35-ATTACK-003 / B35-ENEMY-002**: the re-send rule (P0, **ZACK APPROVAL**: conflicts with R0).
4. **B35-COIN-001…006**: coins, roulette and items (P0 for SMB35 feel, **ZACK APPROVAL** for scope).
5. **B35-INCOMING-001…006**: the incoming bar and attacker lines (P1). The tint is **ZACK APPROVAL**.
6. **B35-LAYOUT-001/002**: the 224-row window and in-window HUD (P1, **ZACK APPROVAL**: changes doc 38 geometry).

## 2. Screen Architecture and Layout

All rectangles are logical px on the 480×270 canvas (1080p ÷ 4). The source frame is t=62 (M1), cross-checked at
t=515, t=760 and t=1000.

### B35-LAYOUT-001 — Game window shows 256×224 game pixels

* **REFERENCE**
  * The game image spans 1080p x 448–1471 and y 32–927, which is 1024×896 = 256×224 game px at exactly 4×.
  * Logical rect: **(112, 8, 256, 224)**.
  * A dark 2 px outline (0.5 logical) sits just outside it (y 30–31, x 444–447). Measured at t=62, re-checked at
    t=515.
* **CURRENT**: *differs*.
  * `BattleHudLayout.GAME_RECT = (112, 3, 256, 240)`.
  * The `SubViewport` is 256×240 and shows all 240 rows.
* **TARGET**
  * The visible window is 256×224 at (112, 8).
  * The game simulation keeps its 256×240 viewport: camera walls, enabler rects and physics must not change.
  * Show 224 of the 240 rows by cropping the *display*, not by resizing the `SubViewport`.
* **NOTES**
  * Which 16 rows SMB35 hides is **Unknown**. NES overscan practice (8 top + 8 bottom) is the likely choice but was
    not measured.
  * Implement as a clipping Control around the `SubViewportContainer` with a −8 px offset (or a `TextureRect` showing
    a region of the viewport texture), so `get_viewport_rect().size == (256,240)` remains true (the doc 38
    invariant).
  * Strip A/B and the frame move with it (B35-LAYOUT-003).
  * **ZACK APPROVAL**: this changes doc 38 geometry and hides 16 rows of gameplay.
* **ACCEPT**
  * The window rect is (112,8,256,224) on whole logical pixels.
  * The game viewport still reports 256×240.
  * The camera walls are still at ±128.
  * Crop rows are documented and covered by a layout test.
  * The 4× integer scale is preserved at 1080p.
* **PRIORITY**: P1. **CONFIDENCE**: size Confirmed; cropped rows Unknown.

### B35-LAYOUT-002 — The HUD lives inside the game window; the classic HUD row is absent

* **REFERENCE**: four HUD elements are drawn over the game image (t=62, t=517.6, t=760, t=1000):
  * Coin counter, top-left, about (115, 10, 35, 9).
  * Item box below it, about (112.5, 20, 40, 40).
  * Targeting selector, centred near x=240, about (200, 14, 95, 37).
  * Timer, top-right, about (296, 10, 69, 18).
  * There is no "MARIO 000000 / WORLD / TIME" classic row.
* **CURRENT**: *differs*. The classic `GameHUD` (inside the `Global` autoload) is anchored `CENTER_TOP` onto the
  window (`GameHUD.gd:37-38`). TIME and RANK are drawn as canvas labels above the panel grids (`BattleScreen._build`,
  `status_left/right`).
* **TARGET**
  * During Battle the classic HUD row is hidden.
  * A Battle-owned HUD layer draws the coin counter, item box, selector and timer over the window at the positions
    above.
  * The canvas TIME/RANK labels are removed.
* **NOTES**
  * Build it as a new canvas child of `BattleScreen` above `GameWindow`, with positions in `BattleHudLayout` and
    values from `BattleSession`.
  * Hide `GameHUD` in Battle with a `BattleScreen.is_active()` branch; do not delete it.
  * Element details: B35-UI-001…006. Depends on B35-TIMER and B35-COIN for content; the timer and coin count can
    ship first.
  * **ZACK APPROVAL** (removes the classic HUD in Battle; doc 38 kept it).
* **ACCEPT**
  * No classic HUD glyphs are rendered in the window during Battle.
  * The Classic mode HUD is unchanged.
  * Each new element's rect matches `BattleHudLayout` (layout test).
  * Text stays legible at 720p.
* **PRIORITY**: P1. **CONFIDENCE**: Confirmed.

### B35-LAYOUT-003 — Strips under the window

* **REFERENCE** (t=62 column at x=960, plus t=517.6 and t=1000):
  * **Incoming bar**: 1080p y 944–991 → logical **(111.5, 236, 257, 12)**. It is bordered by dark lines (RGB about
    59,51,33) at y 942–943 and 992.
  * **Status strip**: y 996–1047 → **(111.5, 249, 257, 13)**, with:
    * the eye counter at the far left (about x 114–132);
    * the "WATCH OUT!" pill at the centre-left (about x 185–290);
    * the chest-bonus box at the right (about x 296–368).
  * The gold frame continues below to y≈268.
* **CURRENT**: *partial*.
  * Strip A is (112,245,256,11): the incoming list.
  * Strip B is (112,257,256,11): plain gold.
* **TARGET**
  * Strip A becomes the incoming bar at (112,236,256,12).
  * Strip B becomes the status strip at (112,249,256,13).
  * Both follow the new window bottom (y=232).
* **NOTES**
  * Geometry goes in `BattleHudLayout`. Contents: B35-INCOMING-001/004/005 and B35-COIN-006.
  * It depends on B35-LAYOUT-001 because the window bottom moves from 243 to 232.
* **ACCEPT**: the layout test asserts the rects, no overlaps with the window, frame or panes, and that both strips fit
  inside the frame.
* **PRIORITY**: P1. **CONFIDENCE**: Confirmed for rects; contents per their own IDs.

### B35-LAYOUT-004 — Opponent grid geometry

* **REFERENCE**
  * Cells are 131×166 px, which is **32.75×41.5 logical**, with a 6 px (1.5 logical) gap.
  * Left columns start at x 1.25, 35.25, 69.25. Right columns start at x 377.25, 411.25, 445.25.
  * Rows start at y 10.5, 53.5, 96.5, 139.5, 182.5, 225.5.
  * 3×6 per side, with the inner-top slot used by a badge: 17 panes per side, 34 in total. Confirmed at t=62 and t=515.
* **CURRENT**: *matches within 1 logical px*.
  * Cells are 32×41 with a gap of 2.
  * `GRID_TOP` is 12; `GRID_X_LEFT`/`GRID_X_RIGHT` are 4/376.
* **TARGET**: optional exact match:
  * Cells 32.75×41.5 are not whole logical px. At 1080p they are whole device px (131×166), so a pixel-exact match
    needs layout in device px or a 1920×1080 canvas.
  * Keep 32×41 unless Zack wants a pixel-exact panel. If so, use cell 33×41 with gap 1 and grid top 11 (a whole-px
    approximation).
* **NOTES**: `BattleHudLayout` constants only.
* **ACCEPT**: unchanged tests pass. If changed, the layout test covers non-overlap and whole pixels.
* **PRIORITY**: P3. **CONFIDENCE**: Confirmed.

### B35-LAYOUT-005 — Badges

* **REFERENCE**
  * **COURSE badge**: about (72.5, 0, 30, 30). A white rounded card with a dark-brown border, a small "COURSE" caption,
    and a large "W-L" below.
  * **ALIVE badge**: about (376.25, 0, 30.75, 43.75). A white card with a full small-Mario sprite and "N/T" below
    (e.g. "32/34", "5/35").
  * T is the **number of contestants in this match** (34 in M1, 35 in M2), not a constant.
  * Both badges hang from the top edge into the inner-top grid slot. Seen at t=62, t=517.6, t=760 and t=1000.
* **CURRENT**: *partial*.
  * The badges are at (72,0,32,30) and (376,0,32,44): the same places.
  * The course badge has no "COURSE" caption.
  * The alive badge shows a red 8×8 square, the count, and a stacked "/35".
* **TARGET**
  * The COURSE badge has a "COURSE" caption above "W-L".
  * The ALIVE badge shows a Mario sprite and "N/T" on one line (N alive including the player; T =
    `BattleSession.CONTESTANT_COUNT`).
* **NOTES**: `BattleScreen._build`. The Mario sprite comes from the loaded resource pack, like
  `BattlePreviewAssets`.
* **ACCEPT**:
  * At round start the badge reads "35/35".
  * After each KO it reads N−1 on the same frame the session's `alive_count` changes.
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed.

### B35-LAYOUT-006 — Wallpaper and frame colours

* **REFERENCE**
  * The canvas background is saturated gold: RGB about (255,190,0) and (255,182,0), with a lighter gold of about
    (255,217,56) on frames and dividers.
  * The window frame is a lighter gold band (about (255,217,54)) outside a deeper gold (about (255,185,0)), plus the
    thin dark outline.
* **CURRENT**: *matches in kind*. `WALLPAPER (0.97,0.70,0.14)`, `FRAME_EDGE`, `FRAME_FILL` approximate this.
* **TARGET**: adopt the measured values. Wallpaper (255,190,0); frame light (255,217,56); frame dark (255,182,0);
  outline (59,51,33).
* **ACCEPT**: a GL pixel test samples the wallpaper and frame colours within ±8 per channel.
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed. Any finer pattern in the wallpaper is Unknown.

## 3. Opponent Preview System

### B35-PREVIEW-001 — Every live opponent shows its own current course, live

* **REFERENCE**
  * Each live pane shows that opponent's game, scaled down. Opponents on different courses show different courses at
    the same moment (t=62: mixed underground and overworld; M2 after t≈560: mixed courses).
  * There is no HUD inside a pane (no timer, coins or name).
* **CURRENT**: *partial*.
  * Only course 0 (1-1) has a live preview (`BattlePreviewDriver.LIVE_COURSE = 0`).
  * A bot that has left 1-1 shows the placeholder renderer.
  * Panes overlay a two-digit id and a "W-L" label.
* **TARGET**
  * Every live bot shows a live picture of its current course (the course from B35-COURSE-001).
  * There is no id or course text over the picture.
* **NOTES**
  * This needs a `BattleLevelSketch` for every course in the rotation (`BattleLevelSketch.load_for` already takes a
    scene path) and `BattlePreviewTrack` support for course changes.
  * This is the largest preview task. It depends on B35-COURSE-001 (which courses exist).
  * Removing the id label is a usability trade-off: bots have no names. Keep the id on hover or debug only.
* **ACCEPT**
  * A bot on 1-2 shows an underground picture.
  * A bot that clears a course switches picture within one preview second.
  * The cost table from doc 40 is re-measured with all 34 live.
* **PRIORITY**: P1. **CONFIDENCE**: Confirmed.

### B35-PREVIEW-002 — Pane zoom / crop

* **REFERENCE**: two estimates disagree.
  * A pipe width suggests about 0.77 display px per game px at 1080p, so a pane spans about 170×215 game px.
  * A ground-pattern period suggests 1.0, so about 131×166 game px.
  * Both are tighter than ours.
* **CURRENT**: *differs*. An atlas cell is 187×240 game px shown in a 32×41 logical pane (128×164 device px at 1080p),
  which is 0.68 display px per game px.
* **TARGET**: crop the preview to a narrower window so sprites are larger: about 170×215 game px, keeping the pane
  aspect.
* **NOTES**: `BattlePreviewAtlas.CELL_PX` and `BattleMiniGameRenderer.world_width`. Measure the exact crop before
  changing it (open question Q9).
* **ACCEPT**: a Mario sprite in a pane measures at least 12 device px tall at 1080p (now about 11).
* **PRIORITY**: P2. **CONFIDENCE**: direction Strongly inferred; exact value Unknown.

### B35-PREVIEW-003 — Pane camera behaviour

* **REFERENCE**: panes scroll with their player like the main game. Whether the pane is a scaled copy of the player's
  whole camera view, or a crop centred on Mario, was not determined.
* **CURRENT**: the track's own camera follows the simulated Mario.
* **TARGET**: no change until measured.
* **PRIORITY**: P3. **CONFIDENCE**: Unknown.

### B35-PREVIEW-004 — Underground "coin row" glyphs

* **REFERENCE**: underground panes show a fixed row of about 5 orange coin-like glyphs at the top that stays put while
  the level scrolls (t=62–70, and the t=760 pane). The purpose is **Unknown**: it may be part of the opponent's own
  status display or a level element.
* **TARGET**: do not build.
* **PRIORITY**: P3. **CONFIDENCE**: Unknown.

### B35-PREVIEW-005 — Whole-pane white flashes

* **REFERENCE**: live panes flash solid white for 1–2 frames at moments that are not KOs. Examples:
  * t=163.000 on L21 and t=163.567 on L00 (30 fps change detection).
  * A white flash also immediately precedes every KO card (B35-KO-002).
  * The trigger of the non-KO flashes is **Unknown**. It may be the opponent receiving an enemy, or being hit.
* **TARGET**: build only the pre-KO flash (B35-KO-002). Others wait for evidence.
* **PRIORITY**: P3. **CONFIDENCE**: occurrence Confirmed; trigger Unknown.

## 4. Targeting System

### B35-TARGET-001 — Every contestant has one persistent current target

* **REFERENCE**
  * A red reticle sits on one opponent pane **at all times while playing**, including during the countdown (visible at
    t=499–505 before GO).
  * It stays on the same pane between sends. In M2 (Random mode), for example, it was on R40 from t=517.8 to t=526.7
    with no defeat in between.
  * The recipient of each send is the pane the reticle flies to (B35-TARGET-003).
* **CURRENT**: *missing*.
  * `BattleTargetingRandomSurvivor.choose()` picks a recipient at send time and nothing is persisted.
  * `BattleContestant.target_id` exists but is reserved and unused.
* **TARGET**
  * `BattleSession` holds an authoritative current target per contestant (player and bots): `target_id`, always an
    alive contestant other than self, or −1 when none exists.
  * Sends go to the sender's current target as it is *after* the mode's per-send rule (B35-TARGET-004/006) is
    applied.
  * When a target is eliminated, its sender re-targets on the same tick.
* **NOTES**
  * Extend `BattleTargeting` with:
    * `current(session, id)`, and
    * `on_send(session, sender, draw)`, which returns the recipient and the new current target.
  * Keep `choose()` as a compatibility wrapper.
  * Keep the two random streams (doc 43):
    * The player's mode draws only from `player_rng`.
    * Bots draw from `bot_rng` at the fixed `DRAWS_PER_BOT` rate. If a bot target pick moves out of the send roll,
      keep the draw count fixed.
  * Log a new appended `EventType.TARGET_CHANGED` (id, a = new target, b = old target) so presentation can read it.
    Do not renumber the existing event types.
* **ACCEPT**
  * The player always has a valid target while playing, ≥2 are alive and the round is open.
  * The target is never self or an eliminated contestant.
  * The target changes only on a send, a KO of the target, or a mode change.
  * Determinism: same seed plus same player defeat sequence gives identical targets.
  * All existing session, attack and incoming suites still pass, with expectations updated only where the recipient
    rule changed.
* **PRIORITY**: P0. **CONFIDENCE**: Confirmed for the player. For opponents (bots), Strongly inferred: Attackers mode
  and the red attacker lines imply that opponents also hold targets.

### B35-TARGET-002 — The reticle on the player's target pane

* **REFERENCE**
  * A red four-corner bracket (thick L-shaped corners, pure red, RGB r>225 g<50 b<70) frames the player's current
    target pane, slightly outside the pane edge (bbox about ±2 device px beyond the cell).
  * It is visible during the countdown, play, and the final 1-v-1 (t=1000, on the last opponent's pane).
  * It is never on a KO card.
* **CURRENT**: *missing*. The only target mark is the yellow tint and pulse during a send flight (doc 44 §3).
* **TARGET**: draw the reticle on `target_id(PLAYER)`'s pane at display resolution, above the pane and below the
  attack layer.
* **NOTES**
  * Add it to `BattleAttackLayer`, or a new `BattleTargetReticle` drawn on the canvas.
  * Geometry comes from `BattleHudLayout.compute().slots`.
  * Corner arm length is about 25% of the pane width; arm thickness is about 3 device px at 1080p (0.75 logical).
    Approximate; tune against a capture.
* **ACCEPT**
  * The reticle is on exactly one alive pane whenever the round is PRE_ROUND or PLAYING and ≥2 are alive.
  * It moves on the frame that `TARGET_CHANGED` is presented.
  * A GL test samples red at the four corners of the target pane only.
* **PRIORITY**: P0. **CONFIDENCE**: Confirmed.

### B35-TARGET-003 — The send animation is the reticle flying from the game window to the recipient

* **REFERENCE** (M2, reticle tracked at 10 fps by colour; same pattern on more than 30 sends between t=509 and t=623):
  * On a player defeat, the reticle leaves its pane and appears inside the game window.
  * Within 0.2–0.3 s it lands on the recipient's pane. Examples:
    * window at t=515.8 → L22 at t=516.1;
    * window at t=526.7 → R51 at t=526.9;
    * window at t=527.6 → L12 at t=527.9;
    * window at t=528.5 → L52 at t=528.7.
  * Where it appears in the window:
    * Its in-window position is very often the window centre (1080p about 960,480: t=515.8, 527.6, 536.7, 537.6,
      548.7, 561.9, 607.7, 618.7).
    * Elsewhere it varies (e.g. 722,385; 1254,534), probably the defeated enemy's position.
  * Retarget sweep: when it re-targets after a KO it can step through neighbouring panes about every 2 frames
    (t=163.60 R10 → 163.63 R11 → 163.70 R12).
* **CURRENT**: *differs*.
  * A 0.55 s gold line with a white core, an enemy icon riding the head, a launch ring, and a yellow target tint for
    0.3 s more (`BattleAttackPresentation`, `BattleAttackLayer`).
  * The line starts 56 px inside the window edge.
* **TARGET**
  * Replace the player's send line with the reticle flight:
    * The reticle appears at the defeated enemy's window position, or the window centre if that is unknown.
    * It flies to the recipient pane over 0.25 s, eased.
    * It settles as the persistent reticle (B35-TARGET-002).
  * No enemy icon rides it.
* **NOTES**
  * `BattleAttackPresentation` already keys flights by seq. Add the source point: the kill position from
    `Enemy.report_battle_defeat` (window coordinates through the game camera), passed into the presentation only,
    never into session logic.
  * The red attacker lines aimed at the player stay (B35-INCOMING-004).
  * **ZACK APPROVAL** for removing the gold line: it changes the accepted doc 44 presentation.
* **ACCEPT**
  * Each player send produces one reticle flight ending on the authoritative recipient's pane in 0.25 ± 0.05 s.
  * Flights pause with the game (doc 46 pause fix still holds).
  * Two sends within 0.25 s retarget the reticle without leaving a stale reticle.
* **PRIORITY**: P0 for the flight; P1 for the start position. **CONFIDENCE**: timing Confirmed; start anchor Strongly
  inferred.

### B35-TARGET-004 — Random mode

* **REFERENCE**
  * The player used Random for all of M2 (t≈505–1072) and M1 until t≈354.
  * In Random mode every defeat sends to a freshly chosen pane: the reticle lands on a different pane almost every
    send (sequence L52/L51, L22, R12, R40, R51, L12, L52, R51, L22, L31, …, t=509–623).
  * The reticle stays on the last recipient until the next send.
  * The countdown-time reticle (R42 at t=505) was *not* the first recipient (L51 at t=509.3). The first send drew a
    new target.
* **CURRENT**: *matches the selection rule*: uniform over eligible survivors, one draw from the sender's stream.
* **TARGET**: on each send, draw a uniform eligible target, send to it, and make it the current target.
* **NOTES**
  * Whether Random can repeat the same target consecutively is **Unknown**. Allow repeats, as now.
  * Uniformity over survivors is assumed; the video cannot verify it.
* **ACCEPT**
  * Over 10,000 seeded sends the recipient distribution is uniform within statistical tolerance.
  * The current target equals the last recipient.
* **PRIORITY**: P0. **CONFIDENCE**: Confirmed for behaviour; Unknown for distribution details.

### B35-TARGET-005 — Targeting selector (four modes)

* **REFERENCE**
  * A cross of four rounded pills around a centre button glyph showing "R":
    * Lowest Time (top), Random (left), Most Coins (right), Attackers (bottom).
    * 1080p pill boxes: Lowest Time about x 900–1015, y 55–90; Random about 800–915, 115–148; Most Coins about
      1010–1180, 115–148; Attackers about 900–1015, 168–202; centre glyph at about (958,130).
    * Logical: the cross spans about x 200–295, y 14–50.
  * At rest the whole cross is drawn at low opacity (translucent white outlines and text).
  * The selected pill is filled gold/yellow with a soft glow.
  * On a change (M1, Random → Lowest Time between t=354.00 and 354.25):
    * the cross becomes fully opaque;
    * the new pill's label briefly enlarges (t=354.25);
    * the highlight settles;
    * it fades back to translucent by about t=355.75 (about 1.5–2 s in total).
* **CURRENT**: *missing*.
* **TARGET**
  * A Battle HUD element with these four positions and states.
  * Input: four directions on a dedicated input. The glyph suggests the right stick on the original controller; the
    controller mapping for our game is **ZACK APPROVAL** (Q5).
  * The chosen mode is the player's targeting policy (B35-TARGET-006).
* **NOTES**
  * Store the mode on the session (`player_target_mode`) so it is authoritative and resets per round. Whether SMB35
    carries the mode between matches is **Unknown**: M1 ended on Lowest Time and M2 played Random throughout, though
    the player may have changed it.
  * Draw at display resolution in the in-window HUD layer (B35-LAYOUT-002).
  * **ZACK APPROVAL** (four-mode scope).
* **ACCEPT**
  * Pressing a direction sets the mode in the same frame.
  * The selector animates opaque → translucent over 1.5–2 s.
  * The mode is visible at rest.
  * Classic input is unaffected.
* **PRIORITY**: P1. **CONFIDENCE**: layout and animation Confirmed; input mapping Unknown.

### B35-TARGET-006 — Lowest Time, Most Coins and Attackers policies

* **REFERENCE**
  * **Lowest Time**:
    * Used in M1 from t≈354 to the end.
    * The reticle stayed on one pane (R31) for at least 1.6 s while sends happened (t=161.5–163.07), i.e. the target
      did not change per send.
    * When R31 was KO'd at t=163.10 the reticle re-targeted to R12.
  * **Most Coins** and **Attackers**: never selected in the video. Their behaviour is not observed; only the labels
    exist.
* **CURRENT**: *missing*.
* **TARGET**
  * **Lowest Time**: the current target is the alive opponent with the lowest `time_left`. It is re-evaluated each
    session tick and on KO; ties go to the lower id. Whether SMB35 re-evaluates continuously or only on send/KO is
    **Unknown**: continuous evaluation is the recommended reading of "lowest time".
  * **Most Coins**: highest bot coin count. Requires the bot coin model (B35-COIN-004).
  * **Attackers**: chosen among contestants whose current target is the player. Falls back to Random when none
    exists.
  * Most Coins and Attackers are built **as labelled** with no video verification. Mark them experimental in code
    comments.
* **NOTES**
  * Subclasses of `BattleTargeting`.
  * Lowest Time depends on B35-TIMER-007 (a meaningful bot time model). Under the current flat 600 s, every bot has
    the same time.
  * Attackers depends on B35-TARGET-007.
* **ACCEPT**
  * Pure tests for each policy (lowest time, ties, fallback, never self or eliminated).
  * Lowest Time keeps the same target across sends when times are unchanged.
* **PRIORITY**: P1 for Lowest Time; P2 for Most Coins and Attackers. **CONFIDENCE**: Lowest Time Strongly inferred;
  the others Unknown.

### B35-TARGET-007 — Bots target, and "who targets the player" is known

* **REFERENCE**: thin red lines run from some opponent panes to the player's incoming bar / WATCH OUT pill (t=517.6
  from a right-panel pane; t=1000 from the last opponent L40). The eye counter reads "1" at t=1000 with one opponent
  left.
* **CURRENT**: *missing*. Bots pick a recipient at send time, so there is no notion of who is targeting whom.
* **TARGET**
  * Each bot holds `target_id` (B35-TARGET-001).
  * Bot policy: Random per send, as now. A bot mode mix is **ZACK APPROVAL** (Q6).
  * `session.attackers_of(id)` returns the alive contestants whose current target is `id`.
* **ACCEPT**:
  * `attackers_of(0)` matches the bots whose `target_id == 0` every tick.
  * The eye counter (B35-INCOMING-006) shows its size.
* **PRIORITY**: P1. **CONFIDENCE**: Strongly inferred.

## 5. Attack Sending and Presentation

### B35-ATTACK-001 — Every defeat by the player sends one enemy to the current target

* **REFERENCE**
  * Every player defeat produces a reticle flight (B35-TARGET-003).
  * The M1 results report **Enemies Defeated 215** and **Enemies Sent 215** (t≈470).
* **CURRENT**: *matches* for native enemies (doc 43 attribution). Incoming enemies never send (R0); see
  B35-ATTACK-003.
* **TARGET**: unchanged for native enemies, with the recipient from B35-TARGET-001.
* **PRIORITY**: P0. **CONFIDENCE**: Confirmed.

### B35-ATTACK-002 — Bot→bot sends are not drawn

* **REFERENCE**: no line or effect between two opponent panes was seen in any sampled frame. Only red lines toward the
  player's bar (B35-INCOMING-004) and the player's own reticle flights appear.
* **CURRENT**: *differs*. Bot→bot sends draw thin white pane-to-pane lines (a quarter strength across the window), at
  about 5 draw calls per line (doc 44 §9).
* **TARGET**
  * Do not draw bot→bot sends.
  * Keep the pane pips (doc 44 §5) only if Zack wants an incoming indicator on panes; SMB35 shows none (Q7).
* **NOTES**: `BattleAttackLayer`. This also removes the main draw-call cost of attacks (section 15). **ZACK APPROVAL**
  (doc 44 presentation).
* **ACCEPT**: with bots sending, no line is drawn unless the player is the sender or the recipient.
* **PRIORITY**: P1. **CONFIDENCE**: Strongly inferred (absence of evidence across many frames).

### B35-ATTACK-003 — Re-send: defeating an incoming enemy also sends

* **REFERENCE**: M1 results: Enemies Defeated 215 = Enemies Sent 215 (t≈470). The player defeated many incoming
  enemies in M1 (the incoming bar was busy throughout), so incoming defeats were sent too. M2's Sent value was not
  read.
* **CURRENT**: *differs*. Rule R0 (doc 46): an incoming enemy's death resolves its attack and never sends.
* **TARGET**
  * Switch to "an incoming enemy defeated by the player sends one enemy of its kind to the current target", **after**
    resolving its attack.
  * Shell residue and woken Koopas stay non-sending (doc 46 §8).
* **NOTES**
  * Doc 45 §6 says this is a single policy switch in `BattleSession.report_incoming_kill`. The player stream draws
    once per accepted send (doc 43), so determinism is unaffected.
  * **ZACK APPROVAL** (reverses R0).
* **ACCEPT**
  * A stomped incoming Goomba resolves its attack `DEFEATED_BY_PLAYER` and sends exactly one new attack.
  * A non-player kill of an incoming enemy sends nothing.
  * Woken-Koopa residue sends nothing.
* **PRIORITY**: P0 (if approved). **CONFIDENCE**: Strongly inferred.

### B35-ATTACK-004 — Kinds sent

* **REFERENCE**: incoming icons included Goombas, green Koopas, Piranha Plants (t=760) and Bill-Blaster/Bullet-Bill
  icons on 7-1 (t=1000). The sent kind follows what was defeated.
* **CURRENT**: *partial*. Only GOOMBA and KOOPA are kinds; everything else maps to NONE and is not sent.
* **TARGET**: add kinds one at a time, as courses beyond 1-1 enter the rotation (B35-COURSE-001). Each needs a
  `BattleEnemyType` row, a spawn prefab and a placement rule (doc 42 §2 recipe).
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed for presence; the mapping is Strongly inferred.

## 6. Incoming Enemy System

### B35-INCOMING-001 — Incoming bar

* **REFERENCE** (t=517.6, 746–754, 760, 1000):
  * Left end: the player's icon in its **current power state** (small Mario at t=517.6, fire Mario at t=760), standing
    on a gold zone.
  * Zones: gold (about the left third), orange, then darker orange toward the right, separated by **jagged
    (zig-zag) boundaries**.
  * Incoming enemy icons enter at the right end and move **right → left**.
  * At the gold boundary an icon disappears with a white flash; that is the moment it is released into the level.
  * Crossing takes about 4–6 s early in M2 (two Goombas, t=512–523) and about 3–4 s late (t=746–754).
  * Icons can wait at the boundary for several seconds before release.
  * Several icons travel at once (four or more at t=746–754).
* **CURRENT**: *differs*. Strip A draws "INCOMING", up to nine static icons (lit = ACTIVE, dim = QUEUED), a flash on
  activation, and "ACTIVE n QUEUED m".
* **TARGET**
  * Icons placed by attack state:
    * QUEUED attacks travel from the right end toward the boundary, with progress = time since `RECEIVED` ÷
      `ACTIVATION_DELAY`.
    * ACTIVE-unspawned attacks wait at the boundary.
    * On `INCOMING_SPAWNED`, the icon flashes white and is removed.
  * The player icon reflects the current power state.
  * No text labels or counts.
* **NOTES**
  * `BattleIncomingStrip` reads `BattleAttackPresentation.player_incoming()`, which already carries state, `spawned`
    and times.
  * Zone proportions: about 1/3 and 2/3 (Strongly inferred).
  * The jagged boundary is a sawtooth with about 3 teeth over the bar height.
* **ACCEPT**
  * With a scripted queue, icon x positions match the formula each frame.
  * An icon disappears on the frame its attack's `INCOMING_SPAWNED` is presented.
  * At most one icon per seq.
* **PRIORITY**: P1. **CONFIDENCE**: Confirmed for appearance and direction; the timing mapping is Strongly inferred.

### B35-INCOMING-002 — Delivery cadence

* **REFERENCE**: crossing about 3–6 s; releases are sometimes held at the boundary; releases are spread out, not
  simultaneous.
* **CURRENT**: *close*: `ACTIVATION_DELAY` is 3 ticks, plus a 1.5 s grace and a 1.0 s gap (doc 46).
* **TARGET**: keep the current pacing. Consider `ACTIVATION_DELAY = 4` only if playtests feel too fast (balance:
  **ZACK APPROVAL**).
* **PRIORITY**: P2. **CONFIDENCE**: Strongly inferred.

### B35-INCOMING-003 — Where an incoming enemy appears in the level, and how it looks

* **REFERENCE**
  * t=518.9–519.6: an incoming Goomba appears at the **right screen edge at ground level** and walks left.
  * Incoming enemies are drawn with a **pale/desaturated (whitish-grey) palette**, distinct from native brown
    Goombas. Pale Goombas, Koopas and shells were seen at t=517.6, 747–754, 760 and 1000.
  * White capsule-shaped flashes appear near enemies at t=760 and t=1000. They are likely a materialise/defeat effect;
    the exact meaning is **Unknown**.
* **CURRENT**: *partial*. Spawns on a real floor at the right edge ≥80 px ahead of Mario (doc 46 §5). No visual
  distinction (an explicit doc 46 decision).
* **TARGET**
  * Spawn placement: keep doc 46's rule; it already prefers the right edge.
  * Tint: apply a pale palette to tagged incoming enemies, e.g. a modulate toward (0.85,0.85,0.9) or a desaturate
    shader on the enemy's sprite.
* **NOTES**
  * The tint should live in `BattleIncomingSpawner` after `BattleEnemyFactory.create`, and must survive the
    Koopa→shell→Koopa duplication (doc 45 §1) or be re-applied.
  * **ZACK APPROVAL** (reverses doc 46's "no visual distinction").
* **ACCEPT**
  * A tagged enemy renders pale.
  * A native enemy of the same kind renders normally.
  * A woken incoming Koopa is still pale.
* **PRIORITY**: P1. **CONFIDENCE**: palette Strongly inferred; spawn edge Strongly inferred (one clear case).

### B35-INCOMING-004 — Red attacker lines

* **REFERENCE**: thin (about 1–2 device px) solid red lines run from an opponent pane to the player's incoming bar /
  WATCH OUT pill. Examples:
  * t=517.6: from a right-panel pane into the bar near the queued Goombas.
  * t=1000: from L40 to the WATCH OUT pill.
  * Whether a line marks the moment of a send or persists while that opponent targets the player is **Unknown**: at
    t=760 the bar had icons and no line was visible.
* **CURRENT**: *partial*. Sends at the player draw red pane→window-edge lines for the flight duration and flash the
  window frame red.
* **TARGET**
  * On a send aimed at the player, draw a thin red line from the sender's pane to the incoming bar's right end.
  * It lasts for the flight duration (0.55 s now) plus a fade.
  * The window frame flash is not observed in SMB35: drop it.
* **NOTES**: `BattleAttackLayer`, `BattleAttackGeometry` (new end point: the strip's right end).
* **ACCEPT**:
  * One red line per bot→player send.
  * The line ends inside the incoming bar rect.
  * No frame flash.
* **PRIORITY**: P1. **CONFIDENCE**: Confirmed for appearance; duration Unknown.

### B35-INCOMING-005 — "WATCH OUT!" pill

* **REFERENCE**
  * A rounded pill in the status strip (about x 185–290 logical): red with a black outline, and yellow/white bold
    "WATCH OUT!" text.
  * Present at t=517.6 and t=1000, both while a red attacker line was visible.
  * Absent at t=760 with three icons in the bar and no line.
* **CURRENT**: *missing*.
* **TARGET**: show the pill while any bot→player send is in flight or landing. That is the same window as the red line
  (B35-INCOMING-004), plus about 1 s hold.
* **NOTES**: the trigger is **Strongly inferred**. Re-check against more cases before treating it as final (Q8).
* **ACCEPT**: the pill is visible exactly while a player-targeted flight is drawn, plus the hold.
* **PRIORITY**: P2. **CONFIDENCE**: Strongly inferred.

### B35-INCOMING-006 — Eye counter

* **REFERENCE**: an eye icon and a number at the far left of the status strip ("1" at t=1000, one opponent left).
* **CURRENT**: *missing*.
* **TARGET**: show the eye and `attackers_of(PLAYER).size()`.
* **NOTES**: the meaning (how many opponents are targeting you) is **Strongly inferred** from one frame. Gate it behind
  B35-TARGET-007.
* **PRIORITY**: P2. **CONFIDENCE**: Strongly inferred.

## 7. Timer and Time Economy

Every value in this section changes balance. The whole section is **ZACK APPROVAL** before implementation (Q1).

### B35-TIMER-001 — Starting time

* **REFERENCE**
  * M2 (standard): the timer reads about 33 at t≈510–520 (5–15 s after GO), with kills already happening.
    The start value is **about 35 (exact value Unknown)**.
  * M1 (Special Battle): about 102 at t=30 (5 s after GO), so a start of about 100+. This is event-specific.
* **CURRENT**: `BattleSession.START_TIME = 600` for every contestant.
* **TARGET**: `START_TIME = 35` (configurable constant; exact SMB35 value Unknown).
* **NOTES**: under a 35 s start, bots die at t=35 unless B35-TIMER-007 lands in the same change. **Do not ship 001
  without 007.**
* **ACCEPT**: a new session's contestants start at `START_TIME`; the HUD shows it during PRE_ROUND.
* **PRIORITY**: P0. **CONFIDENCE**: Strongly inferred (value ±3).

### B35-TIMER-002 — Base countdown rate

* **REFERENCE**: frame-exact HUD change detection shows one unit per **60 frames (1 Hz)** throughout normal play
  (e.g. t=520–527: 33,32,…,27; 15 s windows from t=26 to t=281 in M1 and t=506 to t=731 in M2 all have a modal gap of
  60 frames).
* **CURRENT**: *matches*: 1 per Battle second.
* **TARGET**: unchanged.
* **PRIORITY**: P0. **CONFIDENCE**: Confirmed.

### B35-TIMER-003 — Double speed at 5 or fewer alive

* **REFERENCE**
  * The decrement switches to one unit per **30 frames (2 Hz)** exactly when the alive count goes from 6 to 5:
    * M1: last 1 s step at t=291.37, 2 Hz from t=291.87; alive 6/34 → 5/34 between t=291 and t=292.
    * M2: 1 Hz through t=752.8; alive 6/35 → 5/35 at t=753.5; 2 Hz from t=753.8.
  * It stays 2 Hz to the end of both matches.
* **CURRENT**: *missing*.
* **TARGET**: when `alive_count <= 5`, every contestant's `time_left` decreases by 2 per Battle second, applied as 1
  per half second for the player display.
* **NOTES**
  * Session ticks are whole seconds. Either subtract 2 per tick and let the HUD interpolate, or add a half-second
    sub-step for time only.
  * The display must change at 2 Hz (acceptance below).
* **ACCEPT**:
  * With 6 alive, the HUD drops 1 per second.
  * On the tick that makes 5 alive, it starts dropping 1 per 0.5 s.
  * Pure session test plus a HUD test.
* **PRIORITY**: P0. **CONFIDENCE**: Confirmed (two independent matches).

### B35-TIMER-004 — Time bonus per defeat

* **REFERENCE**
  * A floating clock icon with "+N" appears near Mario or the defeated enemy, and the timer increases at once.
  * N values seen: +1, +2, +4, +5 (e.g. "+5" t=760, "+2" t=1000, +6/+7 in total at t=527–529).
  * The bonus formula is **Unknown**. It may depend on the enemy kind or on the stomp-combo position (the results track
    "Best Streak: Continuous Stomps").
* **CURRENT**: *missing*.
* **TARGET**:
  * Each player defeat of any enemy (native or incoming) adds `TIME_PER_DEFEAT` (recommend +2 as a neutral midpoint)
    and shows a "+N" clock popup at the enemy's position.
  * Combo scaling is **ZACK APPROVAL** (Q2).
* **NOTES**
  * Hook in `BattleSession.report_enemy_kill` (both the native and incoming paths). The kill source must be the PLAYER
    (doc 43 attribution).
  * The popup is a Battle canvas effect positioned from the enemy's window coordinates.
* **ACCEPT**:
  * A stomp adds exactly `TIME_PER_DEFEAT` on the same frame and spawns one popup.
  * A non-player kill adds nothing.
  * The total never exceeds the cap (B35-TIMER-006).
* **PRIORITY**: P0. **CONFIDENCE**: occurrence Confirmed; formula Unknown.

### B35-TIMER-005 — Flagpole bonus and freeze

* **REFERENCE**
  * Grabbing the flagpole shows "+15" and adds 15: t=130→135 (173→188); t=735.5→736.5 (219→234); t=814.5.
  * The timer is **frozen** during the flag slide and castle walk (188 held t=135–136.5) and resumes on the next
    course.
  * Whether the bonus depends on flag height is **Unknown**: all three cases gave +15.
* **CURRENT**: *differs*.
  * There is no bonus.
  * The session clock keeps ticking while the level processes, including the flag and castle walk
    (`BattleHandler._process`; inferred from code, not tested).
* **TARGET**:
  * `report_level_complete` adds 15 to the player's time.
  * Player time does not decrease from `level_complete_begin` until the next level becomes playable.
* **NOTES**: add a session flag `player_time_frozen`. Bots get the same +15 on `LEVEL_CLEAR` (B35-TIMER-007).
* **ACCEPT**:
  * A real flagpole grab adds 15 once.
  * The time is identical from the grab until the next course starts.
  * A Bowser-bridge clear behaves the same: the castle clear at t=905 has no measured bonus, so its bonus is
    **Unknown**. Use 15.
* **PRIORITY**: P0. **CONFIDENCE**: Confirmed (+15 and freeze).

### B35-TIMER-006 — Cap at 400

* **REFERENCE**:
  * The timer never exceeded 400 in 18 minutes.
  * It sat at 395–400 for long stretches (t=165–275, t=865–950, t=1045–1070).
  * "400" was shown at t=163.1 and t=1070.
* **CURRENT**: *missing*.
* **TARGET**: `MAX_TIME = 400`. Every addition clamps.
* **ACCEPT**: additions at 399 end at 400.
* **PRIORITY**: P0. **CONFIDENCE**: Strongly inferred.

### B35-TIMER-007 — Bot time economy (required companion)

* **REFERENCE**: opponents' timers are not visible, but they obey the same rules. Under Lowest Time targeting the
  reticle moved to a specific opponent, so opponents' times differ.
* **CURRENT**: bots run `time_left -= 1` from 600; time-outs are rare.
* **TARGET**
  * Bots use the same rules: `START_TIME`, +`TIME_PER_DEFEAT` per bot defeat (`generate_bot_defeats`), +15 per
    `LEVEL_CLEAR`, the cap, and the 2 Hz rule.
  * Time-out is a real KO cause for bots (`KoCause.TIME`).
* **NOTES**
  * `BattleBotSimulator.step_bot` and `BattleAttackSystem.generate_bot_defeats` (no new random draws: keep
    `DRAWS_PER_BOT` fixed).
  * Expect large balance shifts: run the existing 200-seed match-length statistics before and after, and report them.
* **ACCEPT**:
  * Bots gain time on their defeats and clears.
  * Average bot `time_left` distributions are reported.
  * A 200-seed run produces a TIME KO share between 5% and 60% (sanity range, to be tuned with Zack).
* **PRIORITY**: P0. **CONFIDENCE**: Strongly inferred (game logic).

### B35-TIMER-008 — KO credit reward

* **REFERENCE** (t=163.100, a single 30 fps frame; investigated locally for this document). On the same frame:
  * the timer jumped 177 → **400**;
  * coins jumped 95 → **148** (+53);
  * the alive badge dropped 18 → **17**;
  * the pane the player's reticle had been on continuously (R31, at least t=161.5–163.07, Lowest Time mode) switched
    to an **orange card**, the only orange card in either match. It stayed orange until the end of M1 (still orange
    at t=200, 300 and 410);
  * the reticle immediately re-targeted (R10 → R11 → R12 by t=163.70).
  * The chest bonus did not change (770 before and after), so this is **not** a chest event.
  * Reading: **the player's current target was eliminated while under the player's attack, and the player was credited
    with the KO.** The reward filled the timer to the cap and added coins.
  * Unknown:
    * whether the time reward is "fill to max" or "+N, clamped" (177 + 223 = 400);
    * whether +53 coins is fixed or the eliminated opponent's coins;
    * what exactly qualifies for credit (the last attacker? the current target?);
    * whether this is Special-Battle-only. No orange card appeared in M2, so it cannot be compared.
* **CURRENT**: *missing*. `BattleContestant.ko_by` exists (reserved, unused).
* **TARGET**:
  * When a bot is eliminated and the real player qualifies for credit, set `ko_by = PLAYER`, add the time reward, add
    the coin reward, and show the orange KO card (B35-KO-003).
  * Recommended qualifying rule: the KO'd bot had at least one ACTIVE attack whose sender is the player at the moment
    of its KO (pressure from the player's sends is what the bot model can attribute).
* **NOTES**
  * `BattleSession._apply_kos` already resolves the attacks with `TARGET_OUT`. Check their senders before resolving.
  * The reward values and qualification rule are **ZACK APPROVAL** (Q3). Recommended defaults: time → `MAX_TIME`,
    coins +50.
* **ACCEPT**:
  * A bot KO'd with the player's attack active gives exactly one reward and one orange card.
  * A bot KO'd by bot pressure only gives none.
  * Pure tests over seeded matches: the count of orange cards equals the count of player KO credits.
* **PRIORITY**: P1. **CONFIDENCE**: event Confirmed; mechanism Strongly inferred; formula Unknown.

### B35-TIMER-009 — Timer display

* **REFERENCE**
  * Top-right of the window, about (296,10,69,18) logical.
  * A round grey clock icon with a dark outline, followed by large three-digit silver/chrome numerals with a dark
    outline (no leading zeros, e.g. "36", "146", "400").
  * The display updates on the tick frame (no interpolation).
  * Low-time styling (colour or flashing) is **Unknown**: the player never fell below about 27 s.
* **CURRENT**: canvas "TIME 600" label; the classic HUD time mirrors `time_left` (`Global.time`).
* **TARGET**: the in-window timer per B35-LAYOUT-002; integer `time_left`, no leading zeros.
* **ACCEPT**:
  * The value equals `get_player().time_left` every frame.
  * The digit change happens on the tick frame.
* **PRIORITY**: P1. **CONFIDENCE**: Confirmed.

### B35-TIMER-010 — Running out of time

* **REFERENCE**: not observed (the player never timed out).
* **CURRENT**: the session KOs for TIME; the player dies through `time_up()` (doc 41).
* **TARGET**: unchanged.
* **PRIORITY**: P0 (existing). **CONFIDENCE**: Unknown for SMB35 presentation.

## 8. Coins and Item Roulette

Scope is **ZACK APPROVAL** (Q4).

### B35-COIN-001 — Coin counter

* **REFERENCE**:
  * Top-left of the window, about (115,10,35,9): an orange coin icon and a white number with a dark outline, no
    leading zeros.
  * It counts coins collected this match, starting at 0 (M2 t=510: 1).
  * Values reached ≥214.
  * It decreases by 20 per roulette.
* **CURRENT**: *missing* in Battle UI. The classic `Global.coins` exists and its 100-coin 1-up path works in Battle
  (doc 38 §9).
* **TARGET**:
  * `BattleSession` tracks `coins` for the player, mirroring coins the real game awards.
  * The 100-coin 1-up must not apply in Battle, since lives are not used. Confirm the current behaviour first.
* **NOTES**: the classic coin increments are plain `Global.coins` writes. Poll the delta in `BattleHandler`, as the
  timer is done today.
* **ACCEPT**: picking up a coin increments the Battle counter by 1 on the same frame.
* **PRIORITY**: P0 (if in scope). **CONFIDENCE**: Confirmed.

### B35-COIN-002 — Item box

* **REFERENCE**:
  * Below the coin counter, about (112.5,20,40,40): a dark rounded frame containing a "?" block, with a cost pill
    showing a coin icon and "20" and an X-button glyph.
  * With fewer than 20 coins the whole box is dimmed and translucent (t=517.6, coins 2).
  * During and after the roulette the box shows the item with a yellow glow border.
* **CURRENT**: *missing*.
* **TARGET**: an item box element with three states: disabled (<20), ready (≥20), and spinning/landed.
* **ACCEPT**: the state follows coins and the roulette state every frame.
* **PRIORITY**: P0 (if in scope). **CONFIDENCE**: Confirmed.

### B35-COIN-003 — Roulette

* **REFERENCE** (t=92.25–97.5):
  * Pressing X with ≥20 coins deducts 20 at once (130 → 110 at t=92.25–92.5).
  * The box cycles items (POW, Star, Fire Flower, Mushroom) for about 3 s (t=92.5–95.5) **while gameplay continues**.
  * It lands and holds the result with a yellow glow for about 2 s (t=95.5–97.25).
  * The effect applies at the end (Fire Mario at about t=97).
  * The box returns to "?" at t=97.5.
* **CURRENT**: *missing*.
* **TARGET**: exactly this sequence:
  * the item is drawn from `player_rng` at press time, so it is deterministic per seed and press sequence;
  * a press during a spin is ignored.
* **NOTES**
  * Item weights are **Unknown** and need **ZACK APPROVAL**. Default: uniform.
  * Apply effects through the real game: `Player.get_power_up()` for Mushroom and Fire Flower; the game's Star
    pickup; POW = defeat every on-screen enemy using the game's kill path with source PLAYER.
  * Whether POW kills send is **Unknown**.
* **ACCEPT**:
  * Coins −20 on press.
  * Spin 3.0 ± 0.1 s, hold 2.0 ± 0.1 s, then the effect.
  * The player can move throughout.
  * Pausing freezes the roulette.
* **PRIORITY**: P0 (if in scope). **CONFIDENCE**: Confirmed for timing and four items; weights Unknown.

### B35-COIN-004 — Bot coins

* **REFERENCE**: Most Coins targeting implies opponents have coin counts. The Ranking table shows each player's coins
  (e.g. 106, 87, 243, 104).
* **CURRENT**: *missing*.
* **TARGET**: bots accumulate coins at a simple rate per level progress (no new random draws), so Most Coins and the
  Ranking table have values.
* **PRIORITY**: P2. **CONFIDENCE**: Strongly inferred.

### B35-COIN-005 — Coins from KO credit

* See B35-TIMER-008 (+53 observed).
* **PRIORITY**: P1. **CONFIDENCE**: Strongly inferred.

### B35-COIN-006 — Chest bonus

* **REFERENCE**:
  * Right box of the status strip: a dark-orange bar with a treasure-chest icon and a large white number.
  * It grows through the match:
    * M1: 112 → … → 770 (t≈160) → 1244 → 1474 → 1655 at the win;
    * M2: 0 (t=517) → 77 → 139 → 358 (t=760) → 572 (t=1000) → 572 at the win.
  * At the win it is shown as "BONUS N" and counted into the coin total (B35-RESULT-002).
  * The growth formula is **Unknown**. It rises in steps during play, plausibly per KO elsewhere or per course.
* **CURRENT**: *missing*.
* **TARGET**: display only, fed by a placeholder rule (+10 × opponents eliminated this tick) until Zack picks a rule.
* **NOTES**: **ZACK APPROVAL** (Q4).
* **PRIORITY**: P2. **CONFIDENCE**: display Confirmed; formula Unknown.

## 9. Level Progression and Transitions

### B35-COURSE-001 — Non-linear course sequence

* **REFERENCE**:
  * M2 (standard) badge sequence: 1-1 (t=505) → 1-3 (560) → 1-1 (590) → 1-2 (635) → 1-1 (690, after a warp zone) →
    3-1 (735) → 1-1 (815) → 1-4 (870) → 1-1 (910) → 4-1 (955) → 7-1 (1000) → 1-2 (1045). That is 12 courses at about
    30–80 s each.
  * M1 (Special): 1-2 → 6-2 (warp) → 6-3 → 1-2 → 3-2 (warp) → 6-1 → 6-2 → 6-3.
  * The rule that picks the next course is **Unknown**. 1-1 recurs often in M2.
  * The matchmaking screen shows a small course thumbnail in a speech bubble above the player icon (t=482–503), which
    suggests per-player course choices feed a pool.
* **CURRENT**: *differs*. Linear: course index = `levels_cleared`; 1-1 → 1-2 → … (`BattleCourse`, `LevelClass`
  transition).
* **TARGET**:
  * A session-owned course sequence (`BattleCourse.next(session, cleared)`), drawn from a dedicated random stream so
    bots and player share it (Q10).
  * The player's next level and every bot's preview course come from it.
* **NOTES**:
  * Needs a Battle branch in `Level.transition_to_next_level()` routing to the sequence.
  * The bot model uses `levels_cleared` for ranking, so keep ranking on `levels_cleared + progress`, unaffected by
    which course.
  * **ZACK APPROVAL** (Q10).
* **ACCEPT**:
  * The same seed gives the same sequence.
  * The player's level after a clear equals the sequence entry.
  * The preview shows the bot's sequence entry.
* **PRIORITY**: P1. **CONFIDENCE**: Confirmed non-linear; selection rule Unknown.

### B35-COURSE-002 — Remixed warp zones

* **REFERENCE**: warp-zone pipes are labelled with remixed destinations (M1 t=85 and t=235: 6-2 / 6-1 / 3-2; M2 t=690:
  3-1 / 1-1 / 2-2). Taking one jumps to that course.
* **CURRENT**: classic warp destinations.
* **TARGET**: in Battle, the warp destinations are three entries drawn from the course pool. Taking one sets the
  player's next course.
* **PRIORITY**: P3. **CONFIDENCE**: Confirmed.

### B35-COURSE-003 — Fast course transition

* **REFERENCE**:
  * There is no "WORLD x-y" card.
  * Flag/castle → about 0.5 s darken or palette fade (t=559.0, t=136.0) → next course immediately.
  * About 1.5–2.5 s from flag grab to control on the next course.
  * The HUD and item box stay up throughout.
* **CURRENT**: *differs*. Classic flagpole → castle → `LevelTransition` (black WORLD card) inside the window.
* **TARGET**: in Battle, skip the `LevelTransition` card (load the next course directly with the confined fade, doc
  38). The flag and castle animations stay.
* **NOTES**: `BattleScreen.routes()` / `Global.transition_to_scene`. The round start still uses the pre-round (section
  12).
* **ACCEPT**: from flag grab to control on the next course takes ≤2.5 s at 1×, with no WORLD card frame.
* **PRIORITY**: P1. **CONFIDENCE**: Confirmed.

### B35-COURSE-004 — Course badge

* See B35-LAYOUT-005. The badge changes on the frame the next course starts.
* **CONFIDENCE**: Confirmed.

## 10. Enemy Interaction Rules

### B35-ENEMY-001 — Native enemy defeats

* **REFERENCE**: stomps, fireballs, shells and Star all count (the results separate "Enemies Stomped" 47/104 from
  "Enemies Defeated" 215/415).
* **CURRENT**: *matches* (doc 43 attribution).
* **PRIORITY**: P0. **CONFIDENCE**: Confirmed.

### B35-ENEMY-002 — Incoming enemy defeats

* See B35-ATTACK-003 (re-send, **ZACK APPROVAL**).

### B35-ENEMY-003 — Incoming enemies are ordinary enemies

* **REFERENCE**: pale incoming enemies walk, fall into pits (t=519) and are stomped like native ones.
* **CURRENT**: *matches* (real prefabs, doc 46).
* **PRIORITY**: P0. **CONFIDENCE**: Confirmed.

### B35-ENEMY-004 — Stomp streak tracking

* **REFERENCE**: the results show "Best Streak: Continuous Stomps" (M1 4, M2 11).
* **CURRENT**: *missing*.
* **TARGET**: count consecutive stomps without touching the ground (the classic combo counter), for results only.
* **PRIORITY**: P3. **CONFIDENCE**: Confirmed for the stat; the exact streak rule is Unknown.

## 11. Elimination and Ranking

### B35-KO-001 — KO card replaces the pane in place

* **REFERENCE**:
  * An eliminated opponent's pane becomes a blue card in the same slot. There is no reordering for the rest of the
    match: 33 blue cards at t=1000 in their original slots.
  * The card is mid-blue with a lighter inner border and a bold white "KO" at the top. The **placement number** sits
    in a teal block with corner rivets (e.g. 34 for the first eliminated in M2).
* **CURRENT**: *partial*. In place, with a dark-red 70% overlay, a white X, a red frame and the two-digit id; no
  placement number.
* **TARGET**: the blue KO card with "KO" and `placement`. No contestant id.
* **NOTES**: `BattleOpponentPane._draw_overlay`. The placement is known at the KO (`BattleSession._apply_kos`).
* **ACCEPT**: the card shows the contestant's final placement; it never moves; a GL test samples blue.
* **PRIORITY**: P1. **CONFIDENCE**: Confirmed.

### B35-KO-002 — KO card animation

* **REFERENCE** (t=524.4–527.3, one pane, 10 fps):
  * The live picture continues.
  * The pane flashes white (1–2 frames).
  * The card pops in with a starburst/sparkle and white smoke puffs over about 0.5–0.6 s.
  * A second white flash at about t=527.1.
  * It settles at about t=527.2: about 0.8 s from the first flash to the settled card.
* **CURRENT**: *differs*. The KO marking follows the preview's own KO sequence (`BattlePreviewCell.marked`) with no
  card animation.
* **TARGET**: on `marked` becoming true, play a 0.8 s pane-local animation: flash, pop with scale overshoot, puffs,
  flash, settle.
* **ACCEPT**: the animation lasts 0.8 ± 0.1 s, runs at display resolution, and costs no atlas work.
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed.

### B35-KO-003 — Orange card for opponents the player KO'd

* **REFERENCE**:
  * t=163.1: R31 becomes an orange card distinct from blue KO cards. It persists to the end of M1.
  * It is the only one in either match.
  * Contents (icon or placement) were not measured: **Unknown**.
* **CURRENT**: *missing*.
* **TARGET**: if `ko_by == PLAYER` (B35-TIMER-008), use an orange variant of the KO card.
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed appearance; contents Unknown.

### B35-KO-004 — Placement rule

* **REFERENCE**: placement equals (alive count at elimination). The first out shows 34 or 35. The winner is 1.
* **CURRENT**: *matches* (`_apply_kos`).
* **PRIORITY**: P0. **CONFIDENCE**: Confirmed.

### B35-KO-005 — Alive badge updates

* See B35-LAYOUT-005. The update is immediate on the KO frame (t=163.100: the alive badge and the KO happen on the same
  frame).
* **CONFIDENCE**: Confirmed.

## 12. Match Start, Results and Rematch Flow

### B35-RESULT-001 — Match start sequence

* **REFERENCE** (M2, 0.25 s sampling):
  * "Here we go…" on the matchmaking screen (t=499.5–500.25).
  * The level appears in the window with "**Ready**" (large red/orange outlined text, centred over the window) from
    t=500.5 to about 501.75.
  * "**3**" t=502.0–502.75, "**2**" t=503.0–503.75, "**1**" t=504.25–504.75, each a large red numeral with a white
    outline.
  * "**GO!**" t=505.25–505.75+.
  * In total about 5.5 s from the level appearing to GO.
  * The target reticle is already visible during the countdown.
  * Panes show the opponents' frozen starts.
* **CURRENT**: *differs*. "READY" for 2.5 s, then "GO!" for 0.8 s (`BattleRound.PRE_ROUND_SECONDS`, `GO_SECONDS`).
* **TARGET**:
  * PRE_ROUND shows "Ready" for 1.5 s, then "3", "2", "1" for 1.0 s each.
  * Release at the start of "GO!", which lingers for 0.8 s.
  * Pre-round total 4.5 s.
* **NOTES**: `BattleRound.banner_text()` gains countdown states. `--battle-preround` still overrides.
* **ACCEPT**: the banner text sequence and times match ±0.05 s; play is released exactly at GO.
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed.

### B35-RESULT-002 — Win presentation

* **REFERENCE** (M1 t=412–465; M2 t=1072–1095):
  * The game window dims; a "Saving…" spinner appears in a corner.
  * A large gold starburst medal with a red "1" (white outline) and the player's Mario sprite appears over the window
    (M1 t=418; M2 t=1074).
  * Below it, a player row: icon, name, level, coins, KO count.
  * Then a "BONUS N" banner with a chest (M1 1655 at t=440; M2 572 at t=1080). The coin figure in the row counts up as
    the bonus is added, over about 5–30 s.
  * Then "Level Up! a → b" with "New Icon!" (M1 t=460; M2 t=1095).
* **CURRENT**: *differs*. One text card, "ROUND n OVER / YOU WON! / …" (`BattleScreen.show_result`).
* **TARGET**: Battle-appropriate subset:
  * dim the window, show the "1" medal (or the placement number for a loss), and the player row (placement, coins,
    KOs);
  * then the BONUS count-up if B35-COIN-006 exists.
  * There are no player levels in our game, so the Level Up card is not built (P3).
* **ACCEPT**: medal, then row, then bonus, in order; total ≤6 s before the menu is interactive.
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed for the win; the loss presentation is **Unknown** (never lost).

### B35-RESULT-003 — Ranking and Results pages

* **REFERENCE**:
  * **Ranking** (t=465): a "Ranking" title with a large "1". A table with columns rank badge (gold/silver/bronze for
    1–3, blue after), icon, name, level, coins, KOs. Five rows visible, scrollable.
  * **Results** (t=470, t=1100): a stats table:
    * M1: Items Used 16, Enemies Stomped 47, Best Streak: Continuous Stomps 4, Enemies Defeated 215, Courses Cleared 7,
      Enemies Sent 215, Enemies Received 199.
    * M2 adds Time Played 09:18, Distance Traveled 2388, Jumps Jumped 498.
  * X toggles between Results and Rankings.
* **CURRENT**: *missing*.
* **TARGET**:
  * A two-page results overlay with Ranking (top 5 plus the player's row: placement, id, levels cleared, coins, KOs)
    and Results (the stats we can count: items used, stomped, defeated, courses cleared, sent, received, time played).
  * X toggles pages.
* **NOTES**: most counters already exist in `BattleAttackSystem` (defeats, `player_defeats`, received via history).
* **ACCEPT**: every stat equals the session counters at round end.
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed.

### B35-RESULT-004 — Rematch / Main Menu

* **REFERENCE**:
  * Bottom bar buttons: "Spectate" (greyed after a win), "B Main Menu", "A Rematch", "X Results/Rankings".
  * The player chose Main Menu both times (t=475, t=1110). Rematch was not exercised.
* **CURRENT**: *differs*. Confirm after 1 s, or auto after 10 s, starts the next round; Quit only from the pause menu.
* **TARGET**:
  * A = next round (our "rematch"); B = Quit to title (existing `quit_battle`).
  * No auto-advance (Q11).
  * Spectate is not built.
* **NOTES**: `BattleRound.RESULTS_MAX_SECONDS` becomes infinite or removed; `results_dismissed`. **ZACK APPROVAL**
  (doc 41 auto-advance).
* **ACCEPT**:
  * A starts the next round, B quits, and nothing happens after 10 s idle.
  * The 1 s lockout is kept.
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed.

### B35-RESULT-005 — Matchmaking screen

* **REFERENCE**:
  * t=5–20 and t=480–500: "Matching… NN" with a countdown number (88 → 72 …).
  * A grid of player slots fills with Mario icons up to 35/35.
  * Then "Here we go…".
* **CURRENT**: *missing* (title → round).
* **TARGET**: optional cosmetic: a 2–3 s "Matching…" card that fills 35 slots before the first round.
* **PRIORITY**: P3. **CONFIDENCE**: Confirmed.

## 13. HUD / UI / Visual Style

### B35-UI-001 — Typography

* **REFERENCE**: UI text (selector labels, "COURSE", results tables) is a rounded bold sans-serif. Numbers are large
  bold digits with dark outlines. The timer uses chrome/silver numerals. In-level text stays NES-style.
* **CURRENT**: the game's bitmap font everywhere.
* **TARGET**: one rounded bold UI font for Battle chrome. In-window numerals stay pixel-crisp at 4×. Licensing:
  **ZACK APPROVAL** (Q12).
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed.

### B35-UI-002 — Colour language

* **REFERENCE**:
  * Gold surround (section 2).
  * Red = targeting, danger, attackers: reticle, attacker lines, WATCH OUT.
  * Blue = eliminated (KO cards); orange = KO credit.
  * Gold fill = selected option.
  * White translucent = idle selector.
  * Silver = timer.
* **CURRENT**: partial: yellow target tint, red pips, red KO frame.
* **TARGET**: adopt this mapping. Pips are removed if B35-ATTACK-002 is approved (Q7).
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed.

### B35-UI-003 — Popups in the window

* **REFERENCE**: a "+N" with a clock icon (time) floats up near the defeated enemy or Mario for about 0.5–1 s. White
  text, dark outline.
* **TARGET**: per B35-TIMER-004.
* **PRIORITY**: P1. **CONFIDENCE**: Confirmed for appearance; exact float duration Unknown.

### B35-UI-004 — Opacity of the in-window HUD

* **REFERENCE**:
  * The selector is translucent at rest (section 4).
  * The coin counter, item box and timer are opaque.
  * The item box is translucent when unaffordable.
* **PRIORITY**: P2. **CONFIDENCE**: Confirmed.

## 14. Animation / Motion / Timing Reference

| Event | Duration / cadence | Source t | Confidence | Req |
|---|---|---|---|---|
| Ready banner | ≈1.25–1.5 s | 500.5–501.75 | Confirmed | RESULT-001 |
| 3 / 2 / 1 | ≈0.75–1.0 s each, 1 s period | 502–504.75 | Confirmed | RESULT-001 |
| GO! | ≥0.5 s (sampled to 505.75) | 505.25 | Confirmed | RESULT-001 |
| Reticle window→pane flight | 0.2–0.3 s | 515.8–516.1, 526.7–526.9, … | Confirmed | TARGET-003 |
| Reticle retarget sweep | ≈1 pane per 2 frames | 163.60–163.70 | Strongly inferred | TARGET-003 |
| Selector change (opaque → translucent) | ≈1.5–2 s | 354.0–355.75 | Confirmed | TARGET-005 |
| Incoming icon crossing | ≈3–6 s | 512–523, 746–754 | Strongly inferred | INCOMING-001 |
| Roulette spin | ≈3.0 s | 92.5–95.5 | Confirmed | COIN-003 |
| Roulette hold, then effect | ≈2.0 s | 95.5–97.5 | Confirmed | COIN-003 |
| KO card (flash → settled) | ≈0.8 s | 526.4–527.2 | Confirmed | KO-002 |
| Pane white flash | 1–2 frames | 163.00, 163.57 | Confirmed | PREVIEW-005 |
| Flag → next course control | ≈1.5–2.5 s (0.5 s fade) | 135–137, 559 | Confirmed | COURSE-003 |
| Timer tick | 60 frames; 30 frames at ≤5 alive | section 7 | Confirmed | TIMER-002/003 |
| KO credit: timer, coins, alive, card | same frame | 163.100 | Confirmed | TIMER-008 |
| Bonus count-up | ≈5–30 s | 420–455 | Strongly inferred | RESULT-002 |

Motion style: snappy and short (≤0.3 s) for targeting; 0.5–1 s for state changes; longer only for the
celebration screens. Pops overshoot (KO card, label enlargement). Use ease-out for flights and fades.

## 15. Performance / Update Cadence

| Element | SMB35 cadence (measured) | Battle now | Opportunity |
|---|---|---|---|
| Main game | 60 fps (172/179 frames changed, t=62–65) | 60 fps | none |
| Opponent panes | Up to 60 fps. Over 3 s at t=62 three panes changed on 163, 178 and 179 of 179 frames; one changed on 130 with gaps of 2 or 4 frames. At t=515, 2 s: most live panes changed on ≥0.6 of frames, some much less. The gaps look like scenes that did not move, not a fixed lower rate. | atlas `UPDATE_ALWAYS`, all 34 cells every frame, including eliminated ones | **Stop rendering atlas cells of KO'd contestants** (SMB35 shows a static card). This is safe and visually exact; gains grow late in a match (31 of 34 eliminated by t=300 in M1). Do **not** lower the live-pane rate on fidelity grounds: there is no evidence of a fixed low rate. A 30 Hz atlas is a pure performance choice and needs a visual check. |
| Timer HUD | changes at 1 Hz / 2 Hz | label per frame | update only on value change |
| Selector, badges | event-driven | per-frame `refresh()` label writes | write text only on change |
| Send visuals | one reticle per player send (about 0.25 s); no bot→bot visuals | about 5 draw calls per line for every send, bot→bot included (doc 44 §9) | **Drop bot→bot lines** (B35-ATTACK-002). This removes most attack-layer draw calls (doc 44 stress: 27 lines ≈ 0.55 ms recording) |
| Incoming bar | a few icons moving every frame | a strip redrawn on change | negligible |

### B35-PERF-001 — Freeze the atlas cells of eliminated contestants

* **TARGET**: once a pane shows its KO card, stop drawing that contestant's atlas cell. It is static; the
  `BattlePreviewCell` renderer is skipped, the atlas cell is left as it is, and the pane draws only the card.
* **ACCEPT**:
  * With N contestants eliminated, the per-frame preview draw-recording cost drops roughly in proportion
    (measured with `battle_preview_bench.gd`).
  * No KO'd pane changes pixels after its card settles (GL test).
* **PRIORITY**: P1. **CONFIDENCE**: Confirmed (SMB35 KO cards are static: zero change ratio at t=600 and t=750 for
  KO'd cells).

### B35-PERF-002 — Event-driven HUD text

* **TARGET**: `BattleScreen.refresh()` writes label text and queues redraws only when a value changes.
* **PRIORITY**: P3. **CONFIDENCE**: not a fidelity item.

Recommendation: implement the KO-cell freeze together with B35-KO-001/002 (the card replaces the picture anyway), and
the bot-line removal together with B35-TARGET-003. Re-measure with `tests/tools/battle_attack_bench.gd` and
`battle_preview_frametime.gd`.

## 16. Audio Event Reference

The reference audio was **not analysed** and must not be extracted, transcribed or reproduced. The events below are
the moments where SMB35 visibly changes state, and so are natural sound-effect hooks for Battle. They use our own or
the game's existing sounds, and none of them is a claim about SMB35's audio.

| Hook | Trigger | Existing sound to consider |
|---|---|---|
| Countdown 3/2/1, GO | B35-RESULT-001 | game's existing UI blips |
| Send (reticle flight) | player send | none yet (ours) |
| Incoming released into the level | `INCOMING_SPAWNED` | none yet (ours) |
| WATCH OUT | B35-INCOMING-005 | none yet (ours) |
| Time bonus popup | B35-TIMER-004/005 | coin / 1-up style blip |
| Roulette spin / land | B35-COIN-003 | block-hit, power-up appear |
| KO card / KO credit | B35-KO-002/003 | none yet (ours) |
| Timer at 2 Hz | B35-TIMER-003 | classic "hurry" music trigger (Unknown whether SMB35 changes music) |

Confidence for all audio: **Unknown**. Priority: P3.

## 17. Current Battle Mode Gap Matrix

| ID | Feature | SMB35 reference | Current status | Target | Priority | Confidence |
|---|---|---|---|---|---|---|
| B35-LAYOUT-001 | Window 256×224 | (112,8,256,224), t=62 | differs (240 rows) | display-crop to 224, keep 256×240 viewport | P1 · ZACK | Confirmed (rows Unknown) |
| B35-LAYOUT-002 | HUD inside window | coins/item/selector/timer, t=62 | differs (classic HUD) | Battle HUD layer; hide classic row | P1 · ZACK | Confirmed |
| B35-LAYOUT-003 | Strips | bar (112,236,256,12); status (112,249,256,13) | partial | new rects and contents | P1 | Confirmed |
| B35-LAYOUT-004 | Grid geometry | 32.75×41.5, gap 1.5 | matches ±1 px | optional exact | P3 | Confirmed |
| B35-LAYOUT-005 | Badges | COURSE caption; Mario + N/T | partial | caption, sprite, one line | P2 | Confirmed |
| B35-LAYOUT-006 | Colours | measured RGB | matches in kind | measured values | P2 | Confirmed |
| B35-PREVIEW-001 | Live preview of every course | t=62, M2 >560 | partial (1-1 only) | all courses live | P1 | Confirmed |
| B35-PREVIEW-002 | Pane zoom | ≈0.77–1.0 px/gpx | differs (0.68) | tighter crop | P2 | Strongly inferred |
| B35-PREVIEW-003 | Pane camera | not determined | — | no change | P3 | Unknown |
| B35-PREVIEW-004 | Underground glyph row | t=62–70 | — | do not build | P3 | Unknown |
| B35-PREVIEW-005 | Pane white flashes | 163.00, 163.57 | missing | pre-KO flash only | P3 | Confirmed / trigger Unknown |
| B35-TARGET-001 | Persistent target (all contestants) | reticle always present | missing | session `target_id` + `TARGET_CHANGED` | P0 | Confirmed (player) |
| B35-TARGET-002 | Reticle | red 4-corner bracket | missing | draw on target pane | P0 | Confirmed |
| B35-TARGET-003 | Send = reticle flight | 0.2–0.3 s, t=509–623 | differs (gold line) | reticle flight | P0 · ZACK (line removal) | Confirmed |
| B35-TARGET-004 | Random mode | new pick per send | matches rule | keep; target = last recipient | P0 | Confirmed |
| B35-TARGET-005 | Selector UI | 4 pills, fade, t=354 | missing | selector element | P1 · ZACK | Confirmed |
| B35-TARGET-006 | Lowest Time / Most Coins / Attackers | Lowest Time observed; others labels only | missing | policies | P1/P2 · ZACK | Strongly inferred / Unknown |
| B35-TARGET-007 | Bots target; `attackers_of` | red lines, eye "1" | missing | bot `target_id` | P1 | Strongly inferred |
| B35-ATTACK-001 | Defeat → send to target | defeated = sent 215 | matches (native) | recipient = target | P0 | Confirmed |
| B35-ATTACK-002 | No bot→bot visuals | none observed | differs | remove | P1 · ZACK | Strongly inferred |
| B35-ATTACK-003 | Re-send incoming | defeated = sent | differs (R0) | incoming defeats send | P0 · ZACK | Strongly inferred |
| B35-ATTACK-004 | More enemy kinds | Piranha, Bill, … | partial | add per course | P2 | Confirmed |
| B35-INCOMING-001 | Moving icon bar | t=517–523, 746–754 | differs | travelling icons | P1 | Confirmed |
| B35-INCOMING-002 | Delivery cadence | 3–6 s | close | keep | P2 | Strongly inferred |
| B35-INCOMING-003 | Pale incoming enemies | t=517.6, 760, 1000 | differs (no tint) | pale modulate | P1 · ZACK | Strongly inferred |
| B35-INCOMING-004 | Red attacker lines | t=517.6, 1000 | partial | pane → bar lines; no frame flash | P1 | Confirmed |
| B35-INCOMING-005 | WATCH OUT! | t=517.6, 1000 | missing | pill while attacked | P2 | Strongly inferred |
| B35-INCOMING-006 | Eye counter | t=1000 | missing | attackers count | P2 | Strongly inferred |
| B35-TIMER-001 | Start ≈35 | M2 t=510–520 | differs (600) | 35 | P0 · ZACK | Strongly inferred |
| B35-TIMER-002 | 1 Hz | 60-frame ticks | matches | keep | P0 | Confirmed |
| B35-TIMER-003 | 2 Hz at ≤5 alive | t=291.9, 753.8 | missing | 2 per s | P0 · ZACK | Confirmed |
| B35-TIMER-004 | Defeat bonus | +1…+5 | missing | +2 per defeat (tunable) | P0 · ZACK | Confirmed / formula Unknown |
| B35-TIMER-005 | Flag +15, freeze | t=135, 736, 814 | differs | +15, freeze | P0 · ZACK | Confirmed |
| B35-TIMER-006 | Cap 400 | never >400 | missing | clamp | P0 · ZACK | Strongly inferred |
| B35-TIMER-007 | Bot time economy | implied | differs | same rules for bots | P0 · ZACK | Strongly inferred |
| B35-TIMER-008 | KO credit reward | t=163.100 | missing | time → max, coins, `ko_by` | P1 · ZACK | Confirmed event / Strongly inferred mechanism |
| B35-TIMER-009 | Timer display | top-right chrome digits | differs | in-window timer | P1 | Confirmed |
| B35-TIMER-010 | Time-out | not observed | exists | keep | P0 | Unknown |
| B35-COIN-001 | Coin counter | top-left | missing | session coins + HUD | P0 · ZACK | Confirmed |
| B35-COIN-002 | Item box | ? + 20 + X; dimmed <20 | missing | element | P0 · ZACK | Confirmed |
| B35-COIN-003 | Roulette | 3 s spin, 2 s hold | missing | exact sequence | P0 · ZACK | Confirmed |
| B35-COIN-004 | Bot coins | ranking coins | missing | simple model | P2 | Strongly inferred |
| B35-COIN-005 | KO coin reward | +53 at t=163.1 | missing | per TIMER-008 | P1 · ZACK | Strongly inferred |
| B35-COIN-006 | Chest bonus | 1655 / 572 | missing | display + placeholder rule | P2 · ZACK | Confirmed / formula Unknown |
| B35-COURSE-001 | Non-linear sequence | M2 12-course list | differs (linear) | seeded sequence | P1 · ZACK | Confirmed / rule Unknown |
| B35-COURSE-002 | Remixed warps | t=85, 235, 690 | differs | pool destinations | P3 | Confirmed |
| B35-COURSE-003 | Fast transition | ≈0.5 s fade, no card | differs | skip WORLD card | P1 | Confirmed |
| B35-COURSE-004 | Course badge update | per course | matches | keep | P2 | Confirmed |
| B35-ENEMY-001 | Native defeats | stomp/fire/shell/star | matches | keep | P0 | Confirmed |
| B35-ENEMY-002 | Incoming defeats | = ATTACK-003 | differs | see ATTACK-003 | P0 · ZACK | Strongly inferred |
| B35-ENEMY-003 | Incoming = ordinary enemies | t=519 pit fall | matches | keep | P0 | Confirmed |
| B35-ENEMY-004 | Stomp streak stat | results | missing | count | P3 | Confirmed |
| B35-KO-001 | Blue KO card with placement | t=1000 | partial | card | P1 | Confirmed |
| B35-KO-002 | KO card animation | 0.8 s, t=526.4 | differs | anim | P2 | Confirmed |
| B35-KO-003 | Orange KO-credit card | R31 t=163.1 | missing | variant | P2 | Confirmed / contents Unknown |
| B35-KO-004 | Placement rule | alive at KO | matches | keep | P0 | Confirmed |
| B35-KO-005 | Alive badge same-frame | t=163.100 | matches | keep | P1 | Confirmed |
| B35-RESULT-001 | Ready/3/2/1/GO | t=500.5–505.75 | differs | countdown | P2 | Confirmed |
| B35-RESULT-002 | Win medal + bonus | t=418–455 | differs | medal, row, bonus | P2 | Confirmed (loss Unknown) |
| B35-RESULT-003 | Ranking / Results pages | t=465–470, 1100 | missing | two pages | P2 | Confirmed |
| B35-RESULT-004 | Rematch / Main Menu | buttons | differs (auto 10 s) | A/B, no auto | P2 · ZACK | Confirmed |
| B35-RESULT-005 | Matchmaking card | t=5–20, 480–500 | missing | optional | P3 | Confirmed |
| B35-UI-001 | Typography | rounded bold sans | differs | UI font | P2 · ZACK | Confirmed |
| B35-UI-002 | Colour language | red/blue/orange/gold | partial | adopt | P2 | Confirmed |
| B35-UI-003 | "+N" popups | clock +N | missing | per TIMER-004 | P1 | Confirmed |
| B35-UI-004 | HUD opacity | translucent selector | missing | per element | P2 | Confirmed |
| B35-PERF-001 | Freeze KO'd atlas cells | static cards | missing | skip their rendering | P1 | Confirmed (cards static) |
| B35-PERF-002 | Event-driven HUD text | — | per-frame writes | write on change | P3 | — |

"ZACK" in the Priority column means the item must not be built until Zack approves (section 19).

## 18. Recommended Implementation Order

Milestones are bounded so one Sonnet session can finish one, run the whole Battle suite and write its doc (48, 49, …).
Every milestone keeps:

* `BattleSession` as the sole authority, with presentation read-only (source-scan tests stay);
* the two random streams' independence (doc 43);
* the doc 46 incoming bridge;
* Classic mode unchanged;
* the 480×270 composition.

### M-T1 — Targeting core (start here; no approval needed)

* **Scope**
  * B35-TARGET-001: persistent `target_id` for the player and bots, and `TARGET_CHANGED`.
  * B35-TARGET-002: the reticle.
  * B35-TARGET-004: Random semantics, where the target is the last recipient.
  * B35-TARGET-007: bot targets and `attackers_of` (data only; nothing displays them yet).
  * B35-PERF-001: freeze KO'd atlas cells. This is independent and safe; include it if the milestone has time,
    otherwise move it to M-K.
* **Dependencies**: none.
* **Files**:
  * `BattleTargeting.gd`, `BattleTargetingRandomSurvivor.gd`, `BattleAttackSystem.gd` (send path),
    `BattleSession.gd` (`EventType` appended, `attackers_of`), `BattleContestant.gd` (use `target_id`);
  * a new reticle drawer (`BattleTargetReticle.gd`, or inside `BattleAttackLayer.gd`), `BattleScreen.gd` (wiring);
  * `BattlePreviewAtlas.gd` / `BattlePreviewCell.gd` for PERF-001.
* **Acceptance**: as listed under each ID. Also:
  * a full 200-seed run has no invalid target (self, eliminated, −1 while ≥2 alive);
  * the player stream advances exactly once per accepted player send;
  * the bot stream advances exactly `DRAWS_PER_BOT × 34` per tick.
* **Tests**:
  * New pure `tests/battle_targeting_test.gd`.
  * Extend `battle_attack_test.gd` and `battle_attack_view_test.gd` (recipient = target).
  * A GL render check for the reticle corners in `battle_attack_render_test.gd`.
  * Every existing Battle suite listed in doc 46 §11 must pass. Update only expectations that encode "the recipient is
    chosen at send time without persisting".
* **Untouched**:
  * the timer and `START_TIME`;
  * the gold send line (its removal is TARGET-003, which needs approval);
  * bot→bot lines;
  * the incoming spawner, layout, coins, courses, results;
  * the R0 rule.

### M-T2 — Send flight and attack-visual cleanup (after Zack approves Q7)

* **Scope**: B35-TARGET-003 (reticle flight replaces the gold line), B35-ATTACK-002 (remove bot→bot lines and,
  if approved, pane pips), B35-INCOMING-004 (red pane → bar lines, no frame flash).
* **Depends on**: M-T1.
* **Files**: `BattleAttackPresentation.gd`, `BattleAttackLayer.gd`, `BattleAttackGeometry.gd`,
  `BattleOpponentPane.gd`, and the kill-position hand-off in `Enemy.report_battle_defeat` (presentation data only).
* **Acceptance**: per IDs; re-run `battle_attack_bench.gd` and record the draw-call reduction.
* **Untouched**: the session send logic and incoming delivery.

### M-TIME — Time economy (after Zack approves Q1/Q2/Q3)

* **Scope**: B35-TIMER-001, 003, 004, 005, 006, 007, 009 (the timer display may use the existing canvas label until
  M-HUD), 008 and COIN-005 if Q3 is approved.
* **Depends on**: none, but must land as one change (001 without 007 breaks every match).
* **Files**: `BattleSession.gd`, `BattleBotSimulator.gd`, `BattleAttackSystem.gd` (bot defeats grant time),
  `BattleHandler.gd` (flag freeze), a popup effect in `BattleScreen`.
* **Acceptance**: per IDs, plus a balance report (median match length, TIME vs HAZARD KO shares, player time
  distribution) over 200 seeds, compared with the 600 s baseline.
* **Untouched**: targeting, presentation of attacks, layout.

### M-COIN — Coins, item box, roulette (after Zack approves Q4)

* **Scope**: B35-COIN-001, 002, 003, 004, 006.
* **Depends on**: M-HUD for final placement. It can ship with a temporary position.
* **Files**: `BattleSession.gd` (coins, roulette state), `BattleHandler.gd` (coin polling, input), a new
  `BattleItemBox.gd`, item effects through `Player`.
* **Acceptance**: per IDs; Classic coins and 1-ups unchanged outside Battle.

### M-TMODE — Selector and targeting modes (after Zack approves Q5/Q6)

* **Scope**: B35-TARGET-005, 006, INCOMING-006.
* **Depends on**: M-T1. Lowest Time needs M-TIME, Most Coins needs M-COIN, Attackers needs only M-T1.

### M-INC — Incoming bar and enemy look (tint after Zack approves Q13)

* **Scope**: B35-INCOMING-001, 005, 003 (tint).
* **Depends on**: M-T2 for the red-line endpoint.
* **Files**: `BattleIncomingStrip.gd`, `BattleIncomingSpawner.gd` (tint only).
* **Untouched**: spawn placement and pacing (doc 46).

### M-HUD — Layout and in-window HUD (after Zack approves Q14)

* **Scope**: B35-LAYOUT-001, 002, 003, 005, 006, UI-001…004.
* **Depends on**: M-TIME and M-COIN for content; can land with stubs.
* **Files**: `BattleHudLayout.gd`, `BattleScreen.gd`, `GameHUD.gd` (Battle-only hide).
* **Acceptance**: the layout tests from doc 38 updated to the new rects; the gameplay-sizing invariant (256×240
  viewport) unchanged.

### M-K — Elimination presentation

* **Scope**: B35-KO-001, 002, 003, PREVIEW-005 (pre-KO flash), and B35-PERF-001 if not done in M-T1.
* **Depends on**: TIMER-008 for the orange variant (optional).

### M-COURSE — Course sequence, transitions and previews (after Zack approves Q10)

* **Scope**: B35-COURSE-001, 003, PREVIEW-001, then COURSE-002, PREVIEW-002 and ATTACK-004 as follow-ups.
* **Depends on**: none for COURSE-003; COURSE-001 before PREVIEW-001.
* **Notes**: the largest milestone. Split it into COURSE-003, then COURSE-001, then PREVIEW-001 if needed.

### M-RESULT — Start and results flow (RESULT-004 after Zack approves Q11)

* **Scope**: B35-RESULT-001, 002, 003, 004, ENEMY-004, optional RESULT-005.

## 19. Sonnet Handoff

**Authoritative spec**: `docs/47-smb35-implementation-reference.md` (this file). It supersedes docs 35–46 where they
describe what SMB35 does; docs 35–46 still define how the current system works.

**Baseline**: branch `battle-mode`, commit `fa88f68` (M6a, doc 46). Re-check `git log` before starting. Unrelated local
changes (`.import`, `project.godot`, `.DS_Store`) are not yours: do not commit them.

**First milestone**: **M-T1 — Targeting core.**

* **Requirement IDs**: B35-TARGET-001, B35-TARGET-002, B35-TARGET-004, B35-TARGET-007. Include B35-PERF-001 only if
  time allows.
* **Dependencies**: none. It needs no Zack decision: it keeps random-survivor selection and adds persistence,
  visibility and bot targets.
* **Acceptance criteria**:
  1. The session holds a valid `target_id` for every alive contestant while ≥2 are alive. `TARGET_CHANGED` is
     appended to `EventType`, with existing values unchanged.
  2. Every send goes to the sender's target as updated by its policy. In Random mode the target is the last recipient.
  3. A KO'd target re-targets the same tick. A target is never self or eliminated.
  4. A red four-corner reticle is drawn on the player's target pane in PRE_ROUND and PLAYING, never on a KO card.
  5. `session.attackers_of(0)` is correct every tick (pure test).
  6. Determinism: twin sessions are identical. The player stream draws once per accepted player send. The bot stream
     draws exactly `DRAWS_PER_BOT` per bot per tick.
* **Regression expectations**:
  * All Battle suites in doc 46 §11 pass: `battle_session_test`, `battle_attack_test`, `battle_attack_view_test`,
    `battle_round_test`, `battle_screen_test`, `battle_hud_test`, `battle_preview_atlas_test`, `battle_preview_test`
    (golden attack-free hashes must not change), `battle_attack_screen_test`, `battle_round_lifecycle_test`,
    `battle_attack_game_test`, `battle_incoming_plan_test`, `battle_incoming_game_test`, and the GL suites
    (`battle_attack_render_test`, `battle_screen_render_test`, `battle_preview_render_test`,
    `battle_incoming_render_test`).
  * Classic mode is unchanged. No script errors in any log.
  * Commands are in doc 46 §11.
* **Do not change in M-T1**:
  * the timer (600 s) and any balance constant;
  * the doc 44 gold send line and bot→bot lines, and pane pips;
  * the R0 re-send rule;
  * the incoming spawner, placement and pacing;
  * the layout geometry (240-row window, strips) and the classic GameHUD;
  * course progression, the results flow and the pre-round timings;
  * `reference.mp4`. Never commit or upload it, and never put its frames, audio or pixels in any document, test
    fixture or model context.
* **Write when done**: `docs/48-battle-targeting-core-m-t1.md` (what was built, tests, measurements, open risks).

**Unresolved questions requiring Zack approval** (do not implement the affected IDs until answered):

* Q1 — Replace the flat 600 s model with SMB35's economy?
  * Start about 35, defeat bonus, flag +15 with freeze, cap 400, 2 Hz at ≤5 alive, applied to bots too.
  * IDs: TIMER-001/003–007.
* Q2 — Time per defeat: fixed +2, or a combo-scaled +1…+5? (TIMER-004)
* Q3 — KO credit: should it exist?
  * Qualifying rule: is "the player has an ACTIVE attack on the KO'd bot" acceptable?
  * Rewards: time to max and +50 coins? (TIMER-008, COIN-005)
* Q4 — Are coins, the 20-coin roulette (Mushroom / Fire Flower / Star / POW, weights) and the chest bonus in scope?
  (COIN-*)
* Q5 — The targeting selector and its controller mapping, i.e. which input selects the four modes. (TARGET-005)
* Q6 — Should bots use only Random, or a mix of modes? (TARGET-006/007)
* Q7 — May the doc 44 presentation change?
  * Replace the player's gold send line with the reticle flight.
  * Remove bot→bot lines.
  * Remove the window-frame flash; keep or remove the pane pips.
  * IDs: TARGET-003, ATTACK-002, INCOMING-004.
* Q8 — Accept the inferred WATCH OUT! trigger (while a player-targeted send is in flight)? (INCOMING-005)
* Q9 — May the preview zoom change after an exact measurement? (PREVIEW-002)
* Q10 — Non-linear, seeded course sequence (and which courses are in the pool) instead of linear 1-1→8-4?
  (COURSE-001/002)
* Q11 — Results without the 10 s auto-advance (A = next round, B = quit)? (RESULT-004)
* Q12 — UI font choice and licence. (UI-001)
* Q13 — Reverse doc 46's "no visual distinction" and tint incoming enemies pale? (INCOMING-003)
* Q14 — Switch the window to 224 visible rows, and replace the classic HUD row with the SMB35 in-window HUD?
  (LAYOUT-001/002)
* Q15 — Reverse rule R0 so a player-defeated incoming enemy sends again? (ATTACK-003, ENEMY-002)

**Items marked Unknown** (do not build beyond what each block states):

* the starting time's exact value;
* the per-defeat bonus formula;
* how the chest bonus grows;
* item weights;
* the Most Coins and Attackers behaviour;
* the course-selection rule;
* which 16 rows are cropped;
* the pane camera;
* the loss / time-out presentation;
* all audio.
