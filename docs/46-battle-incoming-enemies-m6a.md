# 46 — Battle: physical incoming enemies, milestone M6a (what was built and verified)

Status: implemented on top of `1d1e7a6`, following the approved architecture in doc 45 with the decisions given for M6a. An ACTIVE attack aimed at the real
player now becomes one real Goomba or Koopa in the real 256x240 GameViewport, at a safe spot. It is the game's own enemy with the game's own behaviour, and
its real fate resolves exactly that attack. There is no new visual: incoming enemies look like native ones, and the strip only gained a `spawned` field.

The rule is unchanged. **`BattleSession` decides what attacks exist. `BattleIncomingSpawner` materialises them. The real enemy's fate reports back to the
session.** The spawner never creates, targets, orders or times out an attack, and `Enemy.gd` gained one argument and no authority.

Decisions applied: **R0** (an incoming enemy's death resolves its attack and never sends). **Carry** (an ACTIVE attack that never spawned survives a
transition). **Bonus rooms** get deliveries when a safe spot exists, otherwise the attack is held and carried. **No visual distinction.** The doc 45 constants are
used unchanged (1.5 s grace, 1.0 s gap, strict order, the session's `MAX_ACTIVE` = 3 as the only cap), with one fix found by the GL test (section 9).

## 1. Files

| File | Change |
|---|---|
| `Scripts/Classes/Battle/BattleIncomingSpawner.gd` (new) | The per-level bridge (Node, child of `BattleHandler`): reconcile, despawn detection, delivery, live physics probes |
| `Scripts/Classes/Battle/BattleIncomingPlan.gd` (new) | Pure pacing and bookkeeping: strict order, grace, gap, retry, hold, relax |
| `Scripts/Classes/Battle/BattleSpawnPlacer.gd` (new) | Pure placement rule over two probe callables |
| `Scripts/Classes/Battle/BattleEnemyFactory.gd` (new) | Kind → the game's prefab, PackedScene cache, the game's spawned-entity metas, parenting |
| `Scripts/Classes/Battle/BattleEnemyType.gd` | A `prefab` column (`Goomba.tscn`, `GreenKoopaTroopa.tscn`) and `prefab(kind)` |
| `Scripts/Classes/Battle/BattleAttribution.gd` | `ORIGIN_META`, `tag_incoming`, `origin_of`, `is_incoming` |
| `Scripts/Classes/Battle/BattleAttack.gd` | `spawned_tick` (in `to_dict`) |
| `Scripts/Classes/Battle/BattleAttackSystem.gd` | `mark_spawned`, `resolve_all(..., spawned_only)`, `note_incoming_kill` / `incoming_kill_sources`, `resolve_incoming(..., extra)`; snapshot carries both |
| `Scripts/Classes/Battle/BattleSession.gd` | `uid`; `EventType.INCOMING_SPAWNED` (appended); `report_player_incoming_spawned`; `resolve_player_spawned`; `report_enemy_kill(..., origin)` and `report_incoming_kill` |
| `Scripts/Classes/Battle/BattleHandler.gd` | Creates the spawner in `_ready` (attacks on, `BattleIncomingSpawner.enabled`); `_exit_tree` resolves only spawned attacks (`resolve_player_spawned`) |
| `Scripts/Classes/Entities/Enemy.gd` | `report_battle_defeat` passes `BattleAttribution.origin_of(self)` (Battle branch only) |
| `Scripts/Classes/Battle/BattleAttackPresentation.gd` | Reads `INCOMING_SPAWNED`; `player_incoming()` rows carry `spawned` |
| `Scripts/Classes/Battle/BattleScreen.gd` | The pause fix (`presentation_held()`); clears the factory cache with the other Battle caches |
| `tests/battle_incoming_plan_test.gd`, `tests/battle_incoming_game_test.gd`, `tests/battle_incoming_render_test.gd` (new) | Section 11 |
| `tests/tools/battle_incoming_bench.gd` (new) | Section 12 |
| `tests/battle_attack_game_test.gd`, `battle_attack_screen_test.gd`, `battle_attack_render_test.gd` | Switch the spawner off (they test the session API or the view alone); the transition check follows the new rule |

No change to Goomba.gd, KoopaTroopa.gd, ShellClass.gd, any prefab, LevelClass.gd, Player.gd, the camera or the level scenes.

## 2. Session changes

* **`BattleSession.uid`**: a per-program counter assigned in `_init`, so 1, 2, 3, and so on. It is not part of `snapshot()`, so twin sessions still compare equal.
* **`BattleAttack.spawned_tick`**: -1 until the attack's one enemy is in the level. This is the only new state, and it separates *ACTIVE-arriving* from *ACTIVE-in-level*.
* **`report_player_incoming_spawned(seq) -> bool`** (→ `BattleAttackSystem.mark_spawned`) sets `spawned_tick` once and logs `INCOMING_SPAWNED` (id = 0, a = seq, b = sender, kind).
  It refuses, with nothing changed, an unknown seq, an attack aimed at a bot, a QUEUED or RESOLVED attack, an attack already spawned, and a closed round. **One seq can never count as two enemies.**
* **`resolve_player_spawned(cause) -> int`**: resolves ACTIVE attacks on the player whose enemy has spawned. ACTIVE-unspawned and QUEUED attacks stay, in order.
  `BattleHandler._exit_tree` uses it with `LEVEL_TRANSITION`. `resolve_player_active` (every ACTIVE attack) is kept for tools and tests.
* **`report_enemy_kill(script_path, source, origin := PackedInt64Array())`**: an empty origin means a native enemy, handled exactly as in doc 43. A non-empty origin goes to `report_incoming_kill`, which:
  * counts the kill in `attacks.incoming_kill_sources` (`defeat_sources` stays "native kills");
  * resolves the attack only if the uid is this session's, and the attack is aimed at the player, ACTIVE, spawned, and its sender and kind match the tag. The cause is `DEFEATED_BY_PLAYER` for a `PLAYER` source, otherwise `OTHER`, and `INCOMING_RESOLVED` carries `source`;
  * otherwise treats it as **residue** (its attack already ended) or **stale** (another round's) and only counts it;
  * **never** records an `ENEMY_DEFEATED`, never sends, and never draws from `player_rng` (R0).
* The overall state machine (QUEUED → ACTIVE → RESOLVED, causes, `MAX_ACTIVE`, timers for bots) is unchanged.

## 3. Identity (the tag)

`battle_incoming` metadata on the enemy node, the value-type `PackedInt64Array([session uid, seq, sender, kind])`.
`BattleAttribution.tag_incoming(node, uid, seq, sender, kind)` sets it. `origin_of(node)` returns a **copy**, or an empty array for a native or malformed tag.
It is set before the node enters the tree, survives every state change, and is copied by `Node.duplicate()`, so the Koopa that wakes from a shell carries the same value.
The 4th field (kind) goes beyond doc 45's three and is cross-checked against the attack.

## 4. Factory

`BattleEnemyFactory.warm()` loads both prefabs when the spawner starts, so no `load()` lands on a spawn frame (`is_warm` is tested). `create(kind, direction)` instantiates the prefab unchanged and
sets the two metas the game's own runtime spawners set (`BlockClass.dispense_item`, `PipeGenerator`):
* `block_item`: the `LevelPersistance` component frees itself, so a recorded defeat at the same position cannot delete the enemy on arrival, and nothing restores it.
* `no_persist`: its defeat is never recorded.

`add(node, level, global_pos)` puts it under the level's `Enemies` node (or the level itself, e.g. 1-1a has none), positioned **before** it enters the tree, then calls `reset_physics_interpolation()`.
AI, collision, animation, gravity, on-screen enabling and every death path are the prefab's own. The cache is cleared in `BattleScreen._exit_tree`.

## 5. Placement (`BattleSpawnPlacer`)

The rule from doc 45 section 8, pure, with two probes. Live, these are point queries on mask 2 (tiles, blocks, pipes) and shape queries on the enemy and shell layers (16|32), in the GameViewport's own world.
In order, the first candidate that passes wins:
1. **Ahead first**: columns from the last one fully inside the right edge toward Mario, while the centre is at least **80 px** ahead. The enemy faces Mario.
   **Behind** only if ahead finds nothing: columns from the left edge, at least **112 px** behind, facing right.
2. **A floor**: a solid cell with two empty cells above it (so no terrain in the body), its surface between view top + HUD band (32) + 32 and view bottom.
   Of several floors, the nearest to Mario's feet. **A column with no floor (a pit) is skipped.**
3. **Footing**: the next column toward Mario has a floor at the same height.
4. **Clearance**: no enemy or shell body in the box above the spot, no live incoming enemy within 32 px on that floor, and no overlap with Mario's body (checked explicitly too, since Mario's body is on no physics layer).

No candidate → a failure with a reason (`no column far enough from Mario`, `no visible floor`, `no footing`, `blocked`). Nothing spawns; the attack is held (section 6).
After 3 s of holding, the relaxed rule applies (48 / 80 px, no footing). A floor, visibility and clearance are still required. Inside the view is required: beyond the edge the game would freeze the enemy.
On 1-1's start screen the spot is x = −8, 200 px ahead of Mario. In 1-1a it is (104, −32), on the floor in the fixed view.

## 6. Pacing (`BattleIncomingPlan`)

* **Strict order**: only the lowest pending seq can be due. A later attack never goes first, even while the earliest cannot be placed.
* **Grace**: nothing spawns until **1.5 s** after the level first became deliverable. This is per level/room and does not restart on a brief interruption.
* **Gap**: at least **1.0 s** between spawns, so a burst of three arrives at +0 / +1 / +2 s and never two in one frame.
* **Deliverable**: Mario in `Normal`, `WallSlide` or `Climb`, not dead, not in a cutscene, the level not completing, the player still in, the round open.
* **Retry** every 0.25 s while held; **relax** after 3 s.
* **Nothing dropped**: an attack leaves `pending` only when it is spawned or no longer ACTIVE.
* **Cap**: only ACTIVE attacks spawn, and each seq once, so at most `MAX_ACTIVE` (3) are ever live. This is checked every frame (`push_error` if exceeded, never seen) and in tests. There is no extra cap.

The clock is the spawner's sum of physics deltas: it stops with the game (pause, pre-round, death, win) and is deterministic under a fixed frame rate.

## 7. Physical outcome → resolution

| Real outcome | Detected by | Cause |
|---|---|---|
| Stomp, star, hammer, the player's fireball, a player-kicked shell, a player-bumped block | the enemy's own kill path → `report_enemy_kill(..., origin)` | `DEFEATED_BY_PLAYER` (`source` on the event) |
| Killed by anything else (another enemy, an unkicked shell, a hazard, `die()`) | the same path | `OTHER` |
| Fell into a pit | bridge: feet below the view bottom + 8 | `DESPAWNED` (freed by the bridge) |
| Left behind by the camera | bridge: body fully left of the view (8 px) for 0.5 s (6 s with back-scroll) | `DESPAWNED` (freed) |
| Ran off ahead | bridge: body fully right of the view for 6 s | `DESPAWNED` (freed) |
| Vanished without a kill report | bridge: invalid / out of the tree / queued for deletion while ACTIVE, level not completing | `DESPAWNED` |
| A level or room transition (flag, castle, pipe, round restart) | `BattleHandler._exit_tree` → `resolve_player_spawned` | `LEVEL_TRANSITION` (spawned only) |
| The player is eliminated (death, time) | the session, as before | `TARGET_OUT` (all) |
| The round ends (win, match finished) | the session, as before | `ROUND_ENDED` (all) |

The bridge uses camera geometry, never notifier signals, so it behaves the same headless and under GL. Every kill path reports before it frees, so "gone while ACTIVE" is never a kill.
**No timer resolves a spawned attack.** The no-re-send rule is explicit in the session (`report_incoming_kill` has no send path) and tested on every real kill path and over whole simulated matches.
Native enemies still send exactly as before.

## 8. Koopa and shell; transitions and bonus rooms

* **Koopa**: the attack resolves when the Koopa becomes a shell (`summon_shell` → `report_battle_defeat`, the existing native moment), once. The shell is an ordinary untagged shell, never tracked and never sendable.
  Kicked by the player into a **native** Goomba, it gives a **native send** (doc 43 attribution). Into an **incoming** Goomba, that attack resolves and nothing is sent.
  The Koopa that wakes from it carries the tag. Its attack is already RESOLVED, so stomping it resolves nothing and sends nothing (counted as residue), and the spawner never takes it back.
* **Transitions**: a spawned ACTIVE attack → `LEVEL_TRANSITION`, and its node goes with the level. An ACTIVE-unspawned attack stays ACTIVE in its place in the order and is delivered first in the next level or room, once. QUEUED attacks are unchanged.
  Ten transitions in a row do not erase an attack that never appeared (pure test).
* **Bonus rooms**: 1-1a is a separate scene with its own handler and spawner bound to the same session. Through the real pipe path (`Player.enter_pipe`), a Goomba spawned in 1-1 resolves `LEVEL_TRANSITION`.
  A Koopa still arriving is carried into 1-1a and delivered there, on the floor in view. On the way back it resolves `LEVEL_TRANSITION` with the room. With no safe spot, the attack is held and carried.

## 9. Death, round end, Quit, Classic; the pause fix

* **Death / timeout / win**: the session resolves everything (`TARGET_OUT` / `ROUND_ENDED`). The tree is paused or the window frozen, so the bridge stops.
  Spawned nodes are freed with the level when the next round replaces it. Tested: after a win and after a real contact death, no node in the whole tree carries an earlier uid's tag, and the new round has a new spawner, a new uid and an empty map.
* **Quit**: the session is cleared and the level freed; no tagged node is left (tested).
* **Classic**: no `BattleHandler`, so no spawner (tested). `Enemy.report_battle_defeat` returns at its mode check before reading the tag. A hand-tagged Goomba killed in Classic, with a stale session object around, reports nothing (tested).
* **Pause fix** (doc 44 §12.8): `BattleScreen` advances the attack presentation by `0` while `presentation_held()`, which is `get_tree().paused or game_frozen`.
  That is exactly when the Battle clock stops (pause menu, death and power-up freezes, pre-round, win hold). Tested with the real pause menu: 1.5 s paused leaves the presentation clock, the line's travel and the Battle tick unchanged, and closing resumes from there.
* **The edge margin fix**: doc 45 used 16 px. Under GL the game's on-screen enabler freezes a Goomba as soon as its 20 px notifier rect leaves the view, about 10 px past the edge. A 16 px threshold was never reached, so a left-behind Goomba would have held a slot forever.
  The margin is now the body's half width (8 px). The GL test caught this; headless cannot, because nothing freezes there.

## 10. Exposed for M6b

`player_incoming()` rows now carry `spawned`, and `INCOMING_SPAWNED` is in the log. That is all the strip needs to draw "arriving" apart from "in level". Nothing draws it yet.

## 11. Tests

| File | Checks | What |
|---|---|---|
| `tests/battle_incoming_plan_test.gd` (pure) | 95 | **Plan**: pending = ACTIVE-unspawned in seq order; grace; gap; a burst at grace / +1 / +2 s; nothing due right after a spawn; not deliverable holds without loss; grace is per level; retry; strict head-of-line; relax after 3 s; a seq is never due twice. **Placer** on ASCII maps: right edge; behind at a camera limit; ≥ MIN_AHEAD; pits skipped; footing; pipe top yes / inside no; headroom; HUD band; occupied → next column; separation; no spot → a reason; relaxed; nearest floor; never on Mario; 1,000 random maps twice (determinism) with every spot a visible floor with footing at distance. **Session**: the spawn-report accept / refuse matrix and event; the transition rule (spawned resolve, unspawned carry, ten transitions); the R0 kill routing (PLAYER → `DEFEATED_BY_PLAYER`, others → `OTHER`, no send / defeat / stream draw, residue, stale uid, mismatched sender / kind, unspawned, malformed); the tag (format, duplicate, copies, malformed); uid not in the snapshot. **Whole matches** (12, bots sending, random outcomes and transitions): the plan's pending list equals the session's ACTIVE-unspawned list at every frame, no double spawn, every attack ends with a real cause, none that never appeared ended by a transition, R0 holds. **Presentation**: a held clock freezes a line, which then resumes; `spawned` in the strip rows |
| `tests/battle_incoming_game_test.gd` (real game, headless) | 83 | Wiring and preload; a Goomba: nothing while QUEUED, exactly one real `Goomba.tscn` once ACTIVE, its identity, parent, metas, log and event, in view below the HUD, 200 px ahead facing Mario, on a real floor with no terrain, enemy or Mario overlap, walks 32 px/s on the floor, no timer, a stomp resolves it with no send, then residue; a Koopa: exactly one, the stomp resolves it once with no send, an untagged shell, the kicked shell's native send, the kicked shell resolving an incoming Goomba without a send, wake → tagged residue that resolves and sends nothing; three in seq order ≥ 60 physics frames apart, the fourth waits (3 live max) and arrives in order after a kill; no spot (every floor occupied) → held with retries, delivered once room appears; DESPAWNED when left behind (and freed), in 1-1's first pit, and when vanished; the real pipe into 1-1a and back (spawned → `LEVEL_TRANSITION`, the arriving one carried and delivered in the room, then `LEVEL_TRANSITION` on return); the real pause menu freezes the lines; a win → `ROUND_ENDED` and a clean next round; a real contact death by an incoming Goomba → `TARGET_OUT` and a clean next round; Quit and Classic leave nothing |
| `tests/battle_incoming_render_test.gd` (GL, xvfb) | 12 | The game's own enabler switches the spawned Goomba on (no hook); it is drawn in the game window (mean colour change 0.24 over its cell); it walks 31.5 px/s; a **real physics stomp** (Mario dropped on it) → `DEFEATED_BY_PLAYER`, no send; left behind, the game freezes it and the bridge still despawns and frees it; walking into small Mario it kills him → `TARGET_OUT` |
| Existing Battle suites | | All pass: `battle_attack_test` 167, `battle_attack_view_test` 118, `battle_session_test` 21, `battle_round_test` 49, `battle_screen_test` 111, `battle_hud_test` 51, `battle_preview_atlas_test` 44, `battle_preview_test` 77 (golden attack-free hashes), `battle_attack_screen_test` 56, `battle_round_lifecycle_test` 103, `battle_attack_game_test` 69; GL `battle_attack_render_test` 39, `battle_screen_render_test` 32, `battle_preview_render_test` 24. No script errors in any log |

Commands: `godot --headless --fixed-fps 60 --path . -s tests/<suite>.gd`. GL: `xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 -s tests/battle_incoming_render_test.gd -- pack=SandboxStandIn`.

## 12. Performance

`tests/tools/battle_incoming_bench.gd`: the real path (attacks → spawner), 1-1 start screen, the whole Battle screen, 180-frame windows, two runs each. Headless switches the enemies on by hand (CPU only).

| | No incoming enemy | 1 live | 3 live | Spawn frame (create + tag + add + report) |
|---|---|---|---|---|
| Headless, wall ms / frame | 3.05 / 2.63 | 3.39 / 3.13 | 4.09 / 2.98 | Goomba 1.2–1.6 ms, Koopa 1.6–1.7 ms |
| Spawner's own cost / physics frame | 34–43 µs | 64–68 µs | 72–104 µs | |
| Nodes (whole tree) | 7,970 | +20 (Goomba) | +63 (Goomba + Koopa + Goomba) | |
| xvfb software GL, wall ms / frame | 70–72 | 70–74 | 73–75 | 1.3–2.3 ms (the first instantiate is the slowest) |

An incoming enemy costs what a native one costs (about 0.1–0.3 ms CPU each, run-to-run noise is of the same size). The spawn frame costs 1.2–1.7 ms, always one per frame at most, thanks to the gap. The bridge itself is under 0.11 ms.
Under software GL the frame is rasterisation-bound (about 70 ms) and the enemies are lost in it. No optimisation was needed or made.

## 13. Unresolved risks

1. **Feel is unmeasured.** Incoming enemies now hurt, shrink and kill through native code. Combined with `MAX_ACTIVE` refilling as the player kills them, the difficulty change is real and untuned (constants per doc 45).
2. **Placement beyond 1-1 / 1-1a is untested**: lava floors (not mask 2, so not floors), lifts, water levels and coin heaven all degrade to "hold, then carry", which is safe but may hold for long stretches.
3. **The Player→bump tag** (doc 43) is still only source-checked. That does not affect this milestone.
4. **The bridge's idle cost** is about 35–80 µs per physics frame (rows are copied every frame). It is small, but it is paid with no attacks too.
5. **SecondQuestReplacer** would swap a Goomba for a Buzzy Beetle and drop the tag. Battle forces `second_quest = false`; if that changes, it shows up as `DESPAWNED`.
6. **A woken Koopa** (residue) is never despawned by the bridge. It is harmless and level-scoped, like a native Koopa.
7. **Headless physical tests** need the `force_process` hook; the true enabler path is only covered by the GL test.
8. **Placement in back-scroll mode** is not specially handled. Left-behind uses the 6 s limit, but placement still prefers ahead.
