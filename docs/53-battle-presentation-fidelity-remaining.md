# 53 — Battle: the remaining presentation-fidelity pass (audit of what the evidence supports, and what it does not)

Status: done on top of `7b782013` (doc 52). It is an **audit and evidence ledger with almost no code change**: after reading
docs 47, 50, 51 and 52 against the code, none of the remaining presentation areas has evidence strong enough to justify
moving a number, and the one place where the code differs from a reference observation (the retained gold-zone icon, doc 47
INCOMING-001) is a deliberate product decision that is not this pass's to reverse. Nothing about targeting, recipients, RNG, attack
qualification, send counts, the incoming queue, enemy spawning, bots, the timer or coin economy, course progression or SMB3
was touched.

> **Closed by [doc 54](54-battle-presentation-measured-from-video.md)**: with the video available the open items of sections 2 and 5 (M1-M6) were measured: the line's endpoint (the pill) and lifetime (while its sender aims at the player; it ends the frame the sender is KO'd), WATCH OUT!'s flash timing, the bar's motion and release (no marker), the KO card's 60 fps timeline, rapid sends (one bracket, the older cancelled) and the frozen results field (option A of section 2.6: settled cards at the freeze) are built or explicitly listed as not reproduced.
> Doc 55 later added the ghost of every enemy send (bot-to-bot included) and the previews' move to the next course.

## 0. Evidence available to this session

This session ran in a cloud container. **`reference.mp4` is not there, and the container's network policy refuses
`www.youtube.com` (403 from the egress proxy)**, so no frame was viewed and nothing was re-measured. The evidence is docs
47 / 50 / 51 / 52, the code, and one measurement of *our own* code (2.4, 2.6). The rule for this pass was "do not invent
precision": where the docs cannot give a value, the current behaviour stays and the gap is written down here with the exact
command that would close it (section 5).

## 1. Inherited from the measured pass (doc 52) — verified unchanged, not redone

Re-read in the code, not re-measured:

| Measured fact (doc 52) | Where it lives | State |
|---|---|---|
| player→opponent send: no continuous glide | `BattleSendStyle`, `BattleAttackFlight.eased()` | intact |
| bracket appears at the game-window centre | `BattleAttackGeometry.send_start` | intact |
| holds ~9–12 frames, then snaps in ≤1–2 frames | `HOLD_SECONDS = 0.18` of `SECONDS = 0.22` | intact |
| no enemy icon travels; authoritative recipient is the destination | `BattleTargetReticle.sync_flights`, `player_flights()` (`SENT.b`, never recomputed) | intact |
| ROUND_OVER / RESULTS field freeze (3cccc53) | `BattleScreen._freeze_field`, `BattlePreviewCell.freeze` | intact (`battle_round_lifecycle_test.test_results_field_frozen`) |

The measured send tests from `7b782013` (`battle_attack_view_test.test_flights_from_sends` / `test_flight_timing`,
`battle_attack_render_test.test_player_send`) pass unchanged.

## 2. Area ledger

| # | Area | Decision | Why |
|---|---|---|---|
| 1 | opponent → player attack line | **unchanged** | the endpoint is contradicted across observations; duration and growth are unmeasured (2.1) |
| 2 | incoming bar | **unchanged** | everything the docs state as Confirmed is built, except one deliberate difference (2.2) |
| 3 | WATCH OUT! pulse | **not implemented** | the *fact* of pulsing is reported, its rate/duty/amplitude are not (2.3) |
| 4 | KO card | **unchanged** | the timeline matches doc 47 within its sampling; one *systemic* gap found and measured (2.4) |
| 5 | rapid sends | **unchanged** | not re-measured by anyone; the architecture satisfies doc 47's ACCEPT (2.5) |
| 6 | results edge | **unchanged, but the premise was wrong — measured (2.6)** | a clean fix exists, but it reverses a documented choice |
| 7 | legacy effects | **verified absent**; one dead helper removed (2.7) | |

### 2.1 Opponent → player attack line

