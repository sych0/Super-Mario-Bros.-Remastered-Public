# 44 — Battle attacks, milestone 2: the visible send / receive loop

Status: implemented on top of `f7a0e24` (docs 42 and 43). The authoritative attack loop was already deciding everything; this milestone **shows** it.
You defeat an enemy, a line carries it to the opponent it was sent to, and a few seconds later it is a danger inside that opponent's miniature game.
Attacks aimed at the real player are visible in the Battle UI (the incoming strip) but **nothing reaches the real game yet**: no enemy is spawned into the
256x240 window and no time, life, power or hazard is taken from the player.

The session still owns every decision. Nothing here chooses a target, simulates a combat, resolves an attack or writes to `BattleSession` / `BattleAttackSystem`:
the presentation reads the event log (`SENT`, `RECEIVED`, `INCOMING_ACTIVATED`, `INCOMING_RESOLVED`) and draws it. No second attack simulation exists.

## 1. Files

| File (`Scripts/Classes/Battle/`) | Role |
|---|---|
| `BattleAttackPresentation.gd` (new) | The model. Reads `session.events` with a cursor and keeps, keyed by attack sequence id, a record per attack, the lines in the air, who is marked as a target, per-contestant queued / active counts and the real player's incoming list. Pure data (no scene tree); time is a presentation clock advanced by `update(delta)`. One instance per session |
| `BattleAttackFlight.gd` (new) | One line's timing: how far along it is, how strong it is, when it is over |
| `BattleAttackGeometry.gd` (new) | Pure geometry: where a line leaves its sender and lands (pane centres; just inside the game window's edge for the real player), and the part of a line that runs through the game window |
| `BattleAttackLayer.gd` (new) | The lines and the target marks, drawn over the 480x270 canvas |
| `BattleIncomingStrip.gd` (new) | The real player's incoming enemies, in the reference's strip A |
| `BattleEnemyIcon.gd` (new) | The small picture of a Goomba / Koopa (the previews' own art; flat shapes if the art is missing) used by the lines and the strip |
| `BattlePreviewInvader.gd` (new) | One incoming enemy inside an opponent's preview: a presentation object with no physics and no link to the session |
| `BattlePreviewTrack.gd` | Makes / ends invaders from `INCOMING_ACTIVATED` / `INCOMING_RESOLVED`; clears them when the picture's own KO or the level's end arrives |
| `BattlePreviewFrame.gd`, `BattleMiniGameRenderer.gd` | The frame carries `invaders`; the renderer draws them (larger than level enemies, on a red halo, with a marker) |
| `BattleOpponentPane.gd` | `set_incoming(counts)`: small pips in the pane's corner at display resolution (filled = ACTIVE, outline = QUEUED) |
| `BattleScreen.gd` | Creates the presentation per session, updates it every frame, feeds the panes, strip and layer; a new round clears it (`_clear_attack_view`) |

Unchanged: `BattleSession`, `BattleAttackSystem`, `BattleAttack`, the targeting policy, the round lifecycle, the 480x270 composition, the contained 256x240 `GameViewport`,
the preview atlas, Classic. `BattleSession` was not touched at all.

## 2. How attack sequence ids map authoritative state to visuals

`BattleAttack.seq` (0, 1, 2, ... per round, never reused) is the only key. Every visual is created from an event that carries it and ended by an event that carries it:

| Authoritative event | Presentation |
|---|---|
| `SENT` (seq, sender, target, kind) | a record (QUEUED) and a **flight** (the line) with that seq; the target is marked; the target's queued count +1 |
| `RECEIVED` (seq) | the record's arrival time (the strip's "new" outline for an attack on the real player) |
| `INCOMING_ACTIVATED` (seq) | the record goes ACTIVE (queued -1, active +1; the strip icon flashes); the target's **preview track** makes an **invader** with that seq, when the picture's clock reaches the event's tick |
| `INCOMING_RESOLVED` (seq, cause) | the record is RESOLVED (counts -1, the icon leaves the strip); the invader with that seq blinks out and goes; with `TARGET_OUT` a line still in the air is cut |

The pieces never look at each other: a pane's marker, a strip icon and an invader are three views of the same record id, and none of them is derived from another or from what a
pane is showing. `tests/battle_attack_view_test.gd` compares them against the session's own queues (`get_incoming`, `attack_history`) after every tick of five whole matches (23,400 comparisons) and
compares the invaders in all 34 previews against the session's ACTIVE attacks at the picture's time over 4,908 preview moments: no mismatch, and no invader without an attack.

What the presentation keeps is copied out of the events (plain numbers); it never stores an event dictionary, a session or an attack object. The twin-session test runs a match with the
previews and the presentation and the same match without them, comparing snapshots and event counts every tick.

## 3. Outgoing lines (player -> opponent, bot -> bot, bot -> player)

One mechanism for all three. A flight lasts 0.55 s (the head, an eased move) and its target stays marked for 0.3 s more; `BattleAttackLayer` draws it every frame while it exists:

* **A line** from where it left its sender to its head, faint at the tail and bright at the head, with the attack's **enemy** (the real Goomba / Koopa art) riding the head, and a ring at the launch.
* **The real player's sends** leave from inside the game window, 56 px in from the edge facing the target's panel, at about the target's height (kept off the HUD band and the ground): thick, gold with a white core.
  They end in the middle of the target's pane. Nothing in the window is covered except that short line.
* **A bot's sends** run pane centre to pane centre, thin and white. Where such a line crosses the player's playfield (a left pane to a right pane) it is drawn at a quarter strength and its head at a third, so the bots' traffic never streaks across the game.
* **Sends at the real player** (red) run from the sender's pane to a point just inside the window's edge on the sender's side, and the **frame around the game window flashes red** while they land.
* **The target** is marked for the whole send effect: the pane's tint (yellow) and a pulsing yellow border, from the moment of the send until the line has landed and faded. The target is the flight's `target`, which is the event's `b`: the session's own pick.

A line towards a contestant who is eliminated while it flies is cut (it fades in 0.12 s) rather than landing on a KO. Lines of an eliminated sender still land (the attack does).

## 4. Incoming enemies in the opponents' previews

`BattlePreviewTrack` already received every event of its contestant from `BattlePreviewDriver`; it now also reads `INCOMING_ACTIVATED` / `INCOMING_RESOLVED`.
When the picture's clock reaches the activation tick, a `BattlePreviewInvader` of the attack's kind appears just beyond the right edge of the miniature run, closes in on Mario at 44 px/s to 36 px ahead of him
(a second one stands 24 px further out, a third 48) and then shadows his run with a small back-and-forth, standing on the walk line's ground (floating over a pit). When the resolution tick is reached it blinks out for 0.4 s and is removed.

It is **not** part of the preview's enemies: Mario never stomps it, meets it or is hurt by it; it is not in `enemies`, takes no part in `_contacts`, and cannot cause a `HIT` or a `KO`. Only the authoritative
events decide that an invader exists. The track's own KO (`_end_ko`) and the level's end (`_grab_pole`, where a vanish starts) only clear what is still on screen. `BattlePreviewTrack` still has no way into the session
(a source-level test checks that none of the presentation classes or the track references the mutating API).

It is drawn 1.7x the size of level enemies on a red halo with a red marker above it, because at pane size (32x41 logical px) a plain level-sized Goomba is about 3 px. The picture trails the session by `BattlePreviewDriver.LAG` (2 s), like everything in it,
so an enemy appears in the preview 2 s after its attack went ACTIVE and goes 2 s after it resolved; the pane's pips (section 5) are not delayed.

## 5. Pane markers

Every opponent pane shows one small pip per unresolved attack against it (up to six, from the right edge of the top row): a lit red square for ACTIVE, an outline for QUEUED. They are drawn at display resolution by the pane (like its frame and
number), come from the presentation's counts (which mirror the session's queue), and so show attacks also when the pane is on the placeholder (a bot that has left World 1-1) or a KO is showing (the pips are hidden then).

