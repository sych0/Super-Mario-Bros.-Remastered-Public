# 48 — Battle: incoming-enemy presentation, milestone M6b (what was built and verified)

Status: implemented on top of `fa88f68` (M6a, doc 46), which was physically playtested and accepted. This pass is **presentation only**. Nothing about what an attack is,
who it targets, when it activates, when it spawns, how it resolves, or how the enemy behaves was changed. The numbering skips 47: that number is reserved for the SMB35
implementation reference (see section 9).

The rule is unchanged: **`BattleSession` decides what attacks exist. `BattleIncomingSpawner` materialises them. The real enemy's fate reports back to the session.**
M6b adds a fourth role that decides nothing: **what the player sees** (the strip, and one short mark on a newly spawned enemy), derived from the session's own state.

## 1. What changed

| File | Change |
|---|---|
| `Scripts/Classes/Battle/BattleAttackPresentation.gd` | `Phase` enum and `phase_of` (a pure function of the session's state); rows gain `phase`, `in_transit`, `arrive`; `fresh` now starts when the line **lands**; `player_phase_counts()`; `player_resolved()` (fading icons); `is_animating()` covers the new fades and an arriving attack. `player_incoming()` rows and `counts()` are still exactly the session's unresolved attacks |
| `Scripts/Classes/Battle/BattleIncomingStrip.gd` | One look per phase, the fading icon of a just-resolved attack, and a colour-keyed count legend. `rows` and `counts` unchanged; `phases`, `ghosts`, `items` added |
| `Scripts/Classes/Battle/BattleArrivalEffect.gd` (new) | The arrival mark: four corner brackets that open outward around a newly spawned enemy and fade, 0.5 s, then the node frees itself |
| `Scripts/Classes/Battle/BattleIncomingSpawner.gd` | Starts one effect per **accepted** spawn report, moves it with the enemy, ends it with its time or its attack; `arrivals`, `arrival_log`, `show_arrival` (tests/tools only) |
| `tests/battle_incoming_view_test.gd`, `tests/battle_arrival_game_test.gd`, `tests/battle_arrival_render_test.gd` (new) | Section 7 |
| `tests/tools/battle_incoming_capture.gd` (new) | Dev tool: GL screenshots of every phase and of the effect frame by frame |

Not touched: `BattleSession`, `BattleAttackSystem`, `BattleAttack`, `BattleIncomingPlan`, `BattleSpawnPlacer`, `BattleEnemyFactory`, `BattleHandler`, `BattleScreen`, `Enemy.gd`, any prefab,
the attack lines (`BattleAttackLayer`, `BattleAttackFlight`, `BattleAttackGeometry`), the opponent previews, the bot model, the targeting policy, pacing (1.5 s grace, 1.0 s gap, 3 ACTIVE), Classic.

## 2. The four presentation states

A phase is **derived, never stored, never read back**: `BattleAttackPresentation.phase_of(state, spawned)` from `BattleAttack.State` and the session's `spawned_tick`. There is no second state machine.

| Phase | Session state | In the strip | In the level |
|---|---|---|---|
| **QUEUED** (in transit) | QUEUED, the attack's line has not landed (0.55 s) | hollow icon with a dotted outline, art faint | nothing |
| **QUEUED** (landed) | QUEUED | dim brown icon; a yellow outline pulses once as the line lands (0.45 s) | nothing |
| **ARRIVING** | ACTIVE, `spawned_tick < 0` | amber icon with a slowly pulsing outline; a white flash for 0.7 s as it becomes ACTIVE | nothing yet (held attacks stay here until a safe spot exists) |
| **IN_LEVEL** | ACTIVE, `spawned_tick >= 0` | saturated red icon with a solid bright outline; white flash for 0.6 s when it appears | the real enemy, with the arrival mark for 0.5 s |
| **RESOLVED** | RESOLVED | the icon stays in its slot and fades over 0.5 s: **green** if the player defeated it, **grey** for anything else that ended it (level change, left behind, a pit) | nothing |

Because the session activates in send order and the spawner delivers in strict order, the icons always read left to right as **in level, arriving, queued**; the tests check this at every tick of whole matches.
No fading icon exists for `TARGET_OUT` or `ROUND_ENDED`: the player being out or the round ending clears the strip at once, as before.

The strip's text now lists only the phases that have any, each in its phase's colour and in icon order: `IN LEVEL 2  ARRIVING 1  QUEUED 3` (short forms `LVL`, `ARR`, `Q` if the strip is crowded). `counts` is unchanged (queued, ACTIVE); the legend splits ACTIVE.

## 3. The arrival effect

**Four white corner brackets** around the enemy's sprite. They start 2 px out (never touching it), open outward over five 0.1 s steps (margins 2, 3, 5, 7, 9 px; opacity 1.0, 0.9, 0.7, 0.45, 0.2), and the node is gone after 0.5 s. 1 px lines, whole pixels, no tint, no flash, no blink of the enemy.
The game's own drop shadow (the player's `drop_shadows` setting) applies to them like to every sprite; the effect draws no shadow of its own.

