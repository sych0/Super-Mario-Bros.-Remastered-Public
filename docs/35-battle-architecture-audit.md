# 35 — Battle Mode Architecture Audit (revised)

**Status:** Audit and design only. No implementation has been started. No gameplay code, scenes, assets or project settings were changed.
**Base commit:** `8d4f3ed` (Godot 4.6, GDScript).
**Revision:** Replaces the first draft of this file, which assumed several *real* players sharing one game. That assumption was wrong. Items that only matter for real local multiplayer are reclassified in §3.

**How to read this:** §1 is the settled scope. §2 is **observed repository facts** only. §3 reassesses the earlier "blockers". §4–§7 are **recommendations**. Line numbers were checked against the base commit, but re-check them before editing.

---

## 1. Settled scope

| | Decision |
|---|---|
| Real players | **1**, local, playing with the existing SMB engine (unchanged physics, levels and HUD) |
| Other contestants | **34 simulated bots**, held as abstract state only |
| Bot representation | Data records advanced by a lightweight simulation. No `Player` nodes, no input slots, no hidden level instances. |
| Presentation | No split-screen and no 35 simultaneous game views |
| Networking | Out of scope |
| Authority | The game engine is authoritative for contestant 0 (the real player) **only**. `BattleSession` is authoritative for the match: who is alive, placements and the winner. |

The existing dormant local-multiplayer system (`player_id` 0-3, `connected_players`, per-slot input actions) is **not** a foundation for this mode and should not be revived or extended for it.

---

## 2. Observed repository facts

Facts only; no recommendations in this section.

### 2.1 Game modes

- `enum GameMode{NONE, CAMPAIGN, BOO_RACE, CHALLENGE, MARATHON, MARATHON_PRACTICE, LEVEL_EDITOR, CUSTOM_LEVEL, DISCO}` (Global.gd:193). A parallel string array `game_mode_strings` (Global.gd:195) is indexed by the enum and used by resource-pack conditions (ResourceSetterNew.gd:452).
- There is no mode interface. Behaviour is selected by `if`/`match` on `Global.current_game_mode` at scattered sites. The ones relevant here:
  - **Death outcome:** `Player.death_load()` uses a dictionary keyed by mode (Player.gd:1314-1366). Modes without an entry fall through to: game over if `lives <= 0`, time-up screen if `time <= 0`, otherwise `default_reload`. Lives are only decremented in CAMPAIGN and MARATHON (1323-1325).
  - **Level completion:** `Level.transition_to_next_level()` (LevelClass.gd:191-215) special-cases CHALLENGE and BOO_RACE. Every other mode advances to the next campaign level through `LevelTransition.tscn` (calls `write_save()` at LevelClass.gd:211).
  - **Pause menu:** `GameHUD.activate_pause_menu()` (GameHUD.gd:215-224) has entries for BOO_RACE and MARATHON\*. Every other mode gets `StoryPause`.
  - **Save:** `SaveManager.write_save` matches on mode (SaveManager.gd:79-106) and ends with `_: pass`, so an unknown mode writes no mode-specific keys. `LevelTransition` writes the save only in CAMPAIGN (LevelTransition.gd:48-49). `transition_to_next_level` calls `write_save()` for every mode it does not special-case (LevelClass.gd:211).
- **Menu:** the title screen's `ChallengeOptions` list holds `BooRace` and `ChallengeHunt` (TitleScreen.tscn). Options lists are wired by `option_N_selected` signal connections, and at least three slots are in use elsewhere (`Options2`, TitleScreen.tscn:1727-1732). Story mode sets `Global.current_game_mode = CAMPAIGN` before loading levels (TitleScreen.gd:99, 108, 235, 267, 275).

### 2.2 Single-player gameplay state (the real player's engine)

