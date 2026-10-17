# 55 — Opponent previews: moving on to the next course, and the ghosts of enemy sends (measured on the reference video)

Status: implemented on top of `0e26756` (doc 54). Presentation only: no targeting, recipient, RNG, attack qualification, send count, queue, spawn,
bot, timer, coin, round-outcome or course-progression rule of the session was touched (section 8). It answers two things Zack found in physical
testing: (A) opponent panes that clear World 1-1 got stuck in a blank, half-drawn state; (B) the enemy / character animation of a send into another
opponent's window, which doc 54 listed as seen and not built.

## 0. Evidence and method

The reference is the public SMB35 video (`https://www.youtube.com/watch?v=AUcFTEfFp58`, 1920x1080, 60 fps, 1115.8 s), read from the private mirror
`sych0/reference-video` (`reference.mp4`, Git LFS; SHA-256 matches its pointer). Under the policy in `tools/reference/README.md` frames were viewed
directly; no frame and no video is in the repository. Positions are canvas units (1080p / 4), `t=` is seconds in the video.

How: the 568 s of the match (t=505-1073) were scanned at 15 fps for every pane (white flashes, black, sky, KO-card blue); the 41 sends of the real
player that `measure_reference.py --mode reticle` finds (t=509-619; 40 of them have a flash on their recipient) were followed to their recipient panes at 60 fps; the events below were then
read frame by frame, with per-frame pixel measurements on the pane (`extract_frames.py` sheets; the new `measure_reference.py --mode fade` reproduces the ramp
(`--start 657.2 --end 657.6`: 0.027 / 0.158 / 0.301 / 0.521 / 1 / 1) and `--mode ghosts` the ghost tracks and burst frames; the rest of the analysis
scripts were local and are not committed).

| Question | Timestamps used |
|---|---|
| course transitions, 60 fps | pane 34 t=609.5-611.1 (flagpole, fade, cut; sheet at 610.40-610.90); pane 2 t=627.9-629.3; pane 4 t=656.40-657.60 (60 fps 657.20-657.60); fade ramps measured per frame on all three; the sky-to-black scan also lists t=659.1 (pane 12), 672.7 (31), 674.7 (13), 714.7 (14), 718.1 (25) |
| what a pane looks like in the new level | pane 34 t=610.883-611.1 (underground, Mario drops in); pane 2 t=628.900-629.233; pane 4 t=657.433-657.583 |
| send ghosts, the real player's sends | 41 sends t=509.017-618.733 (list in section 5); close reads: send 526.683 -> pane 33 (frames 526.70-528.30, 527.172-527.339 at 60 fps); 527.633 -> pane 5 (528.00-528.60); 528.483 -> pane 17 (528.85-529.45); 609.217 -> pane 2; the player's own window at t=526.55-526.717 |
| send ghosts, bot to bot | pane 20 -> pane 23, t=515.50-516.20 (centroid tracks, both panes); the right panel to pane 4, t=655.85-656.45 (a scan of all 34 panes); pane 4 again at 656.60-656.77 |
| the burst (flash) | pane 33 t=527.172-527.339 per frame (sizes, colours); 40 first-flash frames |

## 1. The post-1-1 limbo: root cause