## 6. The real player's incoming strip

The reference's strip A (112,245,256,11), under the game window, now carries a dark bar with: `INCOMING`, one **icon per unresolved attack on the real player in send order** (the enemy's picture on a lit red box for ACTIVE,
a dim box with a half-transparent picture for QUEUED; nine at most, then `+N`), and on the right `ACTIVE n  QUEUED m`. The moment an attack goes QUEUED -> ACTIVE its icon (and the counts) **flash** for 0.7 s; a new arrival gets a yellow outline for 0.45 s.
The list, the states, the kinds and the counts come from the presentation, which comes from the events; tests compare them against `session.get_incoming(0)` on every frame (the screen reads the session in its own `_process`, which runs before the level's
`BattleHandler` steps the clock, so it is at most one frame behind).

An ACTIVE attack on the real player still has no timer (doc 43): its icon stays until the game resolves it (`resolve_player_incoming`), the level ends, the player is eliminated or the round ends.
Nothing in the real game calls the first of those yet, so for now they stay lit until a level transition or the end of the round.

**Untouched by it:** the game window's contents (checked: the same 16 enemy nodes before and after thirteen seconds of attacks, none carrying an attack, none in the viewport named like one), `Global.lives`, score and coins, the player's power state, position and life,
and the player's time (it runs down by exactly the Battle seconds that passed). There is no hidden penalty and no hidden hazard.

