# 50 — Battle: SMB35 UI / visual fidelity pass (what was built and verified)

Status: implemented on top of `5325bd7` (M-T1, doc 49). Doc 47 is the authority for every number below; the reference video was not re-analysed, and none of its frames, pixels or audio is in this repository, in this document or in any test.
This pass changes **how Battle looks and answers input, never what it does**: no attack rule, spawn rule, targeting rule, timer, coin, item, bot, round-outcome or level-progression behaviour was touched (section 8 lists what was verified unchanged).
Zack's physical comparison against the video is the final gate; section 12 is the list to compare.

## 0. How the brief and doc 47 were reconciled

| Brief item | Doc 47 ids | Done? | Basis and limits |
|---|---|---|---|
| 1 Central window 256×224 at (112, 8) | LAYOUT-001 | **yes** | display crop only (section 2); the 256×240 viewport, camera, walls and enemy activation are unchanged. Which 16 rows SMB35 hides is **Unknown** in doc 47; the NES overscan reading (8 top + 8 bottom) is used and is on the "Zack should judge" list |
| 2 HUD inside the window | LAYOUT-002, TIMER-009, COIN-001, COIN-002 | **yes, truthful parts only** | coin counter, clock + timer, item box (a reserved, dimmed, empty frame), selector; classic HUD row hidden; TIME/RANK labels removed. No economy, no roulette (section 3) |
| 3 Four-way selector replaces the readout | TARGET-005 | **yes (the picture)** | arrangement, labels, opacity, selected look, glow/settle timing, placement. The I / J / K / L keys stay provisional (Q5 open); Most Coins is drawn, refused, and keeps the mode |
| 4 Opponent panes | LAYOUT-004, PREVIEW-001 | **yes** | exact 32.75×41.5 cells, 1.25-unit grid start, doc-47 columns/rows; no text over live pictures; thin dark outline; the atlas and downsampling system are unchanged |
| 5 Reticle | TARGET-002 | **yes** | thinner, closer, punches on arrival and on a mode choice; shown from the first countdown frame (already). The reticle **flight** (TARGET-003) is M-T2 and was not touched |
| 6 Incoming bar | INCOMING-001, INCOMING-004 | **yes** | three zones with jagged boundaries, the player's power-state icon, icons travelling right → left to the gold boundary, thin red attacker lines ending in the bar. Spawn/attack timing untouched |
| 7 Lower status strip | INCOMING-005, INCOMING-006 | **partly, by design** | eye counter and WATCH OUT! built; the chest bonus box is **absent** (formula Unknown, needs the coin economy; nothing stands in for it) |
| 8 Match start | RESULT-001 | **yes** | HERE WE GO... 0.75 s, READY 1.5 s, 3 / 2 / 1 at 1 s each, GO! 0.8 s; frozen gameplay, the Battle clock, pause and the round state machine are unchanged |
| 9 KO pane | KO-001, KO-002, KO-004, KO-005 | **yes** | white flash, blue card, "KO" and the placement in a rivetted teal block, burst + smoke, second flash, settle in 0.8 s; same slot, no reordering. The orange card (KO-003) is not built (needs `ko_by` credit rules of the timer milestone) |
| 10 Wallpaper, borders | LAYOUT-006 | **yes** | measured colours, a lighter outer band over a deeper inner band, thin dark outlines; generated flat vector only, no artwork |
| 11 Typography | – | **yes** | the project's one bitmap font (FontMain) only |
| 12 Motion | – | **yes** | section 11 lists every timing |

Not touched, as instructed: `BattleSession` attack semantics, incoming-enemy behaviour (M6a), targeting strategy logic, bot simulation, spawn placement, attack caps, round outcomes, level progression, timer economy, coin economy, item roulette, enemy recycling, SMB3, Classic and every other game mode.

## 1. Files

New (all views; none can reach the session — `tests/battle_ui_test.gd` source-scans them):

| File | Role |
|---|---|
| `BattleHudText.gd` | the one place that draws text: positions the **ink** box of the 8×8 bitmap font (glyphs are 7×7 px inside a 16×16 cell, advance 8), fitting, outline by redrawing |
| `BattleHudShapes.gd` | rounded boxes with true half-unit hairline borders |
| `BattleTargetSelector.gd` | the four-pill selector: states, timeline (`opacity_at`, `label_scale_at`, `glow_at`, `shake_at`), pill rects |
| `BattleHud.gd` | coin counter, item box (reserved), clock + timer; hosts the selector |
| `BattleBadge.gd` | COURSE and ALIVE cards |
| `BattleBanner.gd` | the match-start words |
| `BattleStatusStrip.gd` | eye counter and the WATCH OUT! pill |