- One `Player.tscn` instance is baked into each level scene. Extra players are never spawned: `spawn_in_extra_players()` returns immediately (LevelClass.gd:145-147), and `Global.connected_players` is never set above 1 (Global.gd:164).
- `score`, `coins`, `lives` and `time` are plain globals (Global.gd:100-120). `time` has **no change signal**.
- **Level timer:** `GameHUD` (an instance inside the autoloaded `Global.tscn`, so it survives scene changes) runs a 1 Hz tick in `_process` → `on_timeout()` (GameHUD.gd:14-20, 231-245). The tick runs only while `Global.can_time_tick`, a level exists, and the time-limit setting is on. At 0 it calls `time_up()` on the `Players` group, which calls `die()` (Player.gd:1369-1370).
- **Timer set and reset:** `Level._enter_tree` sets `Global.time = time_limit` when `Level.can_set_time` is true (LevelClass.gd:95-97). `die()` sets `can_set_time = true` (Player.gd:1297). `time_limit >= 999` means infinite time (LevelClass.gd:125-129).
- **Timer bonus:** `ClockItem` adds 100 (ClockItem.gd:8). `can_time_tick` is switched off during flagpole, castle bridge, pipes, vines and the level-transition screen (see grep of `can_time_tick =`).
- **Death:** `die()` emits `dead`, pauses the whole tree, sets `Level.first_load = true`, plays death music, waits, then calls `death_load()` (Player.gd:1280-1312).
- **Damage:** `damage(type)` emits `damaged` only when a power-down occurs. With no damage state it calls `die()`. There is no attacker parameter (Player.gd:1228-1245).
- **Power-ups:** `get_power_up()` emits `powered_up` (Player.gd:1394-1402). `Global.player_power_states` holds a per-slot power index string.

### 2.3 Gameplay event sources that already exist

| Event | Existing source | Notes |
|---|---|---|
| Level start | `Level._enter_tree` (LevelClass.gd:85-120). `Level.first_load` tells a fresh level apart from a sub-room/pipe area. | Static `first_load` is set to true by death and by `transition_to_next_level`. |
| Level complete | `Global.level_complete_begin` signal, emitted by `EndFlagpole` (EndFlagpole.gd:48) and `CastleBridge` (CastleBridge.gd:105). Also `EndFlagpole.player_reached` and `CastleBridge.victory_begin` per instance. | DiscoLevel already listens to the per-instance signals (DiscoLevel.gd:54-57). |
| Enemy defeated | `Enemy.killed(direction)` signal (Enemy.gd:5), emitted from `die`, `die_from_object`, `die_from_hammer` and some subclasses (Goomba, Wiggler, Podoboo, GibSpawner). `EnemyDefeatDetect` gizmo shows a pattern of connecting to it from outside (EnemyDefeatDetect.gd). | Imperfect. Goomba emits `killed` on *every* stomp, including non-lethal hits of multi-hit variants (Goomba.gd:21-30). `flag_die` (end-of-level cleanup) does **not** emit it. No killer is passed. |
| Player damaged | `Player.damaged` (Player.gd:483, 1235) | Power-down only; no source |
| Player death | `Player.dead` (Player.gd:479, 1286). `last_damage_source` holds a cause string. | Also covers time-up and pits |
| Power-up | `Player.powered_up` (Player.gd:485, 1402) | |
| Timer tick / bonus | none (plain `Global.time` writes) | Must be polled |
| Score | none (plain `Global.score` writes); ~45 direct static increments of `DiscoLevel.combo_amount` across enemies/items | |

### 2.4 Mode precedents

- **Boo Race:** `BooRaceMenu` sets the mode and picks a level. A `BooRaceHandler` node *authored into the race level scenes* runs freeze → 3 s countdown → start (BooRaceHandler.gd:35-57) and holds match state in **static vars** (`best_times`, `cleared_boo_levels`, `boo_colour`). It has its own death dictionary entry (reload), level-complete entry (return to menu), pause menu and save keys. The opponent (the Boo) is a scripted entity inside the level, not a player.
- **Disco (All Night Nippon):** runs *ordinary* SMBANN levels with a meta-layer on top. `DiscoLevel` is a node placed in those level scenes that frees itself unless mode is DISCO (DiscoLevel.gd:50-53). State lives in **static vars** (combo, rank, `level_ranks`). Gameplay feeds it through scattered direct static writes (`DiscoLevel.combo_amount += 1` in ~45 places) and the per-level `EndFlagpole`/`CastleBridge` signals. It has a results scene (`DiscoResults`) and its own save key.
- **Challenge:** results scene, `ChallengeModeNodes` frees or keeps level nodes per mode.
- **Marathon / SpeedrunHandler** (autoload): timing, ghost replays. Not relevant to bots.

### 2.5 Other facts carried over from the first draft