What the code draws (`BattleAttackLayer`, `BattleAttackGeometry`, `BattleAttackFlight`): one straight, solid red line
(255,25,25; reference r>225 g<50 b<70) of width 0.5 units = 2 device px at 1080p, from the **centre of the sender's pane**
to `bar_point` — the incoming bar's end on the sender's side, 6 units inside, at the bar's mid-height. The head moves out
over 0.55 s (`DURATION`, ease-out), the line holds 0.3 s more (`LINGER`) and fades. One line per bot→player send; nothing on
the sender's pane; no ring, shadow, tail or enemy.

| Question | Evidence | Verdict |
|---|---|---|
| thickness | doc 47: 1–2 device px, solid | **matches** (2 px at 1080p, the upper bound) |
| colour / opacity | doc 47: thin solid red | **matches**; the post-landing fade is doc 47's own TARGET ("plus a fade"), duration unmeasured |
| origin | doc 47/52: "from the sender's pane" | **matches** (centre; whether the reference leaves from the centre or an edge is unobserved) |
| pane response | doc 47: none; doc 52 looked at `attacker-517.6` and found none | **matches** (none) |
| per send, not persistent | doc 47: no line at t=760 while icons were in the bar | **matches** |
| endpoint | see below | **unresolved — kept** |
| duration, growth, linger | doc 47: "duration Unknown"; doc 51 §4: "whether it grows or appears whole" unresolved | **unresolved — kept** |
| relation to WATCH OUT! | doc 47: pill present at t=517.6 and t=1000 while a line was visible; doc 52: "coincident"; ours: pill from the send to 1 s after landing, so it outlasts the line by ~0.7 s | **consistent, not measurable** |

The endpoint is where the evidence disagrees with itself, so no exact point was chosen:

1. doc 47, t=517.6: "from a **right-panel** pane **into the bar near the queued Goombas**" (icons enter at the bar's right end);
2. doc 47, t=1000: "from L40 **to the WATCH OUT pill**" (the pill is in the strip below the bar, x 185–290);
3. doc 52 §2, zoomed `attacker-517.6`: "to the **left end** of the incoming bar";
4. doc 47 TARGET (a specification, not an observation): "the incoming bar's **right** end".

Our rule (bar's end on the sender's side) fits (3) for left-hand senders and (1)/(4) for right-hand senders, and fits (2)
for neither. (1) and (3) are about the same moment (t=517.6) and read differently ("near the queued Goombas" at the entry end
vs "the left end"). Choosing any one would be a guess. The tool already measures it (section 5, M1).

### 2.2 Incoming bar

Confirmed in doc 47 INCOMING-001, against the code (`BattleIncomingStrip`):

| Reference | Code | |
|---|---|---|
| player's icon at the left, current power state, on gold | `_player_icon`, `set_power` | matches |
| gold ≈ left third, orange, darker orange, **jagged** boundaries (~3 teeth) | `GOLD_FRACTION 1/3`, `ORANGE_FRACTION 2/3`, `TEETH 3` | matches |
| icons enter at the right end, move right → left | `entry_x`, `place_all` | matches |
| several icons at once, in send order | `place_all` (never crossing) | matches |
| icons wait at the boundary, sometimes seconds | ARRIVING waits at `boundary + WAIT_OFFSET` | matches |
| white flash at the boundary on release | `_boundary_flash` on `arrive` | matches |
| the icon **disappears** on release (doc 47 ACCEPT: "disappears on the frame `INCOMING_SPAWNED` is presented") | the icon crosses into the gold zone and **stays** as a marker while its enemy is in the level, then fades green/grey | **differs, on purpose** |
| crossing 4–6 s early, 3–4 s late (Strongly inferred) | 2.45 s after the line lands (`ACTIVATION_DELAY − 0.55`) | **differs, tied to gameplay** |

The retained gold-zone marker **still differs from SMB35**: the reference removes the icon at release, ours keeps it so
the player can see how many incoming enemies are still alive. It is a recorded product decision (doc 48, doc 50 §13), not a
bug, and flipping it changes what information the player has; it was not flipped. If Zack wants the reference behaviour
it is confined to `BattleIncomingStrip` (`place_all`'s gold branch, the `IN_LEVEL` case of `_icon`, the ghost path for
icons that had spawned) and does not touch any state.

The crossing time cannot be lengthened by a view: the icon's arrival at the boundary is the attack system's own activation
(`BattleAttackSystem.ACTIVATION_DELAY = 3`), and an icon cannot start travelling before its attack is sent. Doc 47
INCOMING-002 already says keep the pacing and treat `ACTIVATION_DELAY = 4` as a balance decision for Zack. Not touched.

Authoritative linkage is unchanged: one icon per sequence id, derived from the session's own ACTIVE/spawn state
(`phase_of`), `rows`/`counts` equal to the session's queue frame by frame.

### 2.3 WATCH OUT!

Reported by doc 52 (§2 "it blinks on/off rather than staying lit solid", §4 "a flashing WATCH OUT! pill") and by the
inspection behind this task. **Not implemented.** The reports say *that* it pulses; nothing says the rate, the duty cycle,
whether the whole pill or only the letters blink, or whether the blink is the whole life of the pill or only its start.
Building it would mean choosing all of those. A second reason for care: doc 47 saw the pill **absent** at t=760 with icons
in the bar; if the pill blinks, an absence in a sparse sample is weak evidence, and the *trigger* ("exactly while a
bot→player line is visible", Strongly inferred, Q8) is less certain than it looks. The pill stays solid for its existing
window (send → landing + 1 s, `BattleAttackPresentation.watch_out`), left for physical acceptance. The existing
`measure_reference.py --mode lines` already reports the pill per frame (`frames[].red_solids`, with its region), so one
command gives the on/off run lengths and answers the trigger question too (section 5, M2).

### 2.4 KO presentation

Doc 47 KO-001/002 (10 fps) against `BattleOpponentPane`:

| Reference | Code | |
|---|---|---|
| live picture continues, then white flash of the pane (1–2 frames) | first flash 0–0.07 s | within the measurement (PREVIEW-005: 1–2 frames at 30 fps = 0.03–0.07 s); solid vs fading profile unmeasured |
| blue card pops in with a starburst and white smoke over ~0.5–0.6 s | pop 0.07–0.5 s, puffs 0.1–0.6 s | matches |
| second white flash at ≈527.1 (≈0.7 s after the first at 526.4) | 0.6–0.67 s | within the ±0.1 s sampling |
| settled at ≈527.2 (≈0.8 s total) | `KO_SECONDS = 0.8` | matches |
| card: lighter inner border, "KO" on top, placement in a teal block with rivets | `_card_face` | matches |
| never moves, static afterwards, 33 cards in their original slots at t=1000 | no reordering; `settle()` | matches |
| overshoot / settle | doc 47 §14: "Pops overshoot (KO card, label enlargement)" | matches (ease-out-back; `battle_ui_test` asserts a peak between 1.02 and 1.4) |

No mismatch is supported strongly enough to move a number.

**A systemic gap, found and measured, not changed.** Doc 47 KO-005 / its timing table say the alive badge, the card (and the
KO credit) change **on the same frame** (t=163.100). In our build they cannot: the previews run `LAG = 2.0` s behind the
session and the card waits for the preview's death animation (`BattlePreviewCell.marked`), while the alive badge reads the
session at once (`BattleScreen._refresh_hud`). `tests/tools/battle_ko_lag.gd` (new, read-only) over 7 whole seeded matches
(182 KOs):

* the card appears **median 3.5 session-seconds after the session's KO** (min 1.25, p10 3.25, p90 3.5, max 5.5);
* at a given tick, on average **3.2 opponents (max 10)** are out in the session with no card yet; at least one at 1482 of
  1753 sampled ticks.

This is not a card-animation problem and it is not safe to patch from the badge side: `BattlePreviewDriver` states the
invariant that "everything the HUD shows from [the session] is never delayed", delaying the card's trigger would put a card on
a pane whose picture still shows a living Mario, and delaying the badge would make it disagree with the session and, at a
win, read 2/35 for a match the player has won (the last opponent's pane has not died yet). It belongs with the results
decision in 2.6.

### 2.5 Rapid sends

Untouched. Nobody has re-measured overlapping sends. The architecture (one independent flight per send, in send order,
each to its own authoritative recipient; a recipient eliminated in flight fades the flight instead of landing; a later mode
change moves only the persistent bracket) satisfies doc 47's ACCEPT ("two sends within 0.25 s … without leaving a stale
reticle"), and its tests (`battle_attack_view_test.test_simultaneous_sends`, `battle_attack_screen_test.test_send_flight_rules`) pass unchanged.

### 2.6 The results edge — premise corrected

The brief describes it as "an opponent who dies very near round end". The measurement says it is the **normal** case: with
a median 3.5 s (up to 5.5 s) between the session's KO and the card, a round that ends at an arbitrary moment freezes **about
three opponents on average (up to ten)** in a picture that is still running or mid-death although the session, the
results ranking and the alive badge already count them out. The frozen field is internally consistent only in the sense that
it is exactly what the player had been shown; the badge (session) and the number of non-card panes differ by that count.

Options, none taken:

| Option | What changes | Risk |
|---|---|---|
| **A. settle pending cards at the freeze** — in `_freeze_field`, panes whose contestant is out in the session but not yet `marked` get their settled card (no animation) | the ~3 mid-death panes become cards with their placements; badge == panes + player; at a win, 1/35 matches 34 cards | small and presentation-only (~12 lines, `BattleOpponentPane` + `_freeze_field`), but it **reverses doc 51's explicit "left as is, on purpose"** and changes the accepted frozen look |
| B. leave | nothing | the mid-death panes and the badge/panes difference stay |
| C. let the previews catch up before freezing | the driver keeps running ~3.5 s into ROUND_OVER | touches the lifecycle the accepted freeze fix rests on; rejected |

Nothing was changed: the instruction was to leave the accepted freeze alone unless the solution is clean, and A, though
clean, changes what an accepted state looks like and wants Zack's eye first. A is the recommendation if the mid-death
panes bother the physical review; the badge-vs-card gap in 2.4 would then be the next thing to decide.

### 2.7 Legacy effects

Scanned `BattleAttack*`, `BattleSendStyle`, `BattleTargetReticle`, `BattleIncomingStrip`, `BattleStatusStrip`,
`BattleOpponentPane`, `BattleScreen` for the gold send line, bot→bot lines, window-frame flash, target tint/outline,
enemy-head marker, launch ring, line shadow/tail and pane pips: no functional remnant. The layer draws one thing (the red
line), `drawn_flights` is bot→player only, the pips need the debug labels mode and never show on a card; the existing
absence tests (`battle_ui_test.test_attack_visuals_removed`, `battle_attack_screen_test`, `battle_attack_render_test`)
cover it. The one vestige was `BattleAttackFlight.age()` — uncalled, documented as "for the launch ring" — **removed**.

## 3. Files

* `Scripts/Classes/Battle/BattleAttackFlight.gd` — removed the uncalled `age()` (launch-ring vestige). No behaviour change.
* `tests/tools/battle_ko_lag.gd` (+ `.uid`) — new read-only development tool that prints the numbers in 2.4/2.6.
* `docs/53-battle-presentation-fidelity-remaining.md` — this document.

No test was added or loosened: no presentation behaviour changed.

## 4. Tests

Headless (`godot --headless --fixed-fps 60 --path . -s tests/<suite>.gd`, Godot 4.6, run one at a time) and GL
(`xvfb-run … --rendering-driver opengl3 --rendering-method gl_compatibility --resolution 1920x1080`, Mesa llvmpipe), on the
final tree, with no script or parse error in any log. The untouched `7b782013` tree was run first as the baseline and gave
the same totals.

| Headless | ok | | GL | ok |
|---|---|---|---|---|
| `battle_ui_test` | 148 | | `battle_screen_render_test` | 43 |
| `battle_hud_test` / `battle_round_test` | 64 / 69 | | `battle_attack_render_test` | 53 |
| `battle_round_lifecycle_test` | 126 | | `battle_incoming_render_test` | 12 |
| `battle_screen_test` / `battle_attack_screen_test` | 114 / 122 | | `battle_arrival_render_test` | 32 |
| `battle_attack_view_test` | 126 | | `battle_preview_render_test` | 24 |
| `battle_session_test` / `battle_attack_test` / `battle_targeting_test` | 21 / 168 / 120 | | | |
| `battle_incoming_plan_test` / `battle_incoming_view_test` | 95 / 107 | | | |
| `battle_incoming_game_test` / `battle_arrival_game_test` / `battle_attack_game_test` | 83 / 110 / 81 | | | |
| `battle_preview_atlas_test` / `battle_preview_test` | 44 / 77 | | | |

The measured-send tests from `7b782013` are in these runs unchanged (`battle_attack_view_test` 126 includes
`test_flights_from_sends` / `test_flight_timing`; `battle_attack_render_test` 53 includes the rewritten `test_player_send`).

**GL failures.** None here. The six that doc 52 reports on the Mac (preview halo-pixel count, an ACTIVE-flash icon sample,
a dim-icon sample, a 720p preview-cell bleed, two win-fade samples) did **not** reproduce under Mesa llvmpipe — all five GL
suites pass on the untouched baseline and on the final tree — so they could not be re-verified as pre-existing here; they
look driver/GPU-specific and doc 52's own stash check on that machine stands.

**One pre-existing flake in a headless suite.** In one chained run `battle_attack_game_test` failed three checks
("the mode and the reticle hold while the game runs", "a real stomp sends its enemy to that opponent, and the target stays",
"so does the next kill"). It is not caused by this pass and not by presentation code at all: the suite plays a **random**
match each run (`BattleHandler.new_seed` uses `randi()` unless a test sets `seed_source`), selects bot #15 as the
Lowest-Time target and asserts, one Battle second later, that it is still the target. In about 1.4 % of seeds (2.3 % by the
second tick) the bot simulation KOs that bot at tick 1, the policy re-targets, and those three checks fail. Proven, not
assumed: forcing such a seed (`2563011894`) makes the **original `7b782013` code** fail exactly the same three checks as
this tree, while 13 further unforced runs of this tree (the rerun plus 12 diagnostic copies) all pass 81/81. Left alone —
it is outside this pass — but the cure is one line in the suite (pin `BattleHandler.seed_source` as
`battle_round_lifecycle_test` does).

## 5. For the next pass with the video (Hermes / Zack): what to measure, and which constant it moves

All commands are `python3 tools/reference/measure_reference.py reference.mp4 … --out <file>.json` (derived numbers only).

| # | Question | Command | Moves |
|---|---|---|---|
| M1 | where the attacker line ends (bar left/right/middle, the pill, the window), how many frames it lasts, whether its length grows | `--mode lines --start 516.5 --end 519`; again `--start 999.5 --end 1002` | `BattleAttackGeometry.bar_point` / `BAR_INSET`, `BattleAttackFlight.DURATION`, `LINGER` |
| M2 | WATCH OUT! on/off run lengths and its life relative to the line; whether it also blinks with icons and no line | the same two runs (`frames[].red_solids`, region = status strip) plus `--start 746 --end 756` | new constants in `BattleStatusStrip` (none exist yet), `WATCH_OUT_HOLD` |
| M3 | bar: entry x, speed, release x, whether the icon vanishes at the boundary | `--mode bar --start 512 --end 523`; `--start 746 --end 756` | `BattleIncomingStrip` constants (speed is tied to `ACTIVATION_DELAY`: gameplay) |
| M4 | KO card at 60 fps: first flash length and profile, second flash start, settle | `--mode panes --start 526 --end 527.5` | `BattleOpponentPane.FLASH_1_END`, `FLASH_2_START`, `KO_SECONDS` |
| M5 | rapid sends: overlapping flights, one reticle or several | `--mode reticle --start 515 --end 530` (look for `flights[]` that overlap) | `BattleTargetReticle` |
| M6 | does the reference pane show the opponent's death before the card; is the alive badge on the flash's frame for ordinary KOs (not only the credit KO at 163.1) | `--mode panes` on a mid-match KO plus a crop of the ALIVE badge with `extract_frames.py --crop 376,0,31,44` | decides 2.4/2.6 |