Changed: `BattleHudLayout` (every number below), `BattleScreen` (composition, crop, clocks, snapping), `BattleRound` (the countdown), `BattleOpponentPane` (outline, KO card), `BattleIncomingStrip` (the bar), `BattleTargetReticle`, `BattleAttackPresentation` (additive read-only fields: row `age` / `waited`, `watch_out()`), `BattleAttackGeometry` (`bar_point`), `BattleAttackLayer` (attacker line width), `GameHUD` (hidden while Battle is active). Tests and `tests/tools/battle_ui_capture.gd`: section 9.

## 2. Layout (doc 47 §2): the measured values used

Canvas 480×270 = 1080p ÷ 4. Everything is placed from `BattleHudLayout`.

| Element | Rect (canvas units) | Source |
|---|---|---|
| Game window (visible) | (112, 8, 256, 224) | LAYOUT-001 |
| Simulation viewport | 256×240, unchanged; shown with its top 8 and bottom 8 rows cropped | LAYOUT-001 notes |
| Frame | (108, 0, 264, 268): light band 2 outside, deeper band inside | LAYOUT-006 |
| Incoming bar (strip A) | (111.5, 236, 257, 12) | LAYOUT-003 |
| Status strip (strip B) | (111.5, 249, 257, 13) | LAYOUT-003 |
| Opponent cells | 32.75 × 41.5 (131 × 166 device px at 1080p), gap 1.25 / 1.5 | LAYOUT-004 |
| Columns | left 1.25, 35.25, 69.25; right 377.25, 411.25, 445.25 | LAYOUT-004 |
| Rows | y 10.5, 53.5, 96.5, 139.5, 182.5, 225.5 | LAYOUT-004 |
| COURSE badge | (72.5, 0, 30, 30) | LAYOUT-005 |
| ALIVE badge | (376.25, 0, 30.75, 43.75) | LAYOUT-005 |
| Coin counter | (115, 10, 35, 9) | LAYOUT-002, COIN-001 |
| Item box | (112.5, 20, 40, 40) | LAYOUT-002, COIN-002 |
| Timer | (296, 10, 69, 18) | LAYOUT-002, TIMER-009 |
| Selector pills | Lowest Time (225, 13.75), Random (200, 28.75), Most Coins (252.5, 28.75), Attackers (225, 42), centre button (239.5, 32.5) | TARGET-005 (1080p boxes ÷ 4) |
| Colours | wallpaper (255,190,0); frame light (255,217,56); frame dark (255,182,0); outline (59,51,33) | LAYOUT-006 |

**The crop.** `GameWindow` is a 256×224 clipping Control at (112, 8); inside it the `SubViewportContainer` sits at (0, −8) and still shows the whole 256×240 viewport. `get_viewport_rect()` is still 256×240 for Mario, the camera and every enemy (checked by `battle_screen_test`: camera walls ±128, the level sees 256×240). The hidden rows are the top 8 (where the classic HUD row lived) and the bottom 8 (half of the lower ground row).

**Fractions.** Most cells are not whole logical pixels, exactly as doc 47 notes. They are exact at 1080p and a device pixel's rounding at other sizes. Godot rounds every Control and canvas item to whole pixels by default, which silently turns a 0.5-unit hairline into one unit and moves the panes; so while Battle owns the root window it turns `gui_snap_controls_to_pixels` and `snap_2d_transforms_to_pixel` off and gives the user's values back on leaving (`BattleScreen._apply_canvas` / `_restore_window`). The game window keeps its own pixel snapping. Verified by a GL test that samples the outline at 111.75 / 368.25.