- No networking code. HTTP is used only for Level Share Square, GameBanana and the version check.
- No test framework. `testLevel.tscn` / `FlatTest.tscn` are manual sandboxes.
- CI (`.github/workflows/feature-build.yml`, manual trigger) pins Godot 4.4 while `project.godot` declares 4.6.
- Autoloads (project.godot): ModLoaderStore, ModLoader, NewLevelBuilder, Global, Settings, SaveManager, DiscordManager, AudioManager, BetterTerrain, GameBanana, SpeedrunHandler.
- `Fire.gd` power state appears unused. `StoryPauseOptionHandler.gd` is orphaned. `EndlessLevel` is an unfinished stub.

---

## 3. Reassessment of the first draft's "blockers"

Classification:
- **Battle blocker:** Battle Mode cannot behave correctly without addressing it.
- **Battle integration task:** ordinary wiring a new mode needs; not a structural obstacle.
- **Local-MP only:** matters only for several real players. **Irrelevant to Battle Mode.**
- **Hygiene:** pre-existing issue, independent of Battle Mode.

| # | First-draft item | First draft said | Reclassified | Reason |
|---|---|---|---|---|
| 3.1.1 | Extra players never spawned | Critical | **Local-MP only** | Bots are not `Player` nodes. One baked-in player is exactly what Battle needs. |
| 3.1.2 | Shared global economy (score/coins/lives/time) | Critical | **Not a blocker** | These globals become contestant 0's state, which is correct. Bots keep their own fields in `BattleSession`. |
| 3.1.3 | Death reloads the world | Critical | **Battle blocker (small)** | Per-player respawn is irrelevant. The real issue: with no BATTLE entry in `death_load()`, a death falls through to `default_reload`. Lives are not decremented outside CAMPAIGN/MARATHON, so the player would retry indefinitely instead of being KO'd. Fix: one dictionary entry. The tree pause during the death animation is harmless (bots pause too). |
| 3.1.4 | `damage()` has no attacker | Critical | **Local-MP only** (for now) | Bots never touch the player physically. KO attribution between contestants lives in `BattleSession`. If sent enemies are added later, the sender is stored on the spawned enemy or in the session, not in `Player.damage`. |
| 3.1.5 | Projectiles have no owner | Critical | **Local-MP only** | PvP physics only |
| 3.1.6 | Camera follows a single leader | Critical | **Local-MP only** | One player, one camera |
| 3.1.7 | Single HUD | Critical | **Not a blocker** | The HUD stays contestant 0's HUD. Battle info (alive count, placement) is a separate overlay, deferred past the first slice. |
| 3.1.8 | `A8` entity ID / `PlayerStartMarker` / checkpoints move all players | Critical | **Local-MP only** | |
| 3.2 | Static `Player` vars, ~30 `get_first_node_in_group("Players")` | High | **Local-MP only** | Correct with one player. They also make finding contestant 0 trivial. |
| 3.3 | Missing `move_down_2/3`, hard-coded `jump_0`, single-player bindings | Medium | **Local-MP only** | |
| 3.4 | Player collision layers, PvP via Hitbox, shells hurt players, pit rule, per-player power-up spawn | Medium | **Local-MP only** | The power-up spawn is gated on `connected_players > 1`, which stays 1. |
| 3.5 | Unused `Fire.gd`, orphan `StoryPauseOptionHandler`, `EndlessLevel` stub, `ChallengeModeHandler` placement | Low | **Hygiene** | |
| §4 | `GameMode` + `game_mode_strings` must stay in sync | — | **Battle integration task** | Append `BATTLE` to both, at the end, to keep existing indices stable |
| §4 | Level-complete dispatch | — | **Integration task** (probably no change for the slice) | The default branch already advances to the next campaign level. Note that it calls `write_save()` (see below). |
| §4 | Pause menu dispatch | — | **Integration task** | Falls back to `StoryPause`. Acceptable for the slice, but its options must be checked (e.g. that it cannot save campaign progress). |
| §6 | Save / achievements string | — | **Integration task** | `write_save` under BATTLE writes no mode keys (`_: pass`) but still rewrites the campaign's save file. Must be verified not to alter campaign progress. Achievements: none for the slice. |
| §7 | No networking | — | **Out of scope** | Consistent with the settled design |
| §7 | No test framework | — | **Integration task** | `BattleSession` can be designed to be tested headless (§4.1) |
| §7 | CI Godot version mismatch | — | **Hygiene** | |

**Net result:** the only true Battle blocker is the death outcome. Everything else Battle needs is ordinary mode wiring plus a new, self-contained session object. None of it requires touching the player controller, camera, input map or collision setup.

