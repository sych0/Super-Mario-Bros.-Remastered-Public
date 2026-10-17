# 51 — Battle: the results field, and the SMB35 send presentation (what was built, measured, and left open)

Status: implemented on top of `fd25a92` (doc 50). It is a lifecycle + presentation milestone: no targeting, recipient, RNG, send count, queue, spawn, bot, timer, coin, round-outcome or progression rule was touched (section 9).

> **Superseded in part by [doc 54](54-battle-presentation-measured-from-video.md)**: the send is a constant-speed 15-frame flight from (240, 120) (not a 0.25 s ease), a newer send **cancels** the older one in the air (rapid sends do not all land), the attacker lines belong to the opponents that **aim** at the player and end on the WATCH OUT! pill (not on the bar), and there is no landing punch. Section 0's "unmeasured" values were measured in docs 52 and 54.

## 0. Read this first: what the reference video could and could not give

The brief asks for frame-level measurement of `reference.mp4`. **That file was not reachable from the session that wrote this.** This milestone ran in a cloud container; the path in the brief (`/Volumes/18tb/…`) is on Zack's Mac, and the video is (rightly) not in the repository. Nothing here was measured from the video, and nothing of it was seen, uploaded or guessed at. What was done instead:

1. **Doc 47's measurements were used for everything it records as Confirmed.** Its send-animation numbers (B35-TARGET-003) were taken from the video by the Opus pass at 10 fps: the flight lands 0.2–0.3 s after the bracket leaves its pane; it appears in the game window at the exact window centre (1080p 960,480) in 8 of 10 sampled sends and elsewhere in the others; no enemy rides it; bot→bot sends are not drawn; attacker lines are thin solid red into the incoming bar; the window frame does not flash.
2. **Zack's brief is read as the Q7 approval** doc 47 asked for ("Do not assume our existing gold-line behavior is conceptually correct… remove anything that duplicates or conflicts"): the gold send line, the bot→bot lines, the frame flash, the target tint and the pane pips are removed, and the reticle flight replaces the gold line.
3. **Every value doc 47 does not give is isolated in one file** — `Scripts/Classes/Battle/BattleSendStyle.gd` — each marked UNMEASURED with the plain default used, so applying a measurement is an edit of that file only.
4. **A local measurement tool was written and tested**: `tools/reference/measure_reference.py` (README beside it). It decodes the video through a local ffmpeg pipe and prints **derived numbers only** (times, boxes, durations, speeds, easing fits); it never saves or shows a frame and has no network code. It was tested here on a synthetic clip (it recovered a known 8-frame ease-out flight, its start at the window centre, its 0.3 s leave-to-land and a thin diagonal line's end points and thickness). Zack can run it on the real video and paste the JSON back; section 11 lists the clips.

So the answers to "what exactly does SMB35 do" below are labelled **doc 47** (video-derived, not re-measured), **ours** (a stated default) or **unresolved**.

### 0.1 Follow-up: the video became public, and the cloud container still could not reach it

The reference video is public (`https://www.youtube.com/watch?v=AUcFTEfFp58`), and for **that video only** the "no frame may enter model context" rule is lifted (frames and short contact sheets may be viewed; the video itself is never committed or redistributed; nothing changes for any ROM or ROM-derived asset). The session that was asked to re-inspect the send at the listed timestamps ran in the same kind of cloud container, and **that container's network policy refuses `www.youtube.com` (and `youtu.be`, `*.googlevideo.com`, `i.ytimg.com`)**: `yt-dlp` installs, but its first request is a 403 from the egress proxy (`connect_rejected`). There is no local copy of the video in the container either. So **no frame was viewed, nothing in section 3's "ours" column was re-checked, and no value in `BattleSendStyle` was changed** — a guess corrected by another guess would only make the doc dishonest. The corrections wait for one of: the host allowed in the environment's network settings (`www.youtube.com` plus `*.googlevideo.com` for the stream), or Zack running `tools/reference/extract_frames.py` on the local copy and attaching the sheets it writes (it makes labelled contact sheets for exactly the windows listed in section 11; frames stay outside the repository).

## 1. Part A — the results panes

**Symptom (Zack):** opponent panes look right while playing, and go wrong on entering ROUND_OVER / RESULTS: cream, blank-looking cells with isolated sprites.

**Root cause.** The results are a *fast-forward*: `BattleScreen._show_results()` calls `BattleSession.resolve_to_end()`, which plays the rest of the match out in one go so the card can show a complete ranking. The panes, the preview driver and the HUD kept following the session during that call. Reproduced headlessly: at the player's death, tick 20, 13 opponents out, 22 alive; one frame into RESULTS, tick 133–201, 33 out, 1 alive — every preview track had been pushed through the whole remaining match at once (their run-over / fade / empty frames, the leftover incoming-enemy sprites), 20 more KO cards queued up, the alive badge read 1/35. Nothing was broken in the previews themselves; they were told to show a future that nobody had watched.

**Fix.** The match field is *held* from the moment the round ends. `BattleScreen._begin_round_over()` → `_freeze_field()`:

* one last read of the session (so the player's own KO and the latest cards are in);
* `field_frozen = true`: `refresh()` no longer touches cells, panes, badges, HUD or the reticle, and `_process` no longer calls `BattlePreviewDriver.update`;
* every cell takes a private copy of the contestant it last drew (`BattlePreviewCell.freeze()`, `BattleContestant.copy()`), so any later redraw still draws the same picture;
* a KO card that was popping in is settled (`BattleOpponentPane.settle()`; the screen's clock is 0 while the tree is paused for the death);
* the reticle, any send or red line in the air, and WATCH OUT! are cleared.

The results card, the central window's dimming and the incoming bar are independent of that (the bar still clears when the round ends, as before). `_start_next_round()` releases the field; the new session gets its own driver, cells and presentation. **No fake results preview is built**: the panes keep the last valid rendered state (a picture is never replaced by the placeholder).

Verified on the real game (`battle_round_lifecycle_test.test_results_field_frozen`): after 14 s of play (some opponents out), the death, and 90 frames in RESULTS, a hash of all 34 preview frames, the set and the placements of the KO cards, the pane positions, the alive badge and the timer are identical to the moment of ROUND_OVER; all 34 cells are still live and valid; no KO animation is running; the session meanwhile advanced (tick 20 → 100+, 1 alive); the next round shows no card, "35/35" and new pictures. A GL capture of the results screen shows a normal frozen field under the dimmed window.

Left as is, on purpose: an opponent whose KO happened in the last ~2 s before the round ended (the previews trail the session by 2 s) is frozen in its death animation: the card it would have shown was never visible to the player.

## 2. Doc 47 requirements addressed

| Id | What | Result |
|---|---|---|
| B35-TARGET-003 | the send is the reticle flying from the game window to the recipient | built (section 3); timing 0.25 s; curve / split / size unmeasured |
| B35-TARGET-002 | the reticle on the target pane | unchanged (doc 50); a re-target is now a plain move, a landing and a mode choice punch |
| B35-ATTACK-002 | bot→bot sends are not drawn | removed: no flight, no line, no mark is made for them |
| B35-INCOMING-004 | thin red lines from the sender's pane to the bar; no frame flash | the line is plain, solid, 0.5 units (2 device px at 1080p); the frame flash is gone |
| B35-UI-002 / ATTACK-002 | no incoming marker on a pane | the pips are drawn only in the debug labels mode (F3) |
| B35-INCOMING-005 | WATCH OUT! | unchanged (1 s after a bot's line lands) |
| B35-INCOMING-001 | the incoming bar | unchanged since doc 50; unmeasured details listed in section 8 |

Not touched: ATTACK-003 / Q15 (R0 stands), the pale tint (Q13), the timer and coin economies, the selector's controls.

## 3. The send, as built (player → opponent)

| Moment | What is drawn | Basis |
|---|---|---|
| before the kill | the persistent four-corner bracket on the current target pane (thickness 0.75, outset 0.5, arms ¼ pane, r>225 g<50 b<70) | doc 47 TARGET-002 (doc 50) |
| the frame the defeat sends (the session's `SENT` event is presented) | the bracket is no longer on its pane; a bracket of the pane's own size appears **centred on the game window's middle (240, 120)** | doc 47: exact window centre in 8 of 10 samples. The other two ((722,385), (1254,534) at 1080p) lie on straight lines from the centre towards a pane, i.e. consistent with mid-flight samples; "the defeated enemy's position" (doc 47's guess) is *unresolved* and not built |
| flight | straight line, centre to the recipient pane's centre, **0.25 s**, ease-out (fast leave, soft landing); the bracket keeps the pane's size; no line behind it, no enemy on it, no tint on the pane, no window flash | duration: doc 47 (0.2–0.3 s from leaving the old pane to landing); easing, split between a hold and the move, and the size in flight: **ours / unmeasured** (`BattleSendStyle`) |
| landing | the bracket is on the recipient pane; the pane punches for 0.3 s (the bracket starts 2 units wide and a soft red halo fades); then the persistent bracket is there | the arrival emphasis is **ours / unmeasured** |
| which pane | the **authoritative recipient** of that attack: `SENT.b`, stored in the flight when the event is presented. It is never recomputed | the brief |

* **Changing the targeting mode in flight** moves the persistent bracket (the session's own target) and never the flight: it lands on the recipient it left for (tested, Random → Lowest Time mid-flight with a different lowest-time opponent).
* **Rapid sends:** every send has its own bracket, in send order, each to its own recipient; each lands and punches; one persistent bracket is left, on the last recipient. The reference's behaviour (one reticle that is re-sent from the window, or several) is **unresolved**.
* **The recipient is eliminated in flight:** the flight is cut (it fades in 0.12 s where it is), never lands on a KO'd pane, no punch; the persistent bracket goes to the session's new target.
* **Pause:** the flight follows the presentation clock, which stands still with the game (tested).
* **The round ends:** the field freeze clears every flight (tested).
* The retarget "sweep" doc 47 notes after a KO (t=163.60 R10 → 163.63 R11 → 163.70 R12, a pane every ~2 frames) is not animated: our re-target is one step to the final pane.

## 4. Part C — opponent → player

A bot's send at the real player: **one thin solid red line** (0.5 units wide = 2 device px at 1080p; doc 47: 1–2 device px) from the middle of the **sender's own pane** to a point 6 units inside the incoming bar, at the bar's end on the sender's side. Its head moves out over 0.55 s (the existing authoritative delay before the incoming icon enters, so the bar's icon and the line stay in step), it stays 0.3 s, then fades. No enemy rides it, no ring, no shadow, no tail, no sender-pane emphasis. WATCH OUT! appears with it and stays 1 s after it lands (unchanged). **Unresolved:** whether the reference's line is drawn once per send or persists while that bot targets the player (doc 47: no line at t=760 with icons in the bar); its duration; whether it grows or appears whole; whether the sender's pane reacts.

## 5. Part D — bot → bot

Doc 47 B35-ATTACK-002: "no line or effect between two opponent panes was seen in any sampled frame" (strongly inferred, absence of evidence across many frames). Removed. `BattleAttackPresentation` no longer creates a flight for such a send (it still records and counts it; the previews still show the incoming enemy in the recipient's picture). `battle_ui_test`, `battle_attack_screen_test` and the GL test assert nothing is drawn, across the playfield or between panes.

## 6. Part F — old effects removed

| Old effect | Now |
|---|---|
| gold send line with a white core and an enemy riding its head (player's send) | **gone**: the reticle flies |
| launch ring, line tail gradient, dark shadow line, enemy head on any line | **gone** |
| bot→bot white lines (¼ strength across the window) | **gone** (no flight is made) |
| yellow tint and pulsing outline on a target pane while a line is in the air | **gone** (`marked_ids`, `target_strength` removed from the presentation) |
| red flash of the game window's frame when attacks land on it | **gone** |
| queued / active pips in the pane corner | drawn only in the debug labels mode (F3, `--battle-labels`, `SMB1R_BATTLE_LABELS=1`), and never on a KO card; the counts themselves remain (tested against the session) |
| reticle punch on *every* re-target | a punch now follows a landing and a mode choice only |
| `BattleAttackGeometry.inside_span`, window launch / landing inset constants | removed (the only user was the bot→bot line across the window) |

`BattleAttackLayer` now draws exactly one thing; its pure `drawn_flights(view)` lets tests state what that is.

## 7. Files

New: `BattleSendStyle.gd` (the send's tunables), `tools/reference/measure_reference.py`, `tools/reference/README.md`. Changed: `BattleScreen` (field freeze, reticle flights wiring), `BattleTargetReticle` (flights, per-pane punches, `clear`), `BattleAttackFlight` (per-kind duration and linger), `BattleAttackPresentation` (no bot→bot flights, `player_flights`, `player_sending`, marks removed), `BattleAttackGeometry` (`send_start`, `send_rect`; window-line geometry removed), `BattleAttackLayer` (red lines only), `BattleOpponentPane` (`settle`, `draws_pips`), `BattlePreviewCell` (`freeze`), `BattleContestant` (`copy`), `.gitignore` (the video, `*.mp4`, the tool's work folders).

## 8. Part E — the incoming bar

Unchanged since doc 50 (zones, jagged boundaries, travel from the right end to the gold boundary in `ACTIVATION_DELAY − line time`, release flash, in-level markers). No authoritative or spawn timing was changed. **Unmeasured, to be read with `--mode bar`:** the real entry x and travel speed, how long an icon waits at the boundary, whether and how it disappears on release (we keep an in-level marker), the boundary flash, any tint after release.

## 9. Gameplay unchanged

`BattleSession`, `BattleAttackSystem`, the policies, bots, M6a spawns, the timer and coin code are not modified; `battle_session_test` 21, `battle_attack_test` 168, `battle_targeting_test` 120, `battle_incoming_plan_test` 95, `battle_attack_game_test` 81 pass unchanged; `battle_attack_view_test` still proves a session read by a presentation is identical, tick by tick, to the same session without one. The recipient shown is the SENT event's; the screen never asks a policy anything.

## 10. Tests

**All 17 headless suites and all 5 GL suites pass, with no script error or parse error in any log.**

| Headless | ok | | GL (xvfb, opengl3) | ok |
|---|---|---|---|---|
| `battle_ui_test` | 148 | | `battle_screen_render_test` | 43 |
| `battle_round_lifecycle_test` | 126 | | `battle_attack_render_test` | 52 |
| `battle_attack_screen_test` | 122 | | `battle_incoming_render_test` | 12 |
| `battle_attack_view_test` | 123 | | `battle_arrival_render_test` | 32 |
| `battle_screen_test` / `battle_hud_test` / `battle_round_test` | 114 / 64 / 69 | | `battle_preview_render_test` | 24 |
| `battle_session_test` / `battle_attack_test` / `battle_targeting_test` | 21 / 168 / 120 | | | |
| `battle_incoming_plan_test` / `battle_incoming_view_test` | 95 / 107 | | | |
| `battle_incoming_game_test` / `battle_arrival_game_test` / `battle_attack_game_test` | 83 / 110 / 81 | | | |
| `battle_preview_atlas_test` / `battle_preview_test` | 44 / 77 | | | |

Suites that encoded the old effects were rewritten to the new ones, not loosened: the gold-line, marked-pane, bot→bot-line and frame-flash assertions became assertions that those things are absent; the pips became "no pip"; the reticle samples wait out the 0.3 s punch and treat a neighbouring pane's corner (which shares the gap with the target's bracket) correctly.

New or rewritten checks: the whole results field held across ROUND_OVER → RESULTS → next round (real game); the reticle's pure behaviour (set_target does not punch, flights hide the persistent bracket, a landing punches once, a cut flight never lands, `clear`); flight geometry (`send_rect` starts centred on the window and ends exactly on the pane for all 34 panes, straight, same size); flight timing and easing (monotone, 0.25 s, gone the moment it lands, no linger); the authoritative recipient and endpoint on the real screen; a mode change in flight does not redirect it; two rapid sends keep identity and order and both land; a recipient KO'd in flight is safe; pause freezes a flight; the round end leaves nothing in the air; a bot's send at the player starts in the sender's own pane; a bot→bot send draws nothing (headless, and GL pixel samples along the path and in the target pane); the old effects' methods and the pips do not exist or do not draw; GL: the bracket is drawn where the flight says, no gold trail, no tint, no frame flash, one bracket left on the session's target.

## 11. For Zack: what to compare, and what to measure (timestamps are doc 47's)

Compare by eye in the reference video (`python3 tools/reference/extract_frames.py reference.mp4 --preset all` writes labelled sheets for every window below):

* **Sends** (leave → land): 515.8 → 516.1 (L22), 526.7 → 526.9 (R51), 527.6 → 527.9 (L12), 528.5 → 528.7 (L52); the bracket at the window centre at t = 515.8, 527.6, 536.7, 537.6, 548.7, 561.9, 607.7, 618.7; the off-centre samples are in the same 509–623 range.
* **Re-target sweep after a KO:** 163.60 – 163.70 (R10 → R11 → R12).
* **Attacker lines and WATCH OUT!:** 517.6 (a right-panel pane into the bar), 1000 (L40 → the pill), 760 (icons, no line).
* **Incoming bar:** 512–523 (two Goombas, 4–6 s), 746–754 (four or more icons, 3–4 s).
* **KO flash and card:** 524.4–527.3 (one pane, 0.8 s).

Measure locally (derived numbers only), then paste the JSON into the next pass:

```
python3 tools/reference/measure_reference.py reference.mp4 --start 514.5 --end 530 --mode reticle --out /tmp/sends.json
python3 tools/reference/measure_reference.py reference.mp4 --start 516.5 --end 519 --mode lines --out /tmp/lines.json
python3 tools/reference/measure_reference.py reference.mp4 --start 746 --end 756 --mode bar --out /tmp/bar.json
python3 tools/reference/measure_reference.py reference.mp4 --start 514.5 --end 530 --mode frame --out /tmp/frame.json
python3 tools/reference/measure_reference.py reference.mp4 --start 524 --end 528 --mode panes --out /tmp/panes.json
```

| Question (unresolved here) | Constant / code it changes | Tool output that answers it |
|---|---|---|
| Is the origin the window centre, or the defeated enemy? | `BattleAttackGeometry.send_start` (+ a hand-off from `Enemy.report_battle_defeat`) | `flights[].start_to_window_center_units`, `first_air` positions |
| Flight length and the hold before it moves | `BattleSendStyle.SECONDS`, `HOLD_SECONDS` | `air_frames`, `leave_to_land_s`, `dwell_air_frames_at_start` |
| Easing | `BattleSendStyle.ease` | `easing_fit` |
| Bracket size in flight | `BattleSendStyle.START_SCALE` | `size_first_last` vs `size_end_pane` |
| Path (straight or curved) | `BattleAttackGeometry.send_rect` | `straight_path_max_deviation_units` |
| Is the bracket absent for any frame between the panes? | the hand-over in `BattleScreen` | `air_frames_without_bracket` |
| Arrival emphasis (length, look) | `BattleSendStyle.LANDING_PUNCH_SECONDS`, `BattleTargetReticle._draw` | `panes` / `reticle` frames after landing |
| Does a send flash the window frame? | (already off) | `--mode frame` changes |
| Rapid sends: one reticle or several | `BattleTargetReticle` | two flights overlapping in `flights[]` |
| Attacker line: persistent or per send; duration; growth | `BattleAttackFlight.DURATION/LINGER`, `BattleAttackLayer` | `--mode lines` per-frame lines |
| Incoming bar entry, speed, release | `BattleIncomingStrip` constants | `--mode bar` `icon_tracks` |

Confidence: Part A — verified (reproduced, fixed, tested on the real game). Removal of bot→bot lines, the frame flash and the gold line — doc 47 (strongly inferred / confirmed), plus Zack's brief. The flight's duration and its window-centre origin — doc 47 (confirmed timing; start anchor strongly inferred). Everything else about the flight's look — **unresolved, one file to change**.