## 7. Simultaneous attacks

Nothing is shared between attacks except the two lists the presentation keeps. A flight has its own start time and its own (sender, target, kind); a line ends on its own (a newer send does not extend or cut an older one); the records, counts and
invaders are keyed by seq. 13 sends in one moment are 13 flights with 13 distinct ids, each equal to its authoritative attack; 35 at once (every contestant) is 35 lines (the capture tool and the stress case do exactly that), each opponent carrying up to three invaders. A safety valve keeps at most 256 lines in the air (never
reached: at most 35 contestants can send per Battle second, each line lives 0.85 s) and still records every attack.

## 8. KO, round, Classic

* **A bot is eliminated with attacks active.** The session resolves them as `TARGET_OUT` at the KO. The presentation zeroes the bot's counts at once, cuts any line still flying at it, and the bot's preview keeps playing its normal KO: invaders blink out at the resolution tick, and if one were still there when
  the picture's death ends it is cleared with the run (`_end_ko`; tested with a synthetic track that gets a KO and no resolution). No kill attribution is invented; placement is not touched.
* **A new round** replaces the presentation (`_clear_attack_view` + a new session): no line, mark, pane pip, strip icon or invader survives (tests check the old objects are not reused and the new ones are empty, `signature() == "0:0"`).
* **Attacks off** (`default_attacks_enabled = false`): the screen creates no presentation; strip and layer are empty.
* **Classic:** the Battle screen does not exist, so none of this does; with a stale session around, Classic kills log no event and create no layer or strip (tested).

## 9. Performance