### Actual gaps Battle Mode does have (new)

1. **No home for match state that survives scene changes.** Levels, sub-rooms and the transition screen are separate scenes. A precedent exists: Boo Race and Disco both keep state in static vars.
2. **No timer-change or score-change signals.** `Global.time` must be polled. Not needed for the first slice.
3. **The enemy-defeat signal is noisy.** Multi-hit Goomba stomps double-count, there is no killer, and coverage depends on the subclass. That is fine for statistics; it needs tightening before kills drive gameplay (time bonuses or enemy sending).
4. **Mode-gated level nodes need scene edits.** The Disco/Boo-Race pattern places a handler node inside level scenes. Battle runs on *any* stock level, so it needs a way to attach its handler without editing every level scene (§4.3).

---

## 4. Recommended architecture

### 4.1 Components

```
BattleSession   (RefCounted, pure data + rules, no scene access)
 ├─ config: BattleConfig       (tunables: contestant count, tick rate, seed, hazard curve)
 ├─ rng: RandomNumberGenerator (seeded once per match)
 ├─ contestants: Array[Contestant]   (index 0 = real player, 1..34 = bots)
 ├─ tick_count, alive_count, finished, winner_id
 ├─ step()                     advance all bots one fixed step
 ├─ report_*()                 inputs from the real player (see §4.5)
 └─ resolve_to_end()           fast-forward bots after contestant 0 is KO'd

Contestant      (RefCounted or Dictionary-like inner class; plain fields only)

BotSimulator    (static functions or a small class: the bot step rules)

BattleHandler   (Node; the only piece that touches the scene tree)
 ├─ owns the fixed-step clock and calls session.step()
 ├─ connects to Player / Level / Enemy signals and forwards them as report_*()
 └─ on match end: hands off to results / title
```

Key properties:

- **`BattleSession` never reads the scene tree.** All engine information arrives through `report_*` calls from `BattleHandler`. That keeps the simulation deterministic, and it can be unit-driven from a headless Godot script without a test framework.
- **Held in a static var** (e.g. `static var current: BattleSession` on a `Battle` class). This follows the BooRaceHandler/DiscoLevel precedent for state that must outlive scene transitions. It needs no new autoload and no project-settings change.
- **`BattleHandler` is recreated per level scene and reattaches** to `BattleSession.current`. It must be idempotent, because `Level._enter_tree` also runs for sub-rooms.

### 4.2 Contestant state

| Field | Type | Slice? | Bots | Contestant 0 (real player) |
|---|---|---|---|---|
| `id` | int 0-34 | yes | | |
| `is_bot` | bool | yes | true | false |
| `alive` | bool | yes | sim | `false` on `Player.dead` |
| `ko_tick` | int (-1 = alive) | yes | sim | tick when KO reported |
| `ko_cause` | enum {NONE, HAZARD, TIME, PIT, ENEMY, FORFEIT} | yes | sim | mapped from `last_damage_source` / time-up |
| `ko_by` | int contestant id, -1 = environment | field yes, always -1 | reserved | reserved |
| `placement` | int (0 = undecided, 1 = winner) | yes | set at KO / end | same |
| `levels_cleared` | int | yes | sim | `+1` on level complete |
| `progress` | float 0..1 within current level | yes | sim | slice: 0 or 1. Later: player x / goal x |
| `time_left` | int seconds | yes | sim, reset per level | mirror of `Global.time` (read when reporting) |
| `power` | int 0 small / 1 big / 2 fire | yes (cheap) | sim; absorbs one hazard | from `powered_up` / `damaged` (later) |
| `skill` | float 0..1 | yes | seeded once | n/a |
| `pressure` | float | derived only | computed each step | later |
| `incoming` | int queued enemies | field yes, always 0 | reserved | reserved |
| `target_id` | int, -1 = none | field yes, always -1 | reserved | reserved |
| `enemies_defeated` | int | optional | sim (abstract) | from `Enemy.killed` |

Reserved fields exist so later features (enemy sending, targeting) don't change the record shape. They are not interpreted in the slice.

### 4.3 How the handler is attached (no level-scene edits)

Recommended: in `Level._enter_tree`, beside the existing `connected_players` hook (LevelClass.gd:116-117), add the handler when `current_game_mode == BATTLE` and none is present. This is one guarded line in one file, and it works for every stock level.