A preview was ONE track on ONE course. `BattlePreviewDriver.LIVE_COURSE` was 0 ("only the first course has a live preview; every other course
uses the placeholder"), and a `BattlePreviewTrack` that cleared World 1-1 walked to the castle, faded to black (0.6 s) and went `DONE` with its frame
marked invalid. A cell whose frame is invalid draws `BattlePlaceholderRenderer`: a flat purple-blue sky, two hill triangles scrolled by the session's
`progress`, a brick strip and a Mario-sized rectangle. For the rest of the match that pane looked like a blank, half-drawn level that never became
anything else (and `world_level_text` said "1-2" while the picture said nothing).

**Was progression missing or broken?** Missing, on the preview side only. The session already progressed correctly (`LEVEL_CLEAR` events,
`levels_cleared`, `progress` restarting at 0 for the next course); nothing in the preview layer knew a second course existed: a track had a single
sketch and a single art set for its whole life, no way to load another, and `DONE` was its last state. The renderer (`BattleMiniGameRenderer`) was
generic: it draws whatever the frame carries.

Not the cause: the level sketch builder itself (it reads any level scene it can, section 3), the bots, the attack loop.

## 2. How SMB35 shows an opponent clearing a course (measured, 60 fps)

Three clears read frame by frame (pane 34 at t=610.8, pane 2 at 628.8, pane 4 at 657.3) agree to the frame:

1. Mario slides down the flagpole (the pane's camera follows him down) and stands at its foot. **No castle walk, no score card, no door**: the pane
   never shows a castle.
2. After a hold of **0.23-0.30 s** at the pole's foot (measured 0.23-0.28 on pane 34, 0.20-0.27 on pane 4, 0.30 on pane 2) the pane **darkens over
   six 60 fps frames**. Black fraction of the sky (the picture's own blue channel against its pre-fade value) on consecutive frames:
   pane 4 t=657.333/.350/.367/.383/.400/.417 = 0.027 / 0.158 / 0.301 / 0.521 / 1 / 1;
   pane 34 t=610.783...610.867 = 0.041 / 0.162 / 0.295 / 0.518 / 1 / 1;
   pane 2 t=628.817...628.900 = 0.034 / 0.156 / 0.294 / 0.520 / 1 / 1. The pane's small HUD is not darkened.
3. The **next frame is the new course**: a hard cut, no fade in (pane 4: black 657.400 and 657.417, the new level on 657.433; the new level's
   own first frames are dark only because it is an underground level). Total dark: 0.1 s. Mario shows up in the new level 1-4 frames after the cut
   (dropping in from the top of the underground level).
4. There is **no transition card, wipe or flash tied to the clear**. The white rounded squares seen around the same moments (610.633-610.8 on pane
   34, 628.967-629.15 on pane 2, 656.4 and 656.87 on pane 4) are the arrival bursts of enemy sends (section 4) and not a level-clear effect; they
   happen with or without a clear.
5. The camera is reset by the cut (the new level starts from its beginning). Panes are on different courses: at t=700 the left panel shows an
   overworld, a castle, a warp-zone room, two underground levels; the course label belongs to the real player only.

Confidence: high for 1-3 (three clears, identical ramps); medium for the hold (a range, 0.23-0.30 s); the slide itself (its length and the
camera that follows it) is not reproduced: our previews keep a fixed ground-anchored view.

## 3. The fix

`BattlePreviewStages` (new): the level sketch and the baked art behind each course, built on first use and prefetched when a bot is half way through
its course (`PREFETCH_PROGRESS`), so no frame is spent baking at the clear. A course the previews can walk is shown as itself; any other course is
shown by a **stand-in**: the next level of a fixed cycle after the one the preview has just left, never the level the next course will show as
itself (`geometry_for`, pure and tested), so a clear always looks like a different level. The label (`displayed_course`) is always the real course.

**Which levels can be walked.** The sketch builder reads 18 of the 32 courses (the others have no flagpole or are inherited scenes), and the walk
planner (`BattleLevelSketch._plan_jumps`, written and tuned for 1-1) does not yet cross the others cleanly. The walk audit
(`tests/battle_preview_course_test.gd`, three seeds x small and big Mario per level, progress rising evenly) found:

| Course | Level | Audit |
|---|---|---|
| 0, 9, 12, 17, 24 | 1-1, 3-2, 4-1, 5-2, 7-1 | clean: no frame inside terrain, none on foot over a pit, flagpole reached, fade reached |
| 8, 16, 28, 29 | 3-1, 5-1, 8-1, 8-2 | 1-41 frames on foot over a pit or in terrain per walk |
| 4, 20, 21 | 2-1, 6-1, 6-2 | 65-120 frames inside terrain (a wall or pipe the plan walks through) |
| 2, 6, 10, 14, 22, 30 | the X-3 treetop levels | the plan has one jump: Mario walks over the gaps and never reaches the pole |
| the other 12 | X-2 underground / underwater, X-4 castles, 5-3, 6-4, 7-2, 7-3, 8-4 | no sketch (no flagpole, or an inherited scene) |

Only the clean five are listed in `BattlePreviewStages.SKETCHED`; the test fails if a listed level does not pass the audit, and a listed level whose
sketch or art fails to build at run time is dropped and the choice made again. Giving the planner the treetop levels and the castles is the follow-up
that would let the cycle show the real levels (the reference's panes are on 1-2, 1-3, 1-4... during a match); it is not in this pass.

`BattlePreviewTrack`: after the flagpole slide the track holds `FLAG_HOLD` (0.27 s), then `FADE` (three 30 Hz steps, 10 / 41 / 100 % black: the means of
the pairs of measured 60 fps frames), then `enter_course()`: the same frame object (a cell stays bound) now carries the next course's level and art; Mario
is at its start, the camera at its left, with no enemy, jump plan, flag, fade, freeze or blink of the last level. What the session already said about the
opponent is kept: a HIT or KO still to be shown (planned again on the new level) and the attacks that are still ACTIVE (their enemies are on the new
course too). `LEVEL_CLEAR` events are kept per course, so two clears close together are shown one after the other. The growth at the castle is gone: the
power the clear gave goes straight into the next course. Falling beside a wall no longer walks into it (a one-frame overlap the new levels exposed).
The end of the LAST course (and a track with no stages) still ends dark and hands back to the placeholder.

`BattlePreviewDriver`: each opponent starts on its own `levels_cleared` course, prefetches, and `settle()`s on the results freeze: a pane caught in
the 0.1 s of darkness is put on the next course, never held black. `BattleScreen._freeze_field` calls it. Pane order, the KO card and the results
freeze are otherwise unchanged.

## 4. The send ghost (what the reference shows when an enemy is sent)

**Every send at an opponent is a ghost of the sent enemy** (a Goomba's, a Koopa's) **flying in a straight line, at constant speed, from the middle of
the sender (the sender's pane; the game window for the real player) to the middle of the recipient's pane in 30 frames (0.5 s)**, and **bursting
into a white rounded square there**. This is the same for the real player's sends and for a bot's sends at another bot. A send at the real player has
no ghost on any pane (its picture is the red line and the bar's icon).

* **Is a ghost visible in the destination pane?** Yes, for the last 2-3 frames on average (median 2, the real player's sends; the far panes are
  7.5 units a frame, the adjacent ones 1.4), coming in from the side that faces the sender: from the right edge for a pane of the left panel, the left
  edge for the right panel, from above or below for panes above or below the window's line. In 9 of 40 close reads it shows 4-9 frames (a second
  ghost of a bot's send crossing the same pane).
* **Does it drop in?** It is not a drop. It is a straight line from the sender; it only reads as a drop when the sender is the pane above (pane 20 ->
  pane 23: it enters at the top and moves down at 1.43 units a frame). Ghosts also appear in the SENDER's pane (at its middle, full size, on the send
  frame) and in every pane on the way (a ghost crossed panes 25, 24 and 23 of the right panel at 13.9 units a frame on its way to pane 4 of the left
  panel, t=655.95-656.43). It is never drawn over the game window or the gaps between panes.
* **Grey / desaturated?** Translucent grey-teal, white where the sprite is light: a Goomba's head about (130, 150, 140), its face and feet white, its
  feet shadow teal, with a soft halo. About 10 x 9.5 units for a Goomba (a 16-pixel sprite drawn 2.5 times as large as it is in a level) and taller for a
  Koopa. The pane's own picture is untouched under it.
* **Scale, tumble, fade?** No tumble, no scale change, no fade while it flies. It does not change with the enemy type except by shape.
* **Speed and timing.** Constant: frame n is at start + (end - start) n / 30. The burst starts on the frame after the ghost reaches the recipient's
  middle. For the real player's 40 sends the first flash frame is 0.483-0.500 s after the send began in 35 (median 0.483; the outliers of 0.30-0.45
  coincide with other flashes on the same pane), centred on the pane (median 0.50 x 0.50 of its width and height). The bracket's own 0.25 s flight
  (doc 54) overlaps the first half of the ghost's.
* **The burst** (pane 33, t=527.172-527.339, 11 frames): a white rounded square 11.6, 13.5 x 15, 16, 21 x 23 units on frames 0-3, then a light-cyan
  (about 202, 255, 255) square 26 x 28 at 70 %, a near-empty frame (6 %), 28 x 30 at 40 %, then a rim round the pane's edge 3, 2.2, 1.5, 1.0 units thick at
  30, 22, 15, 10 %; gone on the 12th frame. The same on every pane and for both enemy types (the Goomba and Koopa samples).
* **Multiple sends.** Each send has its own ghost and its own clock; ghosts and bursts overlap freely. Pane 20 sent two Goombas 13 frames apart: the
  first at 1.43 units a frame to pane 23 (arrives t=515.983, burst 516.000), the second at 2.9 units a frame to the pane two below (it passes through pane
  23's middle on its frame 15 without a burst; its own burst is two panes down 0.5 s after it started).
* **Rapid sends of the real player.** The bracket is cancelled by a newer send (doc 54) but the sent enemy is not: every send has a ghost and a burst
  (flashes follow each send by 0.5 s, e.g. t=549.2 and 549.65 with the brackets cut).
* **When it goes, relative to the attack.** The ghost and its burst are over 0.683 s after the send; the attack's own activation (the incoming
  bar's icon reaching the boundary, the enemy appearing in the opponent's level) comes later and is a different picture. No ghost remains.
* **Bot to bot is the same visual language as the player's.** There is no reticle for a bot. A send at the real player has none of this (pane 23's
  red line starts at t=515.683 and no ghost leaves it).

The real player's own window shows ghosts too: at t=526.55 three ghost Goombas walk on the ground and one stands on the brick ledge, translucent grey-teal,
the incoming attacks that have reached the player's level. Our physical incoming enemies are drawn as ordinary enemies; that is a different object
(`BattleEnemyFactory`, doc 45) and is not changed here.

Implementation: `BattleSendGhost` (the measured timeline, geometry, burst table and the ghost's picture made from the enemy sprite, pure and cached),
`BattleSendGhostLayer` (draws each ghost clipped to the panes it crosses, and the burst at the recipient's middle; under the target reticle and the red
lines), `BattleAttackPresentation.send_ghosts()` (one ghost per SENT event whose recipient is an opponent, read from the log: `{seq, sender, target, kind,
age}`; no ghost for a silent replay or a send at the real player; cleared by `clear_flights()` when the round ends; time is the presentation clock, so a
pause holds it), `BattleScreen` (wiring, and the freeze).

A pane that is showing its KO card gets no burst (the card has its own); this cannot happen in a match (a recipient is alive when it is sent, and a
card shows two seconds after the session's KO) and is only defensive. A recipient KO'd while its ghost flies changes nothing: the ghost arrives and
bursts on the pane as it is shown.

## 5. The 41 sends and their flash offsets

Send start t / pane (flash offset s): 509.017/16 (0.483), 515.833/8 (0.500), 526.683/33 (0.500), 527.633/5 (0.500), 528.483/17 (0.500), 529.3/33 (0.500),
530.35/8 (no flash: the recipient was KO'd at 530.333), 535.167/1 (0.483), 536.733/12 (0.500), 537.633/34 (0.500), 540.35/28 (0.500), 542.217/12 (0.483), 544.25/16 (0.500), 545.267/14 (0.417),
546.15/29 (0.500), 547.0/7 (0.467), 547.3/31 (0.500), 548.733/9 (0.467), 549.217/2 (0.483), 549.667/13 (0.483), 554.817/9 (0.483), 561.933/12 (0.500),
564.517/25 (0.483), 569.2/32 (0.500), 576.883/13 (0.467), 581.867/1 (0.300), 583.25/31 (0.483), 588.483/34 (0.500), 590.817/32 (0.483), 592.5/25 (0.500),
598.417/2 (0.483), 599.367/20 (0.333), 600.0/32 (0.500), 602.617/2 (0.467), 604.0/14 (0.433), 607.733/12 (0.467), 609.217/2 (0.467), 611.8/12 (0.467),
613.3/32 (0.450), 613.8/13 (0.500), 618.733/32 (0.500) (60 fps frames are 1/60 s; the scan frames used for the offsets are 1/60 s too).

## 6. What is not reproduced, and uncertainty

| Item | Status |
|---|---|
| The small white pixels that drift up from the burst (t=527.18-527.5, 529.0-529.28) | seen, not drawn (a few pixels) |
| The ghost's exact art (soft glow, the shell on a Koopa's ghost, a winged Koopa's ghost at t=628.9) | approximated from the sprite; only Goomba and Koopa exist as enemy types |
| Whether a burst shows on a KO card | not observable (it cannot happen); none is drawn |
| The ghosts in the real player's window (incoming attacks drawn as translucent ghosts) | seen at t=526.55; not changed: physical incoming enemies are unchanged |
| Our `BattlePreviewInvader` (a large sprite with a red halo and marker ahead of Mario while an attack is ACTIVE on an opponent) | unchanged. The reference shows nothing like it on an opponent pane at the activation (no persistent ghost was seen); it is an earlier guess, left for a decision |
| The slide down the flagpole and the camera that follows it | the track slides along a fixed view |
| The courses' real levels (1-2 underground, 1-4 castle...) | stand-ins from the five clean levels (section 3) |
| Sends cancelled by a rapid send: their exact destination | each has a ghost to the authoritative recipient; the cancelled bracket's heading in the reference does not land on a pane centre, so it was not used |

## 7. Corrections to earlier docs

* Doc 47 B35-ATTACK-002 and doc 51 ("bot-to-bot sends are not drawn", "no line or effect between two opponent panes was seen"): wrong. The ghost
  between two panes is drawn only where it crosses a pane, so contact sheets of the gaps and the window show nothing between them.
* Doc 54 section 9: "Ghost enemies in opponent panes" is now built (section 4). Its "non-KO pane flashes ... trigger unknown" are the bursts of
  section 4 (t=515.633-515.80, 518.35-518.48).
* Doc 54 section 6 and the KO card text: unchanged; the burst here and the KO card's second flash are the same white rounded-square effect.

## 8. Unchanged, verified

`BattleSession`, `BattleAttackSystem`, targeting (modes, recipients, RNG draws), queue semantics, `BattleIncomingSpawner` and the physical incoming
enemies, spawn placement, `BattleBotSimulator`, the timer and coin economy, round outcome, level progression and every other mode. The session
tests (`battle_session_test`, `battle_attack_test`, `battle_targeting_test`, `battle_incoming_plan_test`, `battle_incoming_game_test`,
`battle_attack_game_test`) were not edited; `tests/battle_preview_course_test.gd` and `tests/battle_send_ghost_test.gd` check that a session with the
previews attached is identical (snapshots, ids, placements, KO ticks, progress) to one without.

## 9. Tests

Listed with their counts in the commit message and the report that came with it: `battle_preview_course_test` (stand-in rule, real stages, the walk audit,
the transition, stale state, KO and pending outcomes, settle, whole matches, determinism, the screen freeze), `battle_send_ghost_test` (timeline, geometry,
burst, clipping, art, the presentation's ghosts, bots and the player, rapid sends, KO, pause, round end, read-only), the GL sections in
`battle_attack_render_test` (the ghost and burst as pixels, held clock, clear) and `battle_preview_render_test` (a real clear read back from the atlas and
the display, a freeze mid-fade).