Measured with `tests/tools/battle_attack_bench.gd` on the standalone Battle screen (34 live previews, the strip, the layer; no level in the window), 1,800 frames, seed 5, two runs per row (the two numbers are the two runs).
Modes: **none** = attacks off (no presentation, no events: the baseline), **normal** = a normal match (the bots' own sends), **stress** = every contestant defeats an enemy every Battle second and nothing hurts the bots,
so about 27 lines are in the air at all times and every opponent carries up to three incoming enemies (969 attacks in 30 s; 69 invaders shown and 73 attacks ACTIVE on average).

**CPU per frame**, headless (the screen's `_process` incl. the preview driver and the presentation, plus the time spent recording draw commands for the previews and the attack layer; the GPU is not involved):

| mode | lines in air | invaders shown | `_process` mean | of which attack presentation | draw recording (previews + layer) | total | against none |
|---|---|---|---|---|---|---|---|
| none, 1x | 0 | 0 | 1.00 / 1.05 ms | 0 | 0.17 / 0.19 + 0 ms | **1.17 / 1.23 ms** | |
| normal, 1x (45 sends in 30 s) | 1.3 | 5.7 | 1.24 / 1.24 ms | 25 / 23 us | 0.22 + 0.08 ms | **1.54 / 1.54 ms** | +0.3 ms |
| stress, 1x | 27 | 69 | 1.68 / 1.50 ms | 79 / 70 us | 0.39 / 0.37 + 0.59 / 0.55 ms | **2.66 / 2.41 ms** | +1.3 ms (8 % of a 16.7 ms frame) |
| none, 4x clock | 0 | 0 | 1.60 / 1.62 ms | 0 | 0.20 / 0.21 ms | **1.80 / 1.83 ms** | |
| normal, 4x clock (87 sends in 119 s) | 2.4 | 3.2 | 1.62 / 1.61 ms | 26 us | 0.20 + 0.11 ms | **1.93 / 1.92 ms** | +0.1 ms |

* The presentation itself (reading events, flights, counts) is 25 us per frame in normal play and under 0.1 ms in the stress case; the largest piece of the added cost is recording the lines' draw commands (0.08 ms normal, about 0.55 ms stress, for 27 lines with their heads, rings and shadows),
  then the preview driver stepping the invaders (about +0.1 ms normal, +0.4 ms stress).
* Slowest single frames are the same order as the baseline's (the baseline's worst frame is 3.9-16 ms, the stress case's 8.8-12.8 ms): the frame after a Battle second does the preview driver's catch-up. A single 32 ms frame was seen once in the very first stress run and did not reproduce in five more.

**Wall-clock frame time** under Mesa software GL (xvfb, 1920x1080, 600 frames; absolute numbers are inflated by software rasterisation, compare the rows): none **64.5 ms** (291 draw calls), normal **65.9 ms** (+2 %, 312 calls),
stress **83.9 ms** (+30 %, 688 calls). The extra stress cost there is the 27 blended lines and the ~70 halos being rasterised, not logic; on a real GPU 690 small draw calls are not a concern, and nothing was optimised for it.

No meaningful regression in normal play. In the worst sustained case the CPU cost is 1.3 ms a frame; the one structural cost worth watching if attacks ever get much busier is the layer's per-line draw calls (about five each: shadow, line, head, ring, and a second piece where a bot's line crosses the window).
Nothing was optimised: no measurement showed a problem. The preview atlas, the panes and the shader are unchanged (the older render tests pass unchanged apart from the two expectation updates below).

## 10. Tests

| File | Checks | What |
|---|---|---|
| `tests/battle_attack_view_test.gd` | 118 (pure + real art, headless) | geometry (all 34 panes, the window side, the clipping); player send -> flight to the authoritative recipient; bot -> bot between the right panes; bot -> player; simultaneous sends distinct by seq; the presented counts and the player's list equal the session's queues after every tick (5 seeds); QUEUED -> ACTIVE flash, no timer on the player's, resolve by id; TARGET_OUT cuts a line; round end; late creation; read-only (source scan of every presentation class + the track, no object references held, twin sessions identical); deterministic replay (the event sequence, the lines, and all 34 previews' pictures); flight timing; invaders: Goomba and Koopa, in the right preview only, by seq, several at once, RESOLVED removes, blink-out, KO clears; the invaders in all 34 previews equal the session's ACTIVE attacks at the picture's time |
| `tests/battle_attack_screen_test.gd` | 56 (real game, headless, `--fixed-fps 60`) | the wiring and that nothing lives in the game viewport; a **real stomp** becomes a flight to the authoritative recipient; bot sends; three simultaneous; pane pips equal the session counts every frame; a Goomba and a Koopa appear in the right preview after their activation and leave when resolved; attacks on the real player appear in the strip with matching icons / states / counts, flash on activation, stay active, and **no enemy is spawned**, lives / score / coins / power / position unchanged, time down by exactly the elapsed seconds; resolving one by id removes its icon; a new round clears everything; attacks off; Classic |
| `tests/battle_attack_render_test.gd` | 39 (GL, xvfb) | pixels: the line between the window and the pane, the target tinted, nothing left after; a bot's line clear between the panes and faint across the window; halo, marker and pip in the opponent's pane (one, then three), gone when resolved; the strip's dim and lit icons, the flash, the counts, the window frame lighting up; the window's ground unchanged; the cost of a 16-send second |
| the existing Battle suites | unchanged and passing | `battle_session_test` 21, `battle_attack_test` 167, `battle_preview_test` 77, `battle_preview_atlas_test` 44, `battle_hud_test` 51, `battle_round_test` 49, `battle_attack_game_test` 67, `battle_screen_test` 111, `battle_round_lifecycle_test` 103; GL: `battle_screen_render_test` 32, `battle_preview_render_test` 24 |