Rejected alternatives:
- Placing a node in each level scene (the Disco pattern): too many scenes.
- A new autoload: needs a project-settings change.
- Hosting it in `GameHUD`: mixes concerns.

### 4.4 Bot progress without hidden game copies

Each bot is a tiny stochastic model stepped on a fixed clock.

- **Clock:** `BattleHandler` accumulates unpaused `delta` and calls `session.step()` once per fixed step (recommend 1 step = 1 game second, matching the SMB timer). Frame rate affects only *how many* steps run, never outcomes. The handler's `process_mode` is pausable, so bots freeze with the pause menu and during the death animation. It does **not** depend on `Global.can_time_tick`, so `time_limit >= 999` levels still progress bots.
- **Per step, for each alive bot in id order:**
  1. `time_left -= 1`. At 0 → KO (TIME).
  2. `progress += base_speed * lerp(0.7, 1.3, skill) * noise` (noise from the session RNG).
  3. Hazard roll: `p = base_risk * lerp(1.6, 0.4, skill) * escalation(tick) * (1 + pressure)`. On a hit: if `power > 0`, then `power -= 1`; otherwise KO (HAZARD).
  4. When `progress >= 1`: `levels_cleared += 1`, `progress = 0`, `time_left = level_time` (default 300), and a small seeded chance of `power += 1` (max 2).
- **`escalation(tick)`** rises slowly with match time, so every match ends. This plays the role of the original game's growing pressure and caps match length. Tune it so a median match lasts roughly 8-15 minutes.
- **Determinism:** one RNG seeded at match start (store the seed), fixed iteration order, integer tick counter. The same seed and the same sequence of real-player reports give the same result.
- **Plausibility knobs** (later, data only): per-world difficulty table, skill distribution, and a "catch-up" bias that keeps bot progress near the player's so the field feels contemporaneous.

### 4.5 Real-player events that feed `BattleSession`

| Event | Hook (existing) | Session call | Slice? |
|---|---|---|---|
| Match start | menu selection | `BattleSession.new(config, seed)` | yes |
| Level start (fresh) | `Level._enter_tree` with `first_load` true, via the handler's `_ready` | `report_level_start(world, level, Global.time)` | yes |
| Level complete | `Global.level_complete_begin` | `report_level_complete()` → contestant 0 `levels_cleared += 1` | yes |
| Death (incl. pit, time-up) | `Player.dead` + `last_damage_source` / `Global.time == 0` | `report_ko(0, cause)` → set placement → `resolve_to_end()` | yes |
| Timer value | poll `Global.time` on each step | `report_time(Global.time)` | optional (display only) |
| Timer bonus | none (ClockItem writes directly) | n/a; poll covers it | no |
| Enemy defeated | `Enemy.killed`, connected via `get_tree().node_added` for `Enemy` nodes (no enemy-script edits) | `report_enemy_defeated()` | optional, stats only. Fix Goomba double-count before gameplay uses it |
| Damage (power-down) | `Player.damaged` | `report_power(0, new_power)` | no |
| Power-up | `Player.powered_up` | `report_power(0, new_power)` | no |
| Incoming enemies | none (new feature) | `session.incoming[0]` drained by a spawner | no (later) |

The slice needs only **start, level start, level complete and death**. Everything else is additive.

### 4.6 Match lifecycle and ranking

1. Battle menu → seed → `BattleSession.current = BattleSession.new(...)` → `current_game_mode = BATTLE` → load 1-1 of the chosen campaign. The slice can reuse the campaign start path with a different mode value.
2. Per level: the handler attaches and steps the bots, and the player plays normally.
3. **Placement rule:** when one or more contestants are KO'd in the same step, they take placements `alive_before .. alive_before - n + 1`. Ties are ordered by `levels_cleared`, then `progress`, then lower `id`. Contestant 0 gets no special tie advantage.
4. **Player KO:** contestant 0 gets its placement immediately. Then `resolve_to_end()` runs `step()` in a loop until at most one contestant is alive, with a hard cap (e.g. 20,000 steps). At the cap, the survivors are ranked by the tie rule. The winner gets placement 1.
5. **Player is last alive:** match won, placement 1.
6. **Player clears the campaign's final level while bots remain:** end the match and rank the remaining contestants by the tie rule. This edge case is unlikely within the escalation curve.
7. **Exit:** the slice prints or logs the ranking and returns to the title screen. A results screen comes later.

