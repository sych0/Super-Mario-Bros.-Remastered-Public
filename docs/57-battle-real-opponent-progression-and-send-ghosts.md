# 57 — Real opponents: the "winter" panes after 1-1, ownership, and the real player's send ghost

Status: on top of `b4305e3` (doc 56). This pass fixes real-opponent course progression as the physical build exercises it, makes ownership of
an opponent exclusive and checked, and draws the real player's stomps with the same send ghost as a bot's. The brain was not tuned and nothing
was optimised (34 worlds stay at doc 56's cost); `BattleBotController` is still the one shared brain.

## 0. In one paragraph

`--battle-real-bots=4` given the way it was written (`game --battle-real-bots=4`, no `--` before it) never reached the game: Godot keeps an
argument that comes before `--` out of `OS.get_cmdline_user_args()`, the only list `BattleBotDirector.count()` read, so the count was 0, without
a word. With 0 real opponents every contestant, 1-4 included, was a dice opponent drawn by the legacy previews. Their 1-1 looked like 1-1 (the
previews draw a sketch of the real 1-1 with its real art); after a clear the previews have no sketch of 1-2 and show a **stand-in**, 3-2, drawn in
World 3's **Snow** theme: the "winter" pane. No `BattleBotWorld` ever existed. With the flag read (`-- --battle-real-bots=4`), `b4305e3` already
loaded the real 1-2 and kept the pane on the world. Now the flag is read from both halves of the command line, a bad value is an error, the
round prints who owns which opponent, and nothing can give a real opponent to the previews or draw a stand-in for it.

## 1. The trace

`tests/tools/battle_bot_transition_trace.gd` runs the full Battle screen from the title (GL renderer; the real player's game, HUD, atlas, panes,
legacy previews of the others), fixed seed, and logs for opponents 1-4 every change of: world object, course and requested next course, scene path
requested and actually instanced, old level freed, new level and Mario (identity, parent), viewport (identity and RID), pane texture RID, what the
cell draws (`BattlePreviewCell.last_source`: world / preview / placeholder / failure), whether a legacy track exists for the id, which stage
courses `BattlePreviewStages` was asked for and for whom; and saves the cells and the worlds' screens as PNGs before the flag, in the fade and after
the cut. Each real Mario is put on the ground 46-64 px before 1-1's pole and runs and jumps at it; the pole, the `FlagPole` state, the slide, the
hold, the fade and the cut are the game's (`natural=1` leaves it to the brains).

**`b4305e3`, `godot ... -s trace.gd --battle-real-bots=4 -- ...` (the flag before `--`, as written):**

| What | Recorded |
|---|---|
| `OS.get_cmdline_args()` | `["-s", "...trace.gd", "--battle-real-bots=4"]` |
| `OS.get_cmdline_user_args()` | `[]` (the flag is not there) |
| `BattleBotDirector.count()` / `real_ids()` | `0` / `[]` |
| director, world-driven contestants | none; none |
| legacy tracks | 34 (ids 1-34): opponents 1-4 are dice opponents with `BattlePreviewTrack`s |
| frame 357 | `BattlePreviewStages` builds course 1 (1-2): geometry 9 = **3-2, stand-in** |
| frame 744, id 2 | its track enters course 1 after the session's clear; its picture is 3-2's sketch, World 3 theme **Snow** = the winter pane |
| frame 1444, id 2 | course 2 (1-3): a 4-1 stand-in, Jungle |

**`b4305e3`, `... -- --battle-real-bots=4` (the flag after `--`):** count 4; 4 worlds, 30 tracks (5-34). For each of 1-4 at its cut (frames 78, 95,
99, 129): requested course 1 = `World1/1-2.tscn`, instanced `1-2.tscn`; the old level freed 2 frames later; a new level in the world's own viewport and
a new Mario in that level; theme Overworld -> Underground; viewport and texture RIDs unchanged (e.g. id 1: viewport RID 158943854723075, texture
158961034592426, before and after); the cell `is_bot`, bound to the same world, no track, no stage request; 180 frames on, each plays 1-2
(x 52-133, `Normal`). The PNGs of the cell after the cut are the world's own underground screen.

So the world never failed to enter 1-2, and presentation never fell back for a world-driven opponent: there was no world-driven opponent.

## 2. Root cause, and whose fault

**Exact cause:** `BattleBotDirector.count()` read only `OS.get_cmdline_user_args()`. An argument before `--` is in `OS.get_cmdline_args()`
only (Godot's rule; an exported game run as `game.exe --battle-real-bots=4` and an editor run with that string in its run arguments are the same
case). The parse produced 0, `BattleBotDirector.configure` marked nobody world-driven, `BattleScreen._ensure_driver` made no director and gave all
34 opponents to `BattlePreviewDriver`, and the previews did what they were built to do after a clear (doc 55): show the next course, by a stand-in
when it has no sketch (`BattlePreviewStages.geometry_for(1)` = 9, 3-2, themed by `BattlePreviewAssets` for World 3: Snow).

**Gameplay or rendering ownership?** Neither of the two systems misbehaved for the opponents it owned. It was the assignment of ownership: the
configuration that says which system owns contestants 1-4 silently said "the previews". The world's gameplay (1-1 -> 1-2) and its pane source were
correct whenever the world existed.

## 3. The fix

* **The flag** (`BattleBotDirector.parse_count`): `--battle-real-bots=N` is read from `OS.get_cmdline_args()` and `OS.get_cmdline_user_args()`,
  so `game --battle-real-bots=4` and `game -- --battle-real-bots=4` both give 4 (and `SMB1R_BATTLE_REAL_BOTS=4`; the command line wins). A
  value that is not a number is a `push_error`, not a silent 0. The default, no flag, is still 0: the build plays as before.
* **Visible ownership:** each round prints `Battle: opponents #1-4 play their real games (BattleBotWorld); #5-34 are legacy previews`; in a debug
  build each real opponent's course change prints `Battle: opponent #1 1-1 -> 1-2: its world loaded res://.../1-2.tscn (level ..., Mario ...)
  into the same viewport (RID ...); its pane shows that world`. Both make a run like the physical one self-explaining.
* **One owner per opponent, enforced** (none of this was the cause; all of it would have made the cause impossible to miss, and closes the ways a
  stand-in could reach a real opponent):
  * `BattleScreen._ensure_driver` gives owners once per session: the world-driven ids (`BattleBotDirector.world_driven_ids`) to a
    `BattleBotWorld`, only `legacy_ids` to `BattlePreviewDriver`. The worlds no longer depend on the previews: before, a session whose preview
    driver could not be built (`create` returned null) had its worlds torn down and rebuilt every frame.
  * `BattlePreviewDriver.create` refuses a world-driven id; `BattlePreviewStages` refuses a stage requested for one (`forbidden`; every request now
    carries the contestant id, `queries` / `queried_for`); `BattlePreviewCell.set_live` refuses a preview frame on a cell that shows a world, and
    `set_bot` clears any. Each refusal is `BattleBotDirector.violation`: counted and a `push_error`.
  * **No silent fallback:** a world-driven opponent's cell draws its world or a failure (magenta and black stripes, and a `push_error` naming
    why): no world owns it, its world has no screen, or its world failed. `BattleBotWorld._fail` stops a world whose course has no scene, whose
    scene does not load or is not a level, whose instanced level is not the course's scene, or that has no Mario. Never a preview, a stand-in or
    the placeholder. `BattlePreviewCell.release()` takes a cell back between sessions (no owner, no contestant: it draws nothing until the next
    owner, which a match gives in the same frame).
  * `BattleBotWorld.transitions` records every course entered (requested path, loaded path, a weak reference to the level left, level, Mario,
    viewport and texture ids); `BattlePreviewCell.last_source` records what the cell last drew.

## 4. Proof: the real 1-1, the real 1-2

`tests/battle_bot_transition_test.gd` (headless, the full Battle screen from the title, seed 11, 65 checks), one real opponent: its cell draws its
world on 1-1; its Mario rides the real flagpole; the world's phases are exactly PLAYING, CLEARING, FADING, PLAYING (99 frames); requested and
instanced `World1/1-2.tscn` in the world's own viewport; no failure; a fresh real Mario on pad 101 in the new level; skinned Underground; the old
level freed; the same viewport object and RID and the same texture; the cell still the world's and its last draw that world on course 1, same
texture RID; the session's LEVEL_CLEAR; the pane's course "1-2". Then its brain plays 1-2: Mario moves on, stands on 1-2's floor, the camera
scrolls, a 1-2 Goomba wakes and moves. The real player's level, numbers, theme, score, coins and Global's skin inputs are unchanged.

Pixels (`battle_bot_render_test`, GL): after the cut the cell is the world's own 1-2 screen cropped (95 % of sampled pixels equal to the world
viewport's crop, the rest Mario a frame apart), 0 % sky (1-1 was 75 %; the 3-2 stand-in is mostly sky).

The trace of section 1 re-run on the fix with the flag before `--`: count 4, and all four opponents enter the real 1-2 exactly as with `--`.

## 5. Proof: real opponents never use the legacy previews

In both tests, every check: the opponent's `BattleBotWorld` exists, the session has it world-driven, the cell is bound to that world with no frame,
no `BattlePreviewTrack` exists for the id, `BattlePreviewStages.queried_for(id)` is false for the whole run (so no sketch or stand-in was ever asked
for it, and `BattlePreviewDriver.update` never steps it: it only steps tracks), the cell's last draw is the world, and `BattleBotDirector.violations`
does not move. The guard checks: the driver refuses an id it is handed that is world-driven; the stages refuse; a world's cell refuses a preview
frame; a world that cannot load its course fails and its cell draws the failure; a world-driven opponent with no world draws the failure, never the
placeholder (a legacy opponent with no preview still gets the placeholder).

## 6. Shared state, two real opponents

Two opponents, staggered: 1 clears while 2 plays 1-1 with its brain; 2 clears while 1 plays 1-2. At each cut the other world's level, Mario,
viewport, course, phase and skin are unchanged and it kept playing (its own flag signal: the first clear released nobody else's Mario); each ends in
its own 1-2 instance in its own World2D with its own pad; exactly two bot worlds; `Global.theme_override / time_override / current_room_type /
world_num / level_num` (pushed while a world's resources resolve) are back to the real game's; the real player's game is untouched. No
contamination was found in the worlds' transitions themselves.

Found while tracing, and fixed (both in `BattleHandler`, the real player's game reaching every Mario in the SceneTree):

* **The real player's time-out killed every real opponent.** `get_tree().call_group("Players", "time_up")` reached the bots' Marios too (they are
  in the "Players" group). Proved: with the old line the new check fails, both real opponents dying on the same tick as the real player; now
  `GameWorld.call_group(self, ...)`.
* The real player's live progress took `get_tree().get_first_node_in_group("Players")`, which can be a bot's Mario; now `GameWorld.first_player`.

## 7. The real player's stomps and the send ghost

**Why they did not look the same.** They already went through the same data path: a stomp in the real game (`Goomba.stomped_on` / `KoopaTroopa`
-> `summon_shell` -> `Enemy.report_battle_defeat` -> `BattleSession.report_enemy_kill` -> `BattleAttackSystem._send`) logs one SENT, and
`BattleAttackPresentation._on_sent` makes one ghost for every SENT at an opponent, sender 0 included. The difference was in drawing:
`BattleSendGhostLayer` clipped every ghost to the 34 panes (doc 55's measurement of the reference: never over the game window). A bot's ghost
starts at its own pane's middle, inside a pane, so it is seen leaving; the real player's starts at the game window's middle, outside every pane, so it
was invisible for the first ~27 of its 30 frames and showed only as it entered the recipient's pane.

**The unification.** One rule for every sender: a ghost is drawn in its **sender's own window** and the panes
(`BattleSendGhost.clip_rects(layout, sender)` = `BattleAttackGeometry.rect_of(sender)` + the panes). For a bot its own window is its pane, already a
pane, so bot ghosts are drawn exactly as before (checked piece for piece over 899 sampled frames of 6 senders x 5 recipients); for the real player it
is the game window, so the ghost is seen leaving the window's middle. `BattleSendGhostLayer.ghost_look(g)` is the one place a ghost's picture,
body and pieces are worked out, for any sender. No second effect: the only per-sender inputs are the start point and that window. This departs from
the reference measurement of doc 55 for the real player's ghost only (there it was not seen over the window), as directed.

**Goomba** (`battle_send_ghost_game_test`, headless; the real player's Mario stomps a real 1-1 Goomba in the window while a real opponent's Mario
stomps one of its own 1-1): one SENT each (0 -> #9 and 1 -> #9, GOOMBA); frame for frame the same picture (the Goomba's ghost sprite), the same
body size, the same age; each on a straight constant-speed line from its sender's middle to #9's middle; the real player's drawn inside the game
window at the start, the bot's inside its pane; both arrive on #9; the same 11-frame burst starting on frame 30; both gone after. GL
(`battle_bot_render_test`, physical stomps: Mario dropped onto the enemy, the game's collision does the rest): the real player's ghost seen leaving the
window, 1 499 pixels centred at (209, 129) canvas units, 3 frames in (expected (210, 125)); the opponent's in its pane, 1 309 pixels at (18, 48)
(expected (18, 48)); both bursts 4 136 pixels centred on #9.

**Koopa:** the same checks, all equal (KOOPA ghost sprite, taller); GL: the real player's 1 988 pixels at (209, 129), the opponent's 1 903 at (18, 44);
bursts 3 252 and 3 255 pixels.

Kept: the 0.5 s straight constant-speed flight, the grey-teal enemy-shaped ghost, the burst's frames and timing, independent overlapping ghosts
(two stomps 6 frames apart: two ghosts, each on its own clock), the pause holding them, the round's end clearing them; targeting, WATCH OUT!, the
incoming bar, attack ownership, the KO cards and the results freeze are untouched (their suites below). One observation, unchanged and the same for
every sender: on frame 30 the presentation clock's sum of thirty sixtieths is a hair under 0.5 s, so the ghost is still drawn at the recipient's
middle under the burst's first frame.

## 8. Tests

| Suite | Result |
|---|---|
| `battle_bot_transition_test` (headless, new) | 65 / 65 |
| `battle_send_ghost_game_test` (headless, new) | 32 / 32 |
| `battle_bot_render_test` (GL) | 23 / 23 (5 + 18 new: the ghosts, the real 1-2 on the pane) |
| `battle_send_ghost_test` | 83 / 83 (4 new: the sender's own window, bots unchanged) |
| `battle_bot_world_test`, `battle_bot_screen_test` | 41 / 41, 18 / 18 |
| the other 18 existing headless suites | 1 796 / 1 796 (the 19 of doc 56 incl. `battle_send_ghost_test`: 1 879) |
| the 5 existing GL suites (arrival, attack, incoming, preview, screen render) | 200 / 200 |

`battle_attack_screen_test` failed 1 of 131 once (`(they ended by their authoritative timers)`), the unseeded-round flake doc 56 records on
`b4305e3` too; 131 / 131 on three re-runs. Pre-existing and not touched: a stomped Goomba's `killed("Hello")` script error (doc 56). In this
container the ROM-derived art is the stand-in pack (chroma green where the ROM's art would be); with the ROM the same pictures are the real art.

## 9. Not in this pass

Brain competence (doc 56 A8) and the 34-world cost (A9, A10) are unchanged and next, as decided: one `BattleBotController` for every opponent,
seeded traits for variety.

## 10. Commit

The commit that adds this document, on `claude/youthful-tesla-99o9hl` over `b4305e3`.

## 11. HANDOFF STATE (read this first in a fresh session; kept current, newest facts at the end of each list)

Written at a point where the cloud budget was nearly spent. Everything below was reconstructed from the repository (this doc, doc 56, `git log`),
not from the chat. This is the Battle Mode status document: update **this section** (not a new file) as work continues, and re-point to a later
doc if a numbered doc supersedes it.

**Branch / HEAD.** `claude/youthful-tesla-99o9hl`; code HEAD `b397b28` (doc 57's fix commit), pushed to `origin`. The commit that adds this section
sits directly on top (`git log -2`). **Working tree was clean: no uncommitted work, no temporary instrumentation, nothing to inherit.**

**Done (do not redo).** Docs 35-57: battle architecture, session, attack system, incoming enemies, targeting, UI fidelity, send presentation
measured against the public SMB35 video (`reference-video/reference.mp4` on the local machine, never committed), send ghosts (doc 55), real
opponent worlds (`BattleBotWorld`, `BattleBotController`, `BattleBotDirector`; doc 56 is the architecture decision, accepted), real opponents
keep their real worlds into 1-2 and the real player's stomps draw the same send ghost (doc 57).

**Architectural decisions already accepted.** (1) Opponents are real game instances (`BattleBotWorld`), one per opponent, own World2D/viewport, pane
= that world's screen; the facsimile previews are legacy and are to be deleted at R3. (2) One shared brain, `BattleBotController`, varied by seeded
`BattleBotTraits`. (3) Exclusive ownership per opponent: a world-driven id never touches `BattlePreviewDriver/Stages/Cell.set_live`; violations
are `BattleBotDirector.violation`. (4) A send ghost is drawn in its sender's own window + the panes, for every sender (doc 57 s7, a deliberate
departure from doc 55's measurement for the real player only). (5) Default build still has 0 real opponents.

**Physical-test feedback from Zack (as recorded in the docs).** Doc 56: "the 34 opponents must actually be playing the game", not tracks or
scripted walkers. Doc 57: after 1-1 the opponent panes showed a "winter" (3-2 stand-in) course; cause was `--battle-real-bots=4` given before
`--` never being read, so every opponent was a legacy preview (fixed); and the real player's stomps showed no visible send ghost (fixed).
**Zack has not yet re-tested these two fixes on the physical build, so confirmation is outstanding.**

**Current blocker.** None in code. The open item is Zack's physical confirmation of doc 57's two fixes, run as
`game --battle-real-bots=4` or `game -- --battle-real-bots=4` (or env `SMB1R_BATTLE_REAL_BOTS=4`); the startup log must print
`Battle: opponents #1-4 play their real games (BattleBotWorld); #5-34 are legacy previews`. Container caveat: ROM-derived art is the stand-in
pack (chroma green) here; judge art on the physical build.

**Remaining work (doc 56 s13, unchanged).** A8 brain competence (bots clear 1-1 about as often as the reference but twice as fast, ~2x early
KOs); A9 34 worlds at 60 fps; A10 course-load hitches (`battle_bot_bench`, doc 56 s17-18); R1 per-world seam for the remaining entity set + per-world
RNG; R2 performance; R3 all 34 real by default and delete the preview pipeline; R4 brain on every course, power-ups, warp zones, coins. Also
pending video measurements M1-M6 in doc 53 s5 (`tools/reference/measure_reference.py`).

**Tests.** From the repo root, headless: `godot --headless --fixed-fps 60 --path . -s tests/<name>.gd` (each file's header gives its exact line;
GL suites such as `battle_bot_render_test` run without `--headless`). Last results (doc 57 s8): `battle_bot_transition_test` 65/65,
`battle_send_ghost_game_test` 32/32, `battle_bot_render_test` 23/23, `battle_send_ghost_test` 83/83, `battle_bot_world_test` 41/41,
`battle_bot_screen_test` 18/18, other headless suites 1 796/1 796, other GL suites 200/200. Trace tool: `tests/tools/battle_bot_transition_trace.gd`.
Godot was not on PATH in the cloud container I last checked; I did not re-run the suites in this handoff step.

**Known regressions / uncertainties.** `battle_attack_screen_test` fails 1 of 131 on an unseeded round in roughly 1 run in 3 (pre-existing flake,
doc 56 s19; pin `BattleHandler.seed_source`). A stomped Goomba emits `killed("Hello")`, a script error in `GibSpawner.summon_gib` (pre-existing,
unfixed). On frame 30 a send ghost is still drawn under the burst's first frame (clock rounding, same for every sender). Reference-video values
in `BattleSendStyle` rest on doc 52/54 measurements; doc 53 s5 lists what is still unmeasured.

**Important paths.** `docs/56-*.md`, `docs/57-*.md` (this), `docs/53-*.md` (fidelity audit + video measurement plan); `Scripts/` Battle* classes
(`BattleBotWorld`, `BattleBotDirector`, `BattleBotController`, `BattleScreen`, `BattleHandler`, `BattlePreview*`, `BattleSendGhost*`, `BattleAttack*`);
`tests/*.gd` and `tests/tools/`; `tools/reference/` (video tools); `/home/user/reference-video/reference.mp4` (local only).

**Do not redo.** The flag-parse diagnosis and the ownership enforcement; the send-ghost unification; the 1-1 -> 1-2 transition proof; the video
measurements already in docs 52/54/55.