Decisions, each of them found by testing and not assumed:

* **It is a sibling, not a child, of the enemy.** `KoopaTroopa.gd:92` does `shell.old_entity = self.duplicate()`, which copies every child; an effect parented to an incoming Koopa would be copied into the Koopa that wakes from its shell.
  The effect belongs to the spawner (a plain `Node`, so its position is a world position) and the enemy has no extra node. Mutation test: parenting it to the enemy fails 20 checks.
* **It never touches the enemy**: no `modulate`, `self_modulate`, material, scale, signal, child or physics body, and the enemy's properties equal a native enemy's during and after (compared property by property, Goomba and Koopa).
* **One per physical spawn, ever.** It starts only after `report_player_incoming_spawned` returned true (the session refuses a second report for a seq), and `_arrived[seq]` keeps it once for the life of the spawner. Removing that guard fails 29 checks.
* **It stops with the game**: it runs on the spawner's physics delta, so pause and freezes hold it, exactly like the enemy.
* **It ends with its attack**: when the attack is no longer ACTIVE (stomped, vanished, round over) or the enemy is gone, the effect goes at once instead of finishing.
* **Interpolation is off for it.** The project interpolates physics; the effect is repositioned in whole pixels each physics frame, so interpolation drew its 1 px lines between pixels (a 1 px offset, seen in the GL test).
* **The box is the sprite's real frame.** The sprite's bottom row is the origin row, not the one above (found when the pixel comparison reported the first version overlapping 5 of the enemy's feet pixels at step 0).
* An enemy that spawns at the right edge of the view has its right-hand brackets clipped by the window. That is harmless and was left alone.

## 4. Strip changes in short

Per-phase look (section 2), landing-anchored "new" outline, fading icons that keep their slot, per-phase count legend. `MAX_ICONS` (9) and the layout (strip A) are unchanged.
**One timing fix**: the "new" outline used to start at the send (the `RECEIVED` event shares the send's tick) and was over before the line, which takes 0.55 s, landed. It now starts at the landing, kept in the attack's record so it is not cut when the line is pruned.

## 5. Attack lines: not changed

Looked at, in GL, with three simultaneous lines to the window. They are readable and not cluttered, so nothing was changed there. Pause (`presentation_held()`), targets, timing and routing are untouched.

## 6. Koopa, transitions, bonus rooms: behaviour preserved

Nothing in `BattleSession`, the spawner's delivery, `BattleHandler._exit_tree` or the Koopa path was changed. The new tests assert the presentation of the same behaviour:
an incoming Koopa gets one effect (the height of a Koopa); stomped even **during** it, the attack resolves once, nothing is sent, the effect ends at once, the strip fades one green icon, the shell is untagged and has no effect,
the woken Koopa is built exactly like a native one with no effect and no second resolve or send, and stomping it changes nothing visible. A pipe into the bonus room resolves what was in the level (grey fade, `LEVEL_TRANSITION`),
carries what never appeared (still ARRIVING), delivers it in the room with exactly one effect in total, and an attack held for lack of a safe spot has no effect (an effect only ever follows a spawn).

## 7. Tests

| File | Checks | What |
|---|---|---|
| `tests/battle_incoming_view_test.gd` (pure) | 107 | The phase table; one attack through all four phases; `in_transit` and `fresh` follow the line; several at once in order; **whole matches** (12 seeds, bots sending, random spawns and resolutions): the phases equal the session's at every tick and never invert; one arrival mark per spawn (a repeated event cannot restart it); fading icons per cause, none for `TARGET_OUT` / `ROUND_ENDED`; a held clock freezes every fade, resuming continues; round cleanup; the strip model (`merged`, `legend`, `rows`/`counts` still the session's); late creation is silent; `is_animating`; the presentation changes nothing in a session (300 ticks, identical snapshot and log) |
| `tests/battle_arrival_game_test.gd` (real game, headless) | 110 | The strip's phases follow three real attacks and equal the session's at every frame; **one effect per spawn** (a sibling owned by the spawner, on the enemy's feet, 0.5 s, asking again does nothing); the enemy equals a native one **during and after**; **the enemy's physics is identical frame by frame with the effect on and off**; five attacks: one effect at a time, in order, a second apart, each on its own enemy, the queued ones have none; the effect ends with its attack (stomp, vanish); the pause menu holds effect, enemy and strip mark; the Koopa chain; the pipe round trip; a win; Quit |
| `tests/battle_arrival_render_test.gd` (GL, xvfb) | 32 | The same enemy spawned twice, effect on and off, rendered frames compared: **every pixel the enemy draws is identical** (Goomba and Koopa), differences only in a ring around it, none beyond, **none at all 40 frames later**, white brackets really on screen; the strip's real colours per phase, the white flash, the green fade |
| Existing Battle suites | | All pass with the counts doc 46 recorded: `battle_attack_test` 167, `battle_attack_view_test` 118, `battle_session_test` 21, `battle_round_test` 49, `battle_screen_test` 111, `battle_hud_test` 51, `battle_preview_atlas_test` 44, `battle_preview_test` 77, `battle_attack_screen_test` 56, `battle_round_lifecycle_test` 103, `battle_attack_game_test` 69, `battle_incoming_plan_test` 95, `battle_incoming_game_test` 83; GL `battle_screen_render_test` 32, `battle_preview_render_test` 24, `battle_incoming_render_test` 12. No script errors in any log. **One suite was edited, on purpose:** `battle_attack_render_test` (now 40 checks, was 39) samples the strip's pixels, and three of its assertions described the old strip. "Four dim icons" was taken while the lines were still in the air (now: four hollow icons in the air, then four dim ones once landed); "three lit icons" expected red for an ACTIVE attack, but that test switches the spawner off, so the attacks are ARRIVING and amber; and "counts written on the right" used a luminance threshold the old pale label met and the new coloured per-phase legend does not (now a lower threshold over a wider region). Each was first diagnosed from the saved pictures, then updated to assert the same intent against the new look, with the sampled colours in the message |

Mutation checks (applied, observed failing, reverted): effect parented to the enemy (20 failures), no once-per-seq guard (29), effect nudging the enemy (exactly the physics A/B check), brackets touching the sprite (the pixel check, Goomba and Koopa, with the pixels named).

Commands: `godot --headless --fixed-fps 60 --path . -s tests/<suite>.gd`. GL: `xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 -s tests/battle_arrival_render_test.gd -- pack=SandboxStandIn`.
Screenshots: `tests/tools/battle_incoming_capture.gd` (same command, `out=` a directory).

## 8. Not done, as scoped

SMB35 targeting modes, more enemy types, recycling/resending, any change to pacing, balance, the bot model, the layout or the previews. No performance work, as instructed, and none was measured: the physical playtest of M6a found performance fine. The new work is at most one extra node (the gap between spawns keeps effects from overlapping) drawing eight 1 px rects for half a second, and a few more strip draws.

## 9. SMB35 reference

`docs/47-smb35-implementation-reference.md` **did not exist** when this pass began (checked in the working tree and on every remote branch: `main`, `battle-reference`, `claude/sharp-hypatia-uo1086`, `claude/youthful-tesla-99o9hl`) and was not used.
Nothing here claims fidelity to SMB35: the strip's colours and layout, the arrival mark and the fading icons are this project's own presentation choices. When the reference exists, the places to compare are
the arrival mark (shape, duration, whether the game flashes the enemy itself), what the incoming indicator shows and when, and whether resolution is shown at all.

## 10. For the physical test

**How to run it.** The repo's CI (`feature-build.yml`, manual) pins Godot 4.4 and exports Windows and Linux only, so it cannot make a Mac build. Pull `claude/youthful-tesla-99o9hl` and run the project in the Godot 4.6 editor on the Mac
(the first open re-imports and picks up the new `BattleArrivalEffect` class). Gameplay is unchanged from the accepted M6a build, so the interesting part is purely how it looks and reads.

What to look at, in the order it happens:

1. **A send to you.** The strip gets a hollow, dotted icon while the line is still flying, which fills dim brown with one yellow pulse as the line lands. (Before M6b the pulse fired at the send.)
2. **It becomes ACTIVE** (about 3 s later): the icon turns **amber**, flashes white, and its outline pulses; the text reads `ARRIVING n`. While the level is still inside its 1.5 s grace, or the 1.0 s gap, or no safe spot exists, it stays amber.
3. **The enemy appears.** Four white corner brackets open outward around it for half a second, and the strip icon flashes white and turns **red** (`IN LEVEL n`). Check the brackets are noticeable without being distracting, never cover the enemy, and that the enemy looks exactly normal afterwards.
4. **You defeat it.** Its icon fades **green** in its own slot; anything else that ends it (a pipe, left behind, a pit) fades it **grey**; then the strip closes up. Stomp a Koopa and watch for the same single green fade, a plain shell, and a woken Koopa with no mark.
5. **Several at once.** Icons should always read left to right as red, amber, dim brown; marks never overlap (they are a second apart). Is the strip crowded or clear with five or six icons?
6. **Pause** during a mark or a fade: it should hold and then continue.
7. **The pipe into 1-1a and back** with attacks arriving.

Judgement calls that are yours: the brackets' size and duration at your real window size (they are 1 px lines, so small at the native 256 px width), whether amber against red is distinct enough on your display, the legend wording and colours, and whether the hollow in-transit icon feels like useful information or noise.
Things that are expected: an enemy that spawns at the right edge has its right-hand brackets clipped by the game window; the brackets carry the game's own drop shadow when that setting is on, and none when it is off.