### 4.7 Mode integration (minimal touch list)

| Site | Change | Slice? |
|---|---|---|
| `Global.gd:193,195` | append `BATTLE` / `"Battle"` | yes |
| `Player.death_load()` dict | `BATTLE` entry: report the KO and route to the end of the match. No reload, no lives. | yes |
| `LevelClass._enter_tree` | attach `BattleHandler` when mode is BATTLE | yes |
| Title-screen `ChallengeOptions` (or `Options2`) | add a "Battle" entry and a handler method in `TitleScreen.gd` | yes |
| `transition_to_next_level` | none if the default path is acceptable. Verify `write_save()` under BATTLE does not alter campaign progress. Otherwise skip saving for BATTLE. | verify |
| `GameHUD.activate_pause_menu` | none (falls back to StoryPause). Verify it offers no save or continue options that leak campaign state. | verify |
| `SaveManager` | none in the slice. Battle stats later get a new key. | no |

**Do not** set `connected_players`, add input actions, instance extra `Player` nodes or change collision layers.

---

## 5. Smallest first vertical slice

**Goal:** prove that a Battle match can start, run a normal level with 34 simulated opponents in data, and end with a deterministic ranking. Classic play is unchanged.

**In scope**
1. `GameMode.BATTLE` + `"Battle"` string, appended at the end.
2. One menu entry that starts a Battle match on the standard campaign's first level.
3. `BattleSession`, `Contestant`, `BotSimulator` and `BattleConfig`, as described in §4.1-§4.4.
4. A `BattleHandler` attached at runtime by `Level._enter_tree`. It runs the fixed-step clock and wires the four required events (§4.5).
5. A `death_load()` BATTLE branch: KO contestant 0, resolve the match, log the ranking, return to the title screen.
6. Debug visibility only: `print` / `Global.log_comment` of alive count and final ranking. Optionally a single debug label behind a debug flag.

**Out of scope:** enemy sending, targeting, an opponent grid or overlay HUD, kill-time bonuses, power reporting, a results screen, save data, achievements, advanced bot AI, custom-level support and networking.

**Acceptance criteria**
- Story/Challenge/Marathon/Boo Race/Disco behave exactly as before. Spot-check: death reload in CAMPAIGN and campaign save contents before and after a Battle run.
- Starting Battle loads 1-1 with normal controls. `BattleSession.current` has 35 contestants and contestant 0 is the player.
- Bots lose time, progress and get KO'd over time. The alive count decreases monotonically.
- The real player's death or time-up ends their run with a placement, and the match resolves to a single winner in data.
- Re-running with the same seed and the same player outcome gives the same ranking.

**Verification:** manual play, plus a headless script (`godot --headless --script ...`). The script builds a `BattleSession` with a fixed seed, reports a scripted player timeline and asserts that placements are a permutation of 1..35 and are reproducible. No test framework is needed.

**Expected file touches (for estimation only):** new `Scripts/Classes/Battle/*.gd` (3-4 files). One-to-few-line edits in `Global.gd`, `Player.gd` (death dict), `LevelClass.gd` (handler attach) and `TitleScreen.gd` / `TitleScreen.tscn` (menu entry).

---

## 6. Later phases (ordered, not committed)

1. **Visibility:** alive counter and placement overlay (own CanvasLayer); results screen modelled on `DiscoResults` / `ChallengeModeResults`.
2. **Player fidelity:** power reporting, approximate `progress` from player x and goal x, a timer mirror.
3. **Kill economy:** de-duplicate the enemy-defeat signal (multi-hit Goomba). Kills grant time to contestant 0, and bots gain abstract kills.
4. **Enemy sending and targeting:** `incoming` queues, `target_id` policy, `ko_by` attribution, and a spawner that injects enemies near the real player. Sent enemies carry a sender id in session data.
5. **Bot plausibility:** per-level difficulty data, skill distribution, catch-up behaviour.
6. **Persistence:** best placement / wins under a new save key with `.get(key, default)` loading.

## 7. Open questions

- Should the player's survival use the stock per-level SMB timer (as in the slice), or a single match-long timer with kill bonuses like the original game? This changes how `time_left` is defined for everyone.
- Which campaign or level sequence should Battle use: always SMB1 from 1-1, a curated rotation, or player choice?
- Should reaching the end of the campaign win the match outright?
- Should bot skill be uniform-random or follow a fixed distribution (a few strong bots, a long weak tail)?