Two existing GL tests were updated for what this milestone changes on purpose: `battle_screen_render_test` expected strip A to be plain gold and now expects the incoming bar; `battle_preview_render_test` measures how a picture is scaled into its pane,
so it now runs with the attack loop off (a target mark or pip on a pane is not a scaling error: with attacks on, that test failed on pane 24, which a send had marked).

Tools: `tests/tools/battle_attack_capture.gd` (the six pictures), `tests/tools/battle_attack_bench.gd` (section 9).

## 11. Captures (`docs/battle-attack/`, 1920x1080 unless noted, art = the sandbox stand-in pack)

| # | File |
|---|---|
| 1 player -> opponent, mid-flight | `01-player-sends-to-opponent.png` |
| 2 bot -> bot, mid-flight (the line is faint across the window) | `02-bot-sends-to-bot.png` |
| 3 an opponent's pane with an incoming Goomba | `03-opponent-with-incoming-goomba-pane.png` (128x164), `-x4.png` (magnified), `-screen.png` |
| 4 a pane with several incoming enemies (Goomba, Koopa, Goomba; three pips) | `04-opponent-with-several-incoming-pane.png`, `-x4.png`, `-screen.png` |
| 5 attacks aimed at the real player | `05-incoming-on-real-player-flights.png` (lines landing, frame flash, queued icons), `-strip-flash.png` / `-x4.png` (QUEUED -> ACTIVE), `-strip-settled.png` / `-x4.png` |
| 6 simultaneous stress | `06-stress-simultaneous-attacks.png` (every contestant sends at once on top of three earlier bursts) |

## 12. Known visual approximations

1. **Invaders shadow Mario; they never meet him.** The preview has no collision, so an incoming enemy closes to 36 px ahead of Mario and stays there for as long as its attack is ACTIVE, instead of walking into him and being stomped.
2. **The picture trails the session by 2 s** (the existing preview design). An invader appears 2 s after its attack went ACTIVE and goes 2 s after it resolved; the strip, the pips and the lines are not delayed. So for a moment a pane can show a pip with no enemy yet (or an enemy with no pip).
3. **Invaders exist only while the pane shows the live World 1-1 picture.** A bot that has cleared 1-1 (placeholder) or is on another course shows the pips but no enemy. In the flag / castle walk of a bot that is clearing 1-1, enemies vanish and none arrive.
4. **Invaders are drawn larger than level enemies** (1.7x, on a halo) so they read at 32x41 px; the line's head enemy is a half-size sprite.
5. **Terrain:** an invader follows the walk line's ground level (up a pipe, floating 10 px over a pit); it does not walk, fall or climb.
6. **Lines are straight** pane-centre to pane-centre, so a bot-to-bot line across the screen runs over the game window (faintly); a line to or from the real player starts / ends 56 px inside the window, not at Mario.
7. **The strip shows at most nine icons** (then `+N`); the session's cap of three ACTIVE per contestant means only a long queue ever gets there.
8. **Presentation time is wall-clock** (frame deltas, at most 0.1 s per frame): lines keep flying while the game is paused, and at a dev sim speed above 1 several sends can fly at once.
9. The screen reads the session in its own `_process`, ahead of the level's clock step: panes and strip are at most one frame behind the session.

## 13. Not done (as scoped)

Physical incoming enemies in the real player's game, manual targeting / strategies, new enemy types, balance, more preview courses, layout changes, atlas work.
`DEFEATED_BY_PLAYER` / `DESPAWNED` are still never reported by the game (nothing exists to defeat): an ACTIVE attack on the real player stays lit until a level transition, the player's elimination or the end of the round.