**Cell aspect.** The preview atlas cells stay 187×240 (doc 40's cost table stands). Their picture is stretched into 32.75×41.5, about 1.3 % wider than before; imperceptible, recorded here.

## 3. The HUD in the window

* **Classic row hidden**: `GameHUD.handle_main_hud` hides `Main` and `ModernHUD` while `BattleScreen.is_active()`; Classic is unchanged (tested: the row is visible again after leaving).
* **Coin counter**: the classic game's own count (`Global.coins`), orange coin and white outlined number. Battle's coin economy is a later milestone (Q4). The classic counter wraps at 100 (its 1-up rule), so it will show 0 again after 100 coins; no Battle value is invented.
* **Timer**: clock icon and large silver numerals, whole seconds, no leading zeros, the player's Battle `time_left`; the tick-frame update comes from the session. The dev sim-speed multiplier shows as a small "X2" under it only when it is not 1. No low-time styling (Unknown in the reference).
* **Item box**: **reserved**, not a feature. It is drawn dim and translucent like the reference's box with fewer than 20 coins, with the roulette's fixed cost of 20. It never changes state; no X glyph is drawn (there is no control).
* **Selector**: section 4. The classic `TIME`/`RANK` canvas labels are gone (RANK was a provisional number only).

## 4. The targeting selector (B35-TARGET-005)

* **Arrangement**: Lowest Time top, Random left, Most Coins right, Attackers below, a round centre button between Random and Most Coins. Labels in capitals (the font has no lower case).
* **Pill widths**: the reference's rows, centres and heights are kept; widths grow just enough to hold the labels at a readable size in the 8×8 font (the reference uses a condensed typeface). Doc 47's widths are 28.75 / 28.75 / 42.5 / 28.75; ours are 34–59.
* **Centre button**: drawn without the reference's "R" (it names the right stick; the controller mapping is open, Q5).
* **States**: at rest the whole cross is translucent (alpha 0.5) with the chosen pill filled gold; on a change the cross is fully opaque **on the same frame**, the new label swells to 130 % by 0.2 s and settles by 0.55 s, the glow settles to a steady glow, the cross is opaque for 0.6 s and is back at rest by 1.75 s (doc 47: 1.5–2 s). Pure functions of the age: `opacity_at`, `label_scale_at`, `glow_at`.
* **Most Coins** is drawn greyed (unavailable). Trying it: `select_target_mode` returns false, the **mode and every random stream are untouched**, the cross lights up and the pill shakes and flashes red for 0.5 s. The old "NOT AVAILABLE YET" text is gone.
* **Round start**: the cross shows itself opaque as the round is set up and fades during HERE WE GO / READY.
* **Keys**: I / J / K / L, provisional, unchanged; read by the screen only; nothing in the game's InputMap or settings.
* **Pause**: the selector's animation clock does not advance while the game is paused (`_advance_ui` gets 0), and no mode can be chosen then (tested).

## 5. Opponent panes and the KO card

* **Panes**: 34 panes at the doc-47 grid; a 0.5-unit dark outline (59,51,33) replaces the orange 1-unit frame; the contestant number and "W-L" text are **off** (doc 47 PREVIEW-001: the live pane has no text). They come back as a debug aid with `SMB1R_BATTLE_LABELS=1`, `--battle-labels` (debug builds) or **F3** on the Battle screen (debug builds), which also turns on the old counts legend in the incoming bar. The queued/active pips and the target tint of M5/M6b are unchanged.
* **COURSE badge**: white rounded card, brown border, small "COURSE" caption over a large "W-L".
* **ALIVE badge**: a small Mario (the preview art's own, a drawn stand-in without previews) over "N/35", updated on the frame the session's `alive_count` changes (reads "35/35" at the start).
* **KO card** (`BattleOpponentPane`): when the preview shows the KO (`marked`, unchanged timing) the pane plays 0.8 s drawn at display resolution: white flash (0–0.07 s), the blue card pops in from the middle with an ease-out-back overshoot (0.07–0.5 s), an eight-ray starburst and six smoke puffs (0.1–0.6 s), a second flash (0.6–0.67 s), then it rests. The card has "KO" at the top and the contestant's final **placement** in a teal block with four rivets. No contestant id on it. It costs no atlas work (the picture underneath keeps rendering exactly as before; PERF-001's cell freeze is M-K).
* A pane already marked when first seen settles instead of animating; a new round clears it; the animation clock stops while paused.

## 6. The reticle (B35-TARGET-002)

Red (255,26,26 — within the measured r>225, g<50, b<70), arms a quarter of the pane's width, **0.75 thick** (3 device px), inner edge **0.5** outside the pane: the whole bracket lives in the 1.25–1.5 unit gap, so it never covers a picture or another pane (tested for all 34). It appears on its pane the frame the target changes (the reference does not slide it), with a 0.3 s **punch**: it starts 2 units wider, snaps in, and a soft halo fades. The same punch plays when the player picks a mode. Still shown from PRE_ROUND on, hidden on a KO'd pane and outside PRE_ROUND/PLAYING. The send line (gold, 0.55 s, enemy head) is **unchanged**: replacing it by the reticle flight is M-T2 (Q7).

## 7. The incoming bar and the status strip

**Bar** (`BattleIncomingStrip`): gold left third, orange middle third, darker orange right third, split by three-tooth jagged boundaries; the player's icon in its **current power state** at the left (the preview art's Mario, read from `Global.player_power_states`; a drawn stand-in otherwise). Icons are placed by a pure function of the attack's phase and ages (`place_all`):

