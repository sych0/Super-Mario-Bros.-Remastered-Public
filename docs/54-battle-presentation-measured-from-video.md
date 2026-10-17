# 54 — Battle: the send, the attacker lines, WATCH OUT!, the incoming bar and the KO card, measured frame by frame from the reference video

Status: implemented on top of `6249738` (doc 53). A presentation-only pass: no targeting, recipient, RNG, attack qualification, send count, queue,
spawn, bot, timer, coin, round-outcome, course-progression or SMB3 rule was touched (section 12). It **corrects doc 52**: the player's send is
not "a hold then a snap", it is a constant-speed flight. It also corrects four readings in docs 47 and 50 that the reference's frames refute
(the lines' endpoint, the eye counter, the reticle's size, the retained gold-zone marker).

## 0. Evidence and method

The reference is the public SMB35 video (`https://www.youtube.com/watch?v=AUcFTEfFp58`), 1920x1080, **60 fps**, 1115.8 s, read from a private
mirror in the cloud container (`sych0/reference-video`, a Git LFS object whose SHA-256 matches its pointer). Under the policy for the public video
(`tools/reference/README.md`) frames and contact sheets were viewed directly. Nothing in the repository contains a frame; the video was never committed.

Everything below was measured at the source frame rate, one frame at a time, with local throw-away scripts and `tools/reference/extract_frames.py` /
`measure_reference.py`. All positions are canvas units (1080p / 4). Where a number comes from many samples the sample count is given. Times are
`t=` seconds in the video; "frame n" is the n-th 60 fps frame of the event.

