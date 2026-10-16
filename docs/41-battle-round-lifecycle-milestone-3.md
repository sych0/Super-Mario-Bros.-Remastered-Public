# 41 — Battle screen, milestone 3 (round lifecycle): what was built and verified

Status: implemented on top of `788a264` (doc 38 section 7 / milestone 3). Milestone 4 (strip and badge content) and everything
after it (attacks, targeting, incoming enemies) are not started. Nothing in the layout, the opponent previews, `BattleSession`
or the bot simulation changed.

## 1. What now exists

Battle is a repeatable round-based mode. A death, a time out or a win ends the round, shows the results, and starts a fresh round in
the **same** `BattleScreen`. The player is never sent to the title, Game Over or Time Up. Only an explicit Quit from the pause menu
returns to the title.

```
 title ─► LOADING ─► PRE_ROUND ─► PLAYING ─► ROUND_OVER ─► RESULTS ─┐
            ▲                                                       │ confirm (after 1 s) / 10 s timeout
            └────────────────────── next round ─────────────────────┘
 Quit (pause menu, any state) ─► title
```

| File (`Scripts/Classes/Battle/` unless noted) | Role |
|---|---|
| `BattleRound.gd` (new) | The pure state machine: states, end causes, timers, lockout, banner text. No scene tree, session or input. Emits `state_changed`. |
| `BattleScreen.gd` | Owns one `BattleRound` for the whole Battle; turns state changes into freezing the game window, the READY / GO! banner, the result card and the next round; sees a win |
| `BattleHandler.gd` | `start_match()` is now the one shared round start; `on_player_died()`, `on_death_finished()`, `quit_battle()`; the old `end_match()` is gone; the "time up" request is retried |
| `Scripts/Classes/Entities/Player.gd` | Two Battle-only hooks (see 3) |
| `tests/battle_round_test.gd`, `tests/battle_round_lifecycle_test.gd` (new) | Pure and real-game lifecycle tests |

Everything else is untouched: `Global.transition_to_scene` already routes a Battle scene change into `GameViewport`, and
`Player.death_load` already handled Battle before lives or the timer.

## 2. State machine (`BattleRound`)

| State | Entered when | What happens |
|---|---|---|
| `LOADING` | a round is started (`BattleRound.begin_round`) | The previous round's session is replaced; `LevelTransition` and then World 1-1 load into `GameViewport`. |
| `PRE_ROUND` | the round's first `Level` has been in the window for 3 frames | `GameViewport.process_mode = DISABLED` (gameplay frozen), so `BattleHandler` stops too (the Battle clock is frozen); the game's HUD timer is stopped; "READY". 2.5 s. |
| `PLAYING` | the pre-round ends (or at once if it is 0) | Window released, clock runs, "GO!" for 0.8 s. |
| `ROUND_OVER` | player death, time out, or the last one standing, **only from PLAYING** | A death plays out; a win freezes the window and holds 1.0 s. |
| `RESULTS` | the death animation finishes (`death_finished()`), the win hold ends, or a 12 s safety timeout | The result card. |
| back to `LOADING` | confirm (jump / accept) after a **1.0 s lockout**, or **10 s** with no input | The next round. |