| Phase (unchanged, `BattleAttackPresentation.phase_of`) | Where and how |
|---|---|
| QUEUED, line in the air | hollow dotted placeholder at the right end |
| QUEUED, landed | enters at the right end and travels **left** to the gold boundary, taking `ACTIVATION_DELAY − line time` (2.45 s) after landing: it arrives when the attack system activates it, counted from the send; yellow outline pulses as it lands |
| ARRIVING (ACTIVE, not in the level) | waits just right of the boundary, amber pulsing outline; flashes white as it becomes ACTIVE; an ACTIVE icon that is not there yet is there within 0.3 s (the sim can run ahead of the clock at X2/X4) |
| IN_LEVEL | crosses the boundary with a white flash and stays in the **gold zone** with a red outline for as long as its enemy is in the level |
| RESOLVED | fades where it was: green if the player defeated it, grey otherwise |

Order along the bar is send order, never crossing. One icon per sequence id (tested against the session's queue). There is no text and no count on the bar. The state machine is not duplicated: a phase is derived from the same session state, and `rows` / `counts` still equal the authoritative queue frame by frame.

**Attacker lines** (INCOMING-004, part): a bot's send at the player is now a **thin (1-unit) red line ending inside the bar**, at its end on the sender's side (`BattleAttackGeometry.bar_point`). The player's own send line and bot→bot lines are unchanged.

**Status strip**: eye icon + the number of opponents aiming at the player (`attackers_of(PLAYER).size()`, hidden without the attack loop) at the left; the **WATCH OUT!** pill (red, black outline, yellow letters, a small pop) from the moment a bot sends an enemy at the player until 1 s after its line lands (the player's own sends and bot→bot sends never show it; a presentation created mid-round does not replay an old one). Both meanings are *strongly inferred* in doc 47 (Q8). The chest bonus box is **absent**.

## 8. What was verified unchanged

* `BattleSession`, `BattleAttackSystem`, targeting policies, bots, M6a spawns: not modified; `battle_session_test` 21, `battle_attack_test` 168, `battle_targeting_test` 120, `battle_incoming_plan_test` 95, `battle_incoming_game_test` 83, `battle_arrival_game_test` 110, `battle_attack_game_test` 81 pass unchanged, and `battle_attack_view_test` still proves a session read by a presentation is identical, tick by tick, to the same session without one.
* `BattleAttackPresentation` gained read-only fields and `watch_out()`; its source scan (no `.attacks`, `report_`, `resolve_` …) still passes, and the same scan runs on the ten UI classes of this pass.
* The preview atlas, shader and cost are untouched (`battle_preview_atlas_test` 44, `battle_preview_test` 77 with the golden hashes).
* Pausing: the tree-paused game freezes the Battle clock and the presentation (unchanged); the new animations (selector, reticle punch, KO card, WATCH OUT! pop, banner pop) take the screen's own clock, which is 0 while `get_tree().paused` or `Global.game_paused`; the match-start countdown holds on its word.

## 9. Tests

| Suite | Checks | New / changed in this pass |
|---|---|---|
| `battle_ui_test` (new, headless, no level) | 128 | text helper; the selector's timeline, states, refusal, pill geometry (arrangement, no overlap, fits, inside the window); reticle geometry for all 34 panes, punch, visibility; bar placement and phase mapping from a real session and presentation (QUEUED → ARRIVING → IN_LEVEL → RESOLVED, one icon per seq); WATCH OUT! hold, extension, no false triggers; status strip; banner; KO card timeline and state machine (settle, pause, no move, new round); HUD text; read-only scan of ten view classes |
| `battle_hud_test` | 64 | the layout section rewritten to doc 47's rects, grid columns/rows, HUD rects, selector arrangement; badges and timer bound to the session |
| `battle_round_test` | 69 | the match-start sequence (words at probe times, 5.25 s, release exactly at GO!, pause holds, shortened override stays READY) |
| `battle_round_lifecycle_test` | 111 | the sequence on the real screen at each word; pause holds the countdown and the banner's pop; window frozen throughout |
| `battle_screen_test` | 114 | crop (256×224 clip, view offset −8, still 256×240), classic HUD hidden in Battle and back in Classic, Battle HUD over the window |
| `battle_attack_screen_test` | 101 | selector follows the session and the keys; pause freezes selector and reticle punch and blocks selection; Most Coins refused with the mode and streams untouched; eye counter; WATCH OUT! on a bot's send, off for the player's; bar phases on the real screen; new round starts clean (selector, WATCH OUT!, KO cards, badge 35/35) |
| `battle_attack_view_test` | 118 | the bar landing point and the thin line |
| `battle_screen_render_test` (GL) | 43 | measured colours within ±8/255, the dark outline at 111.75 / 368.25, bar zones, no level leaking above or below the window, HUD drawn over the window, reticle red at all four corners of the target pane only, the chosen pill gold and then back to rest, the KO card blue with its placement, the result card dims only the window |

Mutations were not part of this pass (no gameplay logic changed). Pixel checks are few on purpose: only colours, the hairline, the reticle corners, the chosen pill and the KO card.

Commands: `godot --headless --fixed-fps 60 --path . -s tests/<suite>.gd`; GL: `xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 -s tests/<suite>.gd -- pack=SandboxStandIn`.

`tests/tools/battle_ui_capture.gd` renders the situations of this pass to PNGs (match start words, whole screen, selector states, the bar with travelling icons and WATCH OUT!, the KO animation at six moments, labels, the crop) with the session clock driven by hand, so Zack can lay a still of the same moment beside the reference.

## 10. Result

**All 17 headless suites and all 5 GL suites pass, with no script error or parse error in any log.**

| Headless | ok | | GL (xvfb, opengl3) | ok |
|---|---|---|---|---|
| `battle_ui_test` (new) | 128 | | `battle_screen_render_test` | 43 |
| `battle_hud_test` | 64 | | `battle_attack_render_test` | 50 |
| `battle_round_test` | 69 | | `battle_incoming_render_test` | 12 |
| `battle_round_lifecycle_test` | 111 | | `battle_arrival_render_test` | 32 |
| `battle_screen_test` | 114 | | `battle_preview_render_test` | 24 |
| `battle_attack_screen_test` | 101 | | | |
| `battle_attack_view_test` | 118 | | | |
| `battle_session_test` / `battle_attack_test` / `battle_targeting_test` | 21 / 168 / 120 | | | |
| `battle_incoming_plan_test` / `battle_incoming_view_test` | 95 / 107 | | | |
| `battle_incoming_game_test` / `battle_arrival_game_test` / `battle_attack_game_test` | 83 / 110 / 81 | | | |
| `battle_preview_atlas_test` / `battle_preview_test` | 44 / 77 | | | |

Existing suites that encode the old look were updated, not weakened: the GL strip/reticle checks sample the new bar by the icon positions `place_all` gives, and a neighbouring pane's corner sample can now sit inside the target's own bracket (the bracket fills the gap between panes), so "no other pane" became "no other pane has all four". One suite (`battle_attack_screen_test`) is timing-sensitive under heavy parallel load and passes alone; the regression was run in small batches.

Lessons recorded for the next pass: Godot rounds Controls and canvas-item transforms to whole pixels by default (section 2); a reticle sample must wait for the 0.3 s punch; a test that replaces `attacks.targeting` with a fixed policy also removes the modes (`mode_available` is the policy's).

## 11. Timings used (motion)

Selector: opaque at once, 0.6 s hold, rest by 1.75 s; swell peak 0.2 s, settled 0.55 s; refusal 0.5 s. Reticle punch 0.3 s. KO card 0.8 s (flash 0–0.07, pop 0.07–0.5, puffs 0.1–0.6, flash 0.6–0.67). Banner word pop 0.22 s. WATCH OUT! pop 0.18 s, hold 1 s after the line lands. Match start: 0.75 + 1.5 + 3 × 1.0 = 5.25 s frozen, GO! 0.8 s. Bar icon trip 2.45 s after landing; ACTIVE catch-up 0.3 s; the existing M6b flashes (0.7 / 0.45 / 0.6 / 0.5 s) are unchanged.

## 12. For Zack: what to compare against the video

1. **Window and crop**: the window should read as 256 wide × 224 tall; compare which rows are hidden (we hide 8 at the top and 8 at the bottom; the ground's lower row is half cut). If the reference cuts differently (e.g. 0 top / 16 bottom) it is one constant (`GAME_CROP_TOP/BOTTOM`) and the window rect.
2. **HUD**: coin counter and item box top-left, selector top-middle, clock and big timer top-right; their sizes and distances from the window edges; the item box is a dim placeholder.
3. **Selector**: pill arrangement and widths, resting opacity, how long it stays bright after a change, the label swell, the gold fill; press I / J / K and L (refused).
4. **Panes**: grid spacing and outline weight; no text on the pictures; COURSE and ALIVE card proportions, the Mario on the ALIVE card.
5. **Reticle**: thickness, distance from the pane, and the punch (the reference may not punch; one constant each).
6. **Incoming bar**: zone proportions and colours, tooth size, icon size and travel speed, the gold-zone markers (the reference removes an icon on release; we keep it as a marker while its enemy lives), the red attacker line ending in the bar.
7. **Status strip**: eye counter and WATCH OUT! placement; whether the pill should stay longer or shorter; the empty right-hand part (the chest bonus is not built).
8. **Match start**: HERE WE GO... (the reference shows it on a matchmaking card, not over the level), READY, 3, 2, 1, GO! — timing and letter size; this start is now 5.25 s frozen instead of 2.5 s.
9. **KO card**: blue shade, the placement block, the animation's length and feel.
10. **Colours**: wallpaper, frame bands, outline.

## 13. Differences from SMB35 that were kept on purpose

* Typeface: the 8×8 bitmap font everywhere (no condensed font, no chrome gradient on the timer: a silver face over a darker copy, dark outline).
* The in-level icon stays in the bar's gold zone (M6b semantics) instead of disappearing on release.
* The red frame flash on the window for attacks at the player, bot→bot lines and the pane pips stay (Q7); the pale tint on incoming enemies is not applied (Q13); rule R0 stands.
* The player's send is still the gold line; the reticle flight is M-T2.
* The Mario on the ALIVE card is always small Mario (the reference's is a small Mario too); the bar's icon follows the power state.
* Selector pills are wider than the reference's, and the centre button has no letter.
* Item box and coin counter are placeholders of data that exists (`Global.coins`) or none (the box); no chest bonus.
* The orange KO card for opponents the player KO'd is not built.
* Debug aids (F3, `--battle-labels`) exist because bots have no names; they are debug-build only.

## 14. Dependencies on later milestones

| Piece | Waits for |
|---|---|
| Reticle flight replacing the gold send line; removing bot→bot lines, the frame flash, pane pips | M-T2 and Q7 |
| Selector controller mapping (replacing I/J/K/L); the "R" glyph | Q5 |
| Most Coins becoming selectable; a real coin counter; the item box states and roulette; the chest bonus | Q4 (coin economy) |
| Lowest Time being meaningful (everyone's time is equal today); timer low-time styling | Q1–Q3 (time economy) |
| Pale incoming enemies | Q13 |
| Orange KO card | the KO-credit rules (TIMER-008) |
| KO'd cells stop rendering | M-K (PERF-001) |
| Course badge following a real course sequence | Q10 |
| Results pages (medal, ranking, bonus) | the results milestone |

## 15. Unknowns that were left alone

Which 16 rows SMB35 hides; whether the reticle punches in the reference; the exact WATCH OUT! trigger and hold; how the eye counter is defined; the chest bonus formula; low-time timer styling; the wallpaper's finer pattern (flat colour is used); the loss presentation of the reference (never observed).