| Area | Timestamps used |
|---|---|
| player's send, 53 flights | the whole sweep t=509-623 (`--mode reticle`); examples t=515.833-516.083, 526.683-526.933, 527.633-527.883, 528.483-528.733, 549.083-549.917 (rapid sends), 613.617-614.05 |
| bracket look and idle pulse | zooms at t=527.30 (pane 33), 527.97 (pane 5); size series t=526.9-527.64 and t=550.0-554.7; 28 landings |
| attacker lines | t=515.60-519.30 (two lines at once), 520.50-521.40, 518.30-518.50 (a sender KO'd), 519.13-519.30, 521.30-521.47; line fits per frame over t=509-523 |
| WATCH OUT! | whole match t=505-1073 (62 pill sessions), flashes at t=515.667, 517.630, 520.55, 522.233; zooms t=515.66-517.72; eye checks at t=505.5-509, 600-603, 745, 840, 870, 892, 905, 918, 960, 1010, 1060 |
| incoming bar | t=512-523 (blob tracks), 514.10-514.30 (a release), 515.10-515.30 (an entry), 517.7-518.95, 745-751, zone zooms at t=514.0 |
| KO card | t=526.30-527.40 (the pane at (377.25, 139.5)), t=518.30-518.50 (a second KO) |
| results | t=1070.0-1077.0 |

## 1. The player's send (changes `BattleSendStyle`, `BattleAttackGeometry`, `BattleAttackFlight`, `BattleAttackPresentation`)

| | |
|---|---|
| **Was** (7b78201, doc 52) | the bracket appeared at the window's middle, **held 0.18 s there**, then snapped onto the pane in the last 0.04 s of a 0.22 s flight; one flight per send, all of them landed; a 0.3 s "punch" on landing |
| **Reference** | in **53 of 53** flights with at least 8 frames in the window the bracket's first frame is at exactly **(240.0, 120.0)**; it then moves in a straight line at **constant speed** (worst frame-to-frame deviation from a flight's median step: 0.56 units, i.e. the measurement's resolution) and is at the recipient pane's **centre on the 15th frame: 15 frames = 0.25 s**. The flight of t=526.683 steps (12.5, 8.4) per frame to pane 33's centre (427.8, 246.5) and the one of t=515.833 (-10.3, -0.18) per frame to pane 8's centre (85.6, 117.3). The old persistent bracket is gone on the same frame the flying one appears (t=526.667 on pane 29, 526.683 in the window). Nothing else is drawn: no flash at the window, none at the pane, no ring, no punch. The box is 32.0 x 41.0 on frame 0, about 31.0 x 40.0 on landing and rests at 30.5 x 39.0. **A newer send cancels the older one in the air**: t=549.200 is frame 8 of a flight and t=549.217 is frame 0 of the next; t=549.650 / 549.667 likewise: there is only ever **one** bracket in flight and the cancelled one never lands |
| **Doc 52's reading** | its contact sheets (384 px tiles, 5 per row) showed the bracket "inside the game window for 9-12 frames" and then on the pane; that is the bracket *crossing the window* (x 240 -> 112 is 10 frames), not a dwell. Its "drift" was the motion. It is withdrawn |
| **Changed** | `BattleSendStyle.SECONDS = FRAMES / 60 = 0.25` (15 frames), `HOLD_SECONDS = 0`, `ease` is the identity; `START_INSET` / `REST_INSET` give the 32.0 x 41.0 -> 30.5 x 39.0 box (the pane inset 0.375 / 1.125 in x); `BattleAttackGeometry.send_rect` is the straight line to the pane's centre; `BattleAttackFlight.cancel` + `BattleAttackPresentation._on_sent` cancel an older in-air flight of the player's (it leaves `player_flights()` on the next read and never lands); no landing punch exists any more (`BattleTargetReticle.pulse`, `pulses`, `landed` are gone) |
| **Uncertain** | the exact frame at which the old bracket leaves relative to the SENT event of *our* session (the screen reads the event on its next frame, within one frame of the reference's); what the persistent bracket does when the target changes without a send (a mode choice, a KO): the reference's KO re-target steps through neighbours (doc 47), ours moves at once |

## 2. The bracket itself and its idle pulse (changes `BattleTargetReticle`)

| | |
|---|---|
| **Was** (doc 50) | four hairline corners 0.75 units thick, arms a quarter of the pane's width, **outside** the pane's edge in the gap (a 0.3 s punch) |
| **Reference** (zoom t=527.30, 527.97) | four **thick rounded L corners**, arms **11 units** long and **4.5** thick, the outer corner rounded with about the same radius, bright red (median (241, 0, 0), core (253, 0, 1)); the outer box is the pane **inset 1.125 x 1.25** (30.5 x 39.0 on the 32.75 x 41.5 pane): the bracket sits *inside* the pane and covers its picture's corners; the middle is open |
| **Idle pulse** | the box swells from 30.5 x 39.0 to **31.75 x 41.0** and back on a **59-frame (0.9833 s)** cycle: in the 40 s t=550.0-554.7 the peaks are at 550.658, 551.642, 552.625, 553.608, 554.592 (spacing 0.9833 s). Of the 28 landings whose first peak nothing interrupted, **20** peak 0.76-0.83 s after the bracket first overlaps its pane (median 0.81 s): the cycle starts at the landing. From it the box rests ~0.54 s, swells 0.25 s, falls 0.30 s and rests ~0.43 s |
| **Changed** | `BattleTargetReticle.corner_polygons` (rounded Ls), `ARM = 11`, `THICK = 4.5`, `RADIUS = 4.5`, `COLOR = (245, 0, 0)`; the persistent box is inset by `REST_INSET`; `BattleSendStyle.pulse(age)` is the cycle (`PULSE_PERIOD = 59/60`, rise from 0.54 s, peak 0.79 s, fall to 1.09 s); the reticle's `age` restarts when the bracket (re)appears (a landing or a move to another pane) |
| **Uncertain** | the pulse's exact shape (a smoothstep is used); whether the cycle is restarted by a target change that is not a send (here it is); the inner translucent rim seen in some zooms belongs to the pane highlight of an unrelated event, not to the bracket, and is not drawn |

## 3. The attacker lines (changes `BattleAttackPresentation`, `BattleAttackLayer`, `BattleAttackGeometry`, `BattleHudLayout`)

| | |
|---|---|
| **Was** (doc 51/53) | one line **per bot send at the player**: from the sender pane's centre to the bar's end on the sender's side, 0.55 s eased head + 0.3 s fade, 0.5 units thick |
| **Reference** | (a) the line **ends on the WATCH OUT! pill's outer edge, not in the bar**: right-panel senders to its right edge (290.75, 253.75), left-panel senders to its left edge (189.5, 253.75) (three lines measured: the slope from the pane centre to those points matches the fitted slope to the third digit). (b) It starts at the sender pane's **exact centre** (pane 23 (393.6, 117.3), pane 8 (85.6, 117.3), pane 5 (85.6, 74.3)). (c) It **grows**: the head moves along the line at constant speed, 170.9 units in **15 frames** (t=515.667 -> 515.917) for the first, 207 units in 15 frames for t=520.55 -> 520.8: the head speed is the pane-to-pill distance / 0.25 s. (d) After that it **stays**, uniformly, for as long as its sender **aims at the player**: line 1 lasted 515.667 -> 518.40 and ended on the very frame its sender (pane 23) was **knocked out** (starburst at t=518.367, line gone at 518.383); line 2 (pane 8) 518.30 -> 519.20, line 3 (pane 5) 520.55 -> 521.383. (e) Thin: 2.5 device px (0.65 units), red |
| **Interpretation** | doc 47's guess (Q8, "lines exactly while an enemy is on its way") and the build's "a line per send" are replaced by the relation the eye-counter inference already used: **a line exists while an opponent aims at the player** and goes the frame it stops (a re-target or a KO). The session already logs both as `TARGET_CHANGED`; the presentation reads them. A bot's send at the player is only an icon in the bar |
| **Changed** | `BattleAttackPresentation.lines()` / `_on_target_changed` (a bot whose target becomes the player gets a line; any other change, or `-1` for a KO, removes it; the player's own target and anything that happened before the presentation existed never make one); `BattleAttackLayer` draws `launch_point -> head_of(progress)` with `LINE_WIDTH = 0.65`; `BattleAttackGeometry.pill_point` (left edge for a pane left of the window's middle, right edge otherwise, `PILL_LINE_DROP = 5`); `BattleHudLayout.PILL = (189.5, 248.75, 101, 13)`; bot flights (`DURATION`, `LINGER`, the fade) are removed: `BattleAttackFlight` is the player's send only |
| **Uncertain** | the *initial* targets (silent, never a line): the reference shows no line in the first 2.4 s of the match, which is consistent with "no one aimed at the player yet", but with 34 random aims that is a 36 % chance, so it is one sample; why line 2 (pane 8) ended at 519.2 (a re-target, not a KO: pane 8 shows no card) and line 3 at 521.383 (a ghost enemy appears in that very pane that frame: a re-target together with a send) is read as "its target changed" |

## 4. WATCH OUT! (changes `BattleStatusStrip`; no eye counter)

| | |
|---|---|
| **Was** | a **red-filled** pill (x 185.5-289.5), shown from a bot's send until 1 s after its line landed, popping in; an eye and the attackers' count at the strip's left |
| **Reference** | the pill is **on exactly while at least one line is on screen** (62 pill sessions over the match; the first one, t=515.667-519.20, is exactly the union of two lines' lifetimes, 515.667-518.40 and 518.30-519.20) and goes **in one frame** with the last line. Look: outer x 189.5-290.5, y 248.75-261.75; from each end inward a crimson (225, 48, 55) stripe 3 units, an orange (255, 95, 0) stripe 3, a red (255, 0, 0) ring 2.5, then a **black** plate (x 198-282, y 250-260.5) with **yellow** (255, 248, 0) letters spanning x 202-278.5. The **"pulse"** doc 52 reported is a **white flash of the whole outline**: on its first frame the pill is solid white, then the white overlay falls linearly (fill value 255, 248, 210, 174, 138, 103, 62, 20, 0 on nine frames: alpha 1.0, 0.97, 0.82, 0.68, 0.54, 0.40, 0.24, 0.08, 0), over 8 frames; the same flash **repeats every 59 frames** (t=515.667, 516.65, 517.633, 518.617). There is no pop/scale |
| **Eye counter** | refuted: at t=905 **two** lines (two attackers) show **no eye**; at t=918 one line shows an eye and "1"; at t=600, 745, 870, 892 lines show none; over the whole match the eye is visible only in t=915-927, 951-1047, 1050-1068. It is not the attackers' count (it may be spectators). Nothing in the session drives it, so it is **not drawn** (`set_eye`, `eye` removed) |
| **Changed** | `BattleStatusStrip.set_pill(age)` (the presentation's `watch_out_age()`, -1 for off); `flash_alpha(age)` and `pill_layers(rect)` are the measured flash and layers; colours as measured; `BattleAttackPresentation.watch_out()` = "a line exists" |
| **Uncertain** | the letters' face (the project's bitmap font, bolded, is used; the reference's are chunkier rounded capitals); what the eye shows |

## 5. The incoming bar (changes `BattleIncomingStrip`)

| | |
|---|---|
| **Was** | pale zones (255,208,48 / 255,150,28 / 226,104,18) split at thirds with 3-tooth, 2-unit boundaries; 9 x 10 plates filled per phase (hollow while a line was in the air, brown, amber, red), outlines, pulses, flashes, a boundary flash, a gold-zone marker kept while the enemy lived and a fading green/grey ghost; icons eased in from the entry over 2.45 s after the line landed |
| **Reference** | zones are flat **(255, 189, 9) / (255, 118, 0) / (245, 85, 17)**; the boundaries are zig-zags of two teeth, 3.2 units deep, centred at x **202.6** and **288.0** (fractions 0.3545 and 0.6868 of the 257-unit bar). Icons are **bare sprites about 8 units wide, nothing round them**. They **enter at the bar's right end when the enemy is sent**, independently of any line (an icon entered at t=518.28, line 2 started at 518.30, and the pair that entered at t=515.15 / 515.38 had no line until 515.667), with a 2-3 frame grey ghost enemy over the bar's top edge (t=515.183-515.20), travel left at a **constant 47 units/s** (blob tracks: x0 = 356.8, 351.8, 347.2, 343.8, ... every 0.1 s, 4.6 units a step), keep one pitch (10.8) behind the one in front, and an icon that reaches the gold boundary **vanishes with no flash and leaves nothing** (t=514.183 on the boundary, 514.200 gone). A bare sprite means no per-phase colour, no outline pulse, no ghost |
| **Changed** | measured colours and boundaries (`GOLD_FRACTION`, `ORANGE_FRACTION`, `TOOTH_DEPTH`, `jagged`); `ICON_W = 8`, `PITCH = 10.8`, `ENTRY_INSET = 4.5`; an icon is `BattleEnemyIcon.draw` alone; it enters at the send (`landed_at = sent_at`), travels linearly from the entry to its place in the queue by the attack system's own `ACTIVATION_DELAY` (so it reaches the boundary as the attack becomes ACTIVE; speed `travel_speed` ≈ 50 units/s, the reference's 47), a queue closing up moves at `FOLLOW x speed`; an IN_LEVEL icon runs on across the boundary at 47 units/s and is not drawn (`crossed`); the hollow placeholder, the amber/red/brown plates, the boundary flash and the fading ghost are removed. **The M6b/doc 50 decision to keep a marker in the gold zone is reversed** (doc 53 §2.2): the reference has none |
| **Not reproduced** | (1) the bar's **global stops**: in t=512-523 every icon stands still together (512.0-513.8, 516.83-517.7, 519.4-520.7, 521.4-522.7) and moves together at 47 units/s otherwise; the icons' x is a function of an attack clock that pauses, and the cause is not derived from the frames (it is not the pill, not the lines). Ours is a function of the authoritative ages (a gameplay timing: `ACTIVATION_DELAY = 3`), so the icons never wait mid-bar. (2) the 2-3 frame entry ghost. (3) the entry spacing: five sends in one tick start on the same spot |
| **Uncertain** | the waiting place (boundary + 8): the reference's waiting icons were seen at x0 = 214, 228/239, 217/236 (they drift with the stops above), so the spot is ours |

## 6. The KO card (changes `BattleOpponentPane`)

| | |
|---|---|
| **Was** | a 0.8 s animation: first flash 0-0.07 s, the card popping in with an overshoot 0.07-0.5 s, a ring of six puffs and eight rays 0.1-0.6 s, a second flash 0.6-0.67 s; a card of dark blue / light edge / blue field |
| **Reference** (60 fps; t0 = 526.333, and t=518.367) | **0.95 s** from the first frame to rest. Frame 0 a **white rounded square** (11 units) at the pane's middle over the live picture; frame 1 it is 14.5 units and throws **eight yellow stars**; frame 2 the **whole blue card is there** (it does not pop in) under a **white burst** (radius ~12 -> 25) that has cleared by frame 6; the stars fly outward and leave the pane by about 0.3 s while **cream smoke puffs** build over the card (from frame 4), thicken to ~0.3 s, thin into **hollow rings** from 0.47 s and are gone at 0.58 s; a **second white rounded square** grows at the middle from 0.217 s (12 x 12 -> 18 x 26 over 4 frames) and fades pale green by 0.35 s; from 0.55 s a gold coin and a grey enemy icon cross the card (not drawn); a **third white square** flashes over the card's plate at 0.764-0.85 s (8 x 8 -> 17 x 24, fading to pale cyan); a pale rim round the plate fades 0.85-0.95 s. The settled card: a bright blue ring (3, 102, 193), a dark slate field (32, 78, 147), a light-blue plate (22, 137, 211) holding "KO" and, in a black-edged teal (0, 120, 152) block with four rivets, the placement; rectangles measured in design units |
| **Changed** | `KO_SECONDS = 0.95`; the pure timeline `square_side_at`, `burst_at`, `stars_at`, `puffs_at`, `flash_2_at`, `flash_3_at`, `glow_at`, `card_visible_at` replaces `flash_at` / `card_scale_at` / `puff_progress_at`; `_card_face` draws the measured card (`RING_RECT`, `FIELD_RECT`, `PLATE_RECT`, `BLOCK_*_RECT`) |
| **Uncertain** | the puffs' exact count and layout (nine circles in a cloud), the coin and the grey icon (not drawn), the first frame of the second sequence (t=518.367 starts at the star frame) |

## 7. The results screen's frozen field (changes `BattleScreen._freeze_field`, `BattleOpponentPane.settle_as_card`)

Doc 53 measured that the previews run a median 3.5 s (up to 5.5 s) behind the session, so a round that ends at an arbitrary moment froze about
three opponents (up to ten) **mid-death**. The reference's win (t=1070.0-1072.0) shows **every other pane already a settled card** before the white
flash of the results (t=1072.0): no pane is held mid-play. At `ROUND_OVER` a contestant who is out in the session but whose (lagging) picture had not
shown the KO now gets its **settled card** (no animation, its placement) at the freeze (doc 53 option A), after the single `refresh()`; the alive badge, the
frozen live pictures of the contestants still alive in the session, the freeze itself and everything it holds are unchanged. After a win all 34 panes are cards.

## 8. Rapid consecutive sends (section 1)

One bracket at a time; the older one is cancelled (t=549.2 -> 549.217, t=549.65 -> 549.667, t=613.783 -> 613.8). Doc 51's "each rapid send has its own bracket and all
land" is withdrawn. Our authoritative `target_of(0)` and every SENT event are untouched; the screen simply shows the newest send's flight and the persistent bracket
on the session's own target when it has landed.

## 9. Seen in the reference and not built

* **Ghost enemies in opponent panes**: grey translucent enemy sprites materialise at a recipient pane's top and drop in (t=515.667-515.84, 518.30, 521.38 on the sender pane): the bot -> bot send. Doc 51's "bot -> bot sends are not drawn" is not right; our previews already show an incoming enemy, but the grey ghost entry is not reproduced.
* **Non-KO pane flashes** (white rounded square fading to a pale ring, t=515.633-515.80 on one pane, t=518.35-518.48 on another): trigger unknown.
* The chest/coin box in strip B (it appears at t=506.0), the coin and ghost icon in the KO card.

## 10. Files

`BattleSendStyle`, `BattleAttackGeometry`, `BattleAttackFlight`, `BattleAttackPresentation`, `BattleAttackLayer`, `BattleTargetReticle`, `BattleStatusStrip`,
`BattleIncomingStrip`, `BattleOpponentPane`, `BattleHudLayout` (`PILL`), `BattleScreen` (wiring, the freeze); tests `battle_ui_test`, `battle_attack_view_test`,
`battle_attack_screen_test`, `battle_incoming_view_test`, `battle_arrival_game_test`, `battle_round_lifecycle_test`, and the GL suites `battle_attack_render_test`,
`battle_screen_render_test`, `battle_arrival_render_test`; `tests/tools/battle_ui_capture.gd` (shots for the new moments).

## 11. Tests

All run sequentially on the final code (`--fixed-fps 60`; GL under xvfb, `gl_compatibility`, 1920x1080, stand-in art), 0 failures, 0 script/parse errors.

Headless, 17 suites, 1710 checks: `battle_ui_test` 180, `battle_hud_test` 64, `battle_round_test` 69, `battle_round_lifecycle_test` 128 (new: nothing pending at ROUND_OVER; after a win all 34 other panes are settled cards), `battle_screen_test` 114, `battle_attack_screen_test` 125, `battle_attack_view_test` 123, `battle_session_test` 21, `battle_attack_test` 168, `battle_targeting_test` 120, `battle_incoming_plan_test` 95, `battle_incoming_view_test` 108 (new: the strip redraws every frame while an icon travels and rests when all are placed), `battle_incoming_game_test` 83, `battle_arrival_game_test` 110, `battle_attack_game_test` 81, `battle_preview_atlas_test` 44, `battle_preview_test` 77. The session, attack, targeting, incoming-plan, incoming-game, attack-game and preview suites were not edited: the authority is untouched.

GL, 5 suites, 177 checks: `battle_attack_render_test` 70, `battle_screen_render_test` 43, `battle_arrival_render_test` 28, `battle_incoming_render_test` 12, `battle_preview_render_test` 24.

The GL arrival test found one real defect in this pass's own strip: an icon that had caught up with a target that was itself still travelling was reported as "not moving", so the strip stopped redrawing and the icons sat at the right end on screen while the model had them mid-bar. `BattleIncomingStrip._follow` now counts an icon as moving until it has reached its place; the headless test above fails without that line.

The frame-by-frame analysis scripts (`/tmp` scratch: line fits, head tracking, bar tracking, pane features) are not committed; `tools/reference/extract_frames.py` and `measure_reference.py` are, and cover the same measurements (reticle, lines, bar, panes, single frames) from a local copy of the video. No video frame and no ROM-derived asset is in the repository.

## 12. Unchanged, verified

`BattleSession`, `BattleAttackSystem`, the targeting policies, the bots, spawn placement, the timer and coin code and the round rules are untouched: `battle_session_test`,
`battle_attack_test`, `battle_targeting_test`, `battle_incoming_plan_test`, `battle_incoming_game_test`, `battle_attack_game_test`, `battle_preview_test` pass without a single edit.