Timing is real time (the screen's frame delta), not the Battle clock. The 3-frame delay before the freeze lets the camera and Mario settle
on the level start (checked numerically: the camera did not move between the frozen frame and the release).
`BattleRound.pre_round_override` (tests) and `--battle-preround=SECONDS` / `SMB1R_BATTLE_PREROUND` (debug builds) shorten or skip the countdown.
Because a state can only be left in one direction, a late or duplicate end report cannot re-end a round or skip the results.

## 3. Player KO timing

Before: the KO was registered in `Player.death_load()`, after the death hang, the death music and a 3-second wait (about 4-5 s after dying), and
`end_match()` then resolved the match.

Now: `Player.die()` calls `BattleHandler.on_player_died()` right after `is_dead = true` (Battle only), which registers the KO at that moment,
so the placement and the KO tick are those of the instant of death. `Player.death_load()` (after the animation) only reports
`on_death_finished()`, which moves ROUND_OVER to RESULTS. The bots do not move during the animation (the tree is paused, as before), and the rest
of the ranking is resolved when the results come up.

* A time out: the session KOs the player for `TIME` at the tick; `BattleHandler` asks the real player to `time_up()` (and asks again each second, because
  the game ignores a death while Mario is in a pipe or leaving the level); `die()` reports `TIMEOUT` as the end cause.
* A win: seen by `BattleScreen._process` when the session is finished and the player is alive. It also works between levels.
* Duplicates: `die()` returns early while Mario is already dead, `BattleSession.report_ko` ignores a contestant who is already out, and `BattleRound.end_round`
  ignores everything after the first report. Calling `on_player_died()` repeatedly changed nothing (tested).

## 4. Why a round never reaches the title, Game Over or Time Up

* Death: `Player.death_load()` looks up the game mode first. BATTLE is in the dispatch table, so the lives and the timer are never consulted. That branch now only
  reports the end of the death sequence.
* Time out: `time_up()` calls `die()`, so it takes the same path.
* The next round is `BattleHandler.start_match()` followed by `Global.transition_to_scene(LevelTransition)`. With mode BATTLE and a session,
  `BattleScreen.routes()` sends that into the existing `GameViewport` (the old game scene leaves the tree, the new one enters). `change_scene` is never called.
* The tests watch every scene loaded into the game window across 11 rounds and assert that none is the title, Game Over or Time Up, that
  `scene_changed` never fired, and that `current_scene` stayed the same `BattleScreen`.

## 5. Fresh round: one shared reset path

`BattleHandler.start_match()` is used by the title (round 1) and by the results (every later round). It: sets mode BATTLE and campaign SMB1; `clear_saved_values()`;
world 1, level 1; `Global.reset_values()`; creates a new `BattleSession` with a **new seed** (`new_seed(previous)`: the global RNG, never equal to the previous
round's; a test can script it with `seed_source`); resets `PipeCutscene.seen_cutscene`; sets `Level.first_load = true` (a win leaves no death to do it);
`Global.death_load = false`; unpauses the tree; then transitions to 1-1. A fresh session means 35 alive contestants, tick 0, no events, no placements,
no progress, 600 s each. The screen drops the old preview driver and clears every cell's live frame before the new session's tracks are built.


## 6. Results

The card (over the game window only, as before) shows: "ROUND n OVER", "YOU PLACED p / 35" or "YOU WON!", the cause ("OUT BY: HAZARD / TIME"), opponents left, levels cleared,
the winner, and "PRESS JUMP FOR NEXT ROUND". Confirm is ignored for 1.0 s; at 10 s it advances on its own. It starts the next round, not the title. A forfeit has no
results (Quit leaves at once).

## 7. Quit

`BattleHandler.quit_battle()` clears the `BattleSession`, sets mode NONE, and transitions to the title (the pause menu's own handler is unchanged). The title frees `BattleScreen`
and its `_exit_tree` restores the user's window (content scale, aspect, mode, stretch, snapping), the HUD offset and the fade viewport; tests compare all of them to before Battle, from the
playing state and from the results.

## 8. Stability over rounds

Five consecutive rounds (alternating death and time out), compared at the same moment of each round:

| | result |
|---|---|
| Nodes in the tree | 7967 in every round |
| `BattleScreen` children, atlas children, panes (34), cells (34), `SubViewport`s (2), `BattleHandler` (1), Mario (1), game-window children, `level_complete_begin` and `transition_finished` connections | identical in all five rounds |
| Previous `BattleSession` | collected (`WeakRef` is null); at most the current one is alive |
| Seeds | all distinct (11 over the whole test) |
| Orphan nodes | **+30 per round, exactly what one Classic level load leaves** (measured in the same run: 442, 472, 502, 532). They are `ResourceSetterNew` nodes that the game creates and never adds; this is not new and Battle adds nothing to it. I left it alone (out of scope: it would change Classic code). |

## 9. Tests

| File | What | Command |
|---|---|---|
| `tests/battle_round_test.gd` (new, pure) | every state and transition; READY / GO! text; pre-round 0 and the override; end conditions; duplicates and illegal transitions are ignored; lockout (confirm at 0.5 s and 0.9 s ignored); confirm and timeout both start the next round; five rounds | `godot --headless --path . -s tests/battle_round_test.gd` |
| `tests/battle_round_lifecycle_test.gd` (new, real game, 93 checks) | pre-round freezes Mario, the Battle clock and the game timer and the camera is the level start; PLAYING resumes all of it; death: KO at the instant of death with that placement and tick, round over while the animation plays, bots wait, results after, 35 distinct placements, results content; next round: same screen, new session and seed, 35 fresh contestants, no KO / order / progress carried over, game mode Battle, 1-1, unpaused, pre-round again, no scene change; timeout and win rounds the same; results input (lockout, auto-advance); pause menu over the results; no title / Game Over / Time Up in 11 rounds; five-round stability; Quit returns to the title and restores the window (also from the results); Classic death costs a life and reloads, the last life goes to Game Over, a Classic time out goes to Time Up, none involving Battle | `godot --headless --fixed-fps 60 --path . -s tests/battle_round_lifecycle_test.gd` |
| `tests/battle_screen_test.gd`, `battle_hud_test.gd`, `battle_screen_render_test.gd` | updated for the new API (Quit no longer shows results; results are driven by the round); the render test now includes a real death, the result card dimming the window only, and the next round; these real-level tests skip the countdown (`pre_round_override = 0`) | as before |
| `tests/battle_session_test.gd`, `battle_preview_test.gd`, `battle_preview_atlas_test.gd`, `battle_preview_render_test.gd` | unchanged, all pass | as before |

## 10. Screenshots (`docs/battle-screen/`, sandbox stand-in art)

`19-m3-pre-round-ready-1080p.png` (READY, frozen, 600 s, all 35 alive), `20-m3-go-1080p.png` (GO! after release), `21-m3-round-results-1080p.png` (the card after a real death).

## 11. Decisions worth revisiting

* Level music keeps playing through the pre-round (it lives in `AudioManager`, outside the frozen window).
* The pause menu stays reachable during the pre-round and the results (so Quit is always reachable). While it is open the pre-round and the results timers (and the results' confirm) wait; closing it resumes them (added after review: `BattleRound.paused`, set from `Global.game_paused`). A death animation or a win hold is not paused.
* The pre-round only happens for a round's first level, not for 1-1 → 1-2.
* A win holds for 1.0 s; a death waits for its animation, with a 12 s safety net.
