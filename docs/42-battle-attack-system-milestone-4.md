# 42 — Battle attacks, milestone 1 (authoritative send / receive): what was built and verified

Status: implemented on top of `108d098`. This is the first **authoritative** attack milestone: a contestant defeats an enemy, the enemy is sent to a
surviving opponent, queues there, activates, resolves, and while it is active it makes a simulated bot more likely to be eliminated. There is **no** visual
side to it: no attack lines, no targeting UI, no incoming enemies in the real player's level, no preview animation. (Numbered 42 because docs 38-41 are the
screen, atlas and round-lifecycle docs.) Also in this change: the small round-lifecycle cleanup (pause menu holds the pre-round and results timers, see 9).

## 1. Files

| File (`Scripts/Classes/Battle/`) | Role |
|---|---|
| `BattleEnemyType.gd` (new) | Battle's enemy kinds (`GOOMBA`, `KOOPA`) and their data table: pressure weight, active time, how often a bot defeats it, which game script it comes from |
| `BattleAttack.gd` (new) | One attack: seq, sender, target, kind, ticks, state (QUEUED / ACTIVE / RESOLVED) |
| `BattleAttackSystem.gd` (new) | The whole loop for one round: send, queues, lifecycle, pressure, bot defeat generation, its own random stream. Owned by the session (`session.attacks`), no back-reference |
| `BattleTargeting.gd`, `BattleTargetingRandomSurvivor.gd` (new) | The targeting interface and the one policy |
| `BattleSession.gd` | Five new event types, `attacks`, `report_enemy_defeat`, `report_player_defeat` (the game's entry point), `get_incoming`, `record`; the tick runs the attack lifecycle and bot defeats |
| `BattleBotSimulator.gd` | `step_bot` takes an optional `pressure` (default 0) that scales the hazard |
| `Scripts/Classes/Entities/Enemy.gd`, `Enemies/Goomba.gd`, `Enemies/KoopaTroopa.gd` | The kill hook (see 3) |
| `BattleRound.gd`, `BattleScreen.gd` | The pause cleanup (see 9) |
| `tests/battle_attack_test.gd`, `tests/battle_attack_game_test.gd` (new) | 90 pure checks and 33 real-game checks |

`BattleScreen`, the previews and the layout are not involved: the screen only reads state (`session.get_incoming(id)`) when a later milestone wants it.

## 2. Enemy types

A plain integer enum (`BattleEnemyType.Kind { NONE, GOOMBA, KOOPA }`) and a data table: `{name, script, weight, active_ticks, bot_spawn}`. The game's enemies are mapped to a kind at the
edge by **script path** (`Goomba.gd` -> GOOMBA, `KoopaTroopa.gd` -> KOOPA, which also covers red and winged variants); nothing but an int ever reaches `BattleSession`: no nodes, scenes or
PackedScenes. A shell (`ShellClass.gd`), plants, bosses and everything else map to `NONE` and are ignored. A new enemy type is one enum value, one table row, and (if its game
script overrides the `die` functions without calling the base class) one `report_battle_defeat()` call.

| kind | pressure weight | active for | share of bot defeats |
|---|---|---|---|
| GOOMBA | 0.5 | 5 ticks | 70 % |
| KOOPA | 0.8 | 7 ticks | 30 % |

## 3. The real player's kills

The game reports kills in several places (`Enemy.die`, `die_from_object`, `die_from_hammer`, Goomba's stomp, Koopa's stomp and block hit). They funnel into **one** function:
`Enemy.report_battle_defeat()`.

* The base class calls it from `die()`, `die_from_object()` and `die_from_hammer()`, which covers shell, fireball, star, hammer and Goomba's `damage()`. Goomba's `enemy_death()` (a fatal stomp, either death style)
  and Koopa's `summon_shell()` (a stomp or a hit from below turning it into a shell) call it too: that is two extra lines in two enemy scripts.
* It does nothing unless the game mode is Battle, and it reports **at most once per enemy** (`_battle_defeat_reported`; a Koopa that wakes up from its shell is a fresh object and can be defeated again).
* It passes only the enemy's script path to `BattleSession.report_player_defeat`, which maps it to a kind and sends it for the player. `BattleSession` has no scene dependencies, so `Enemy.gd` does not drag the
  Battle screen into the game's script load order (a first version that called `BattleHandler` from `Enemy.gd` broke the load order of some particle scenes; this form does not).
* A shell kill is not a defeat (the Koopa already counted when it was stomped). Defeats after the player's own death are ignored (an eliminated contestant cannot send).
* Level-end clearing (`flag_die`) and off-screen despawning are not defeats.

Not inferred from visuals or previews; tested by calling each real kill function on real 1-1 enemies inside a running Battle.

## 4. Bots: send generation

No combat simulation. Each tick, after the bots have moved, every bot that is still in and advanced this tick gets one roll: `chance = (levels advanced this tick) x DEFEATS_PER_LEVEL (5)`. A faster bot advances
further, so it defeats and sends more (tested: higher-skill bots send about twice as many). A success picks a kind from the table's weights and sends it through the same path as the player's. Bots that were eliminated
this tick never roll. A full match has about 150 sends (median over 200 seeds) and a bot's expected rate is one defeat every ~18 s of average progress.

## 5. Targeting

`BattleTargeting.choose(session, sender, rng) -> int` is the whole interface; the attack system only ever calls that. `BattleTargeting.eligible()` is the shared starting list: contestants who are alive and not the
sender, in id order, **the real player included**. The one policy, `BattleTargetingRandomSurvivor`, draws uniformly from it with the attack system's random stream. A policy that returns the sender, an eliminated
contestant or -1 is refused (nothing is sent; the defeat is still logged with seq -1). A later mode (attackers, most coins, lowest time, a manual choice) is another subclass; sending, queues and delivery do not change
(tested with a fixed-target policy).

## 6. Events

Appended to `session.events` after the four existing types (their numbers did not change); fields `{tick, id, type, a, b}` plus named extras:

| event | id | a | b | extras |
|---|---|---|---|---|
| `ENEMY_DEFEATED` | the defeater | kind | the attack's seq (-1 if nobody could be targeted) | |
| `SENT` | sender | seq | target | `kind` |
| `RECEIVED` | target | seq | sender | `kind` (the same moment as SENT, from the target's side, so the target's own event stream has it) |
| `INCOMING_ACTIVATED` | target | seq | sender | `kind` |
| `INCOMING_RESOLVED` | target | seq | sender | `kind`, `ko` (true if it ended because the target was eliminated) |

A defeat is always followed by its SENT and RECEIVED on the same tick. Switching attacks off logs none of them. The preview tracks ignore the new types, so previews are unchanged.

## 7. Incoming queues and lifecycle

Each contestant has an authoritative queue of unresolved attacks, in send order. `session.get_incoming(id)` returns **copies** (dictionaries), so presentation code can read the queue but cannot change it
(tested). `attacks.attack_history()` lists every attack of the round, resolved ones included.

Per attack, in session ticks (Battle seconds):

* `QUEUED`: sent. It waits `ACTIVATION_DELAY` (3) ticks. A contestant's attacks always activate in the order they were sent.
* `ACTIVE`: after the delay, if fewer than `MAX_ACTIVE` (3) are active on that contestant (the rest keep waiting, in order). It stays active for its kind's `active_ticks`.
* `RESOLVED`: expired, or its target was eliminated (resolved at once, `resolved_by_ko`). It then contributes nothing.

Order within a tick: the lifecycle runs first (so this tick's bots feel it), then the bots move, then bot defeats are rolled, then eliminations are applied. Multiple incoming enemies are normal (queues hold any number).
What an eliminated sender already sent still arrives; a sender who is out can never send again.

## 8. Bot pressure

`pressure(id)` = the summed weights of that contestant's ACTIVE enemies (capped at 4; the active cap makes the practical maximum 3 Koopas = 2.4). A simulated bot's hazard per second is multiplied by `(1 + pressure)`
in `step_bot`. That is the whole effect: no enemy-by-enemy simulation. With pressure 0 the arithmetic is exactly what it was, so a bot with nothing active behaves exactly as before.

Measured (pure, deterministic): bot of average skill, ticks 40-60, 3000 seeds, share eliminated: **25.7 %** with no pressure, 36.7 % with one Goomba active (0.5), 50.2 % with a Goomba and a Koopa (1.3), 65.2 % with three Koopas (2.4).
With identical random draws, pressure only ever eliminates bots that would otherwise have survived (735 of 3000, none the other way round). Through the whole loop (a sender keeps sending a Goomba or Koopa to bot 5 every 3 s): 131 of 200
seeds eliminate it within 45 s against 87 without, mean life 28.4 s against 34.7 s. Whole matches with attacks on are about 11 % shorter (median 344 ticks against 388 over 200 seeds), and 30 of 30 tested seeds play out differently.

**Randomness.** The loop has its own stream (seeded from the session seed), used for bot defeat rolls, kinds and targets; the bots' own stream is never drawn from. Consequences, both tested: with the system on but nothing sent, a match is bit-identical to the
attack-free one (events, rng state, winner); with it off (`attacks.enabled = false`, or `BattleSession.default_attacks_enabled = false`) the old outcome for a seed is exactly restored. The `battle_preview_test.gd` golden hashes (outcomes of the
pre-event-log code) pin that attack-free model, and that test runs with attacks off.

## 9. The real player as a target

Bots can and do target the player (about 23 sends per match are aimed at them). Those attacks are recorded in the player's queue, activate and resolve like anyone's, and the events (`RECEIVED`, `INCOMING_ACTIVATED`,
`INCOMING_RESOLVED`) are logged for a future UI. **Nothing consumes them:** `pressure()` is only ever used for bots, no enemy is spawned into the player's level (the Enemies group had the same 17 members before and nine seconds after
three attacks went through the player's queue, and the real Mario was neither hurt nor shrunk), and a player under heavy fire has exactly the same time, life and KO cause as with the system off. There is no hidden penalty.

(Also in this change, as requested: while the pause menu is open the pre-round and the results do not run down and the results ignore confirm; closing it resumes them. `BattleRound.paused` is set from `Global.game_paused`; ROUND_OVER and
PLAYING are not affected. The code that closed a pause menu left open over the results is gone: the situation can no longer arise.)

## 10. Rounds and Classic

All attack state lives in `session.attacks`, which is created with the session, so every new round starts with empty queues, no active attacks, sequence numbers from 0, an empty event history, a new default targeting object and a new random stream
(tested in the pure test and across a real round restart). Outside Battle `report_battle_defeat()` returns before doing anything: a Classic Goomba or Koopa defeat creates no Battle state, even when a stale session object exists (tested).

## 11. Tests

| File | What | Command |
|---|---|---|
| `tests/battle_attack_test.gd` (90 checks, pure) | kinds and the plain-data table; one send from a supported player defeat with the right events; targets (never self, never eliminated, player eligible while alive, two left, determinism, a replaceable policy, refused bad policies); event and queue contents and order; the full QUEUED -> ACTIVE -> RESOLVED timeline, the active cap and FIFO, target eliminated; pressure values; bot elimination rates (monotone, coupled draws, the whole loop); bot sends (to bots, to the player, both kinds, faster bots send more, reproducible); the player as a target (recorded, no effect); eliminated senders; enabled / disabled / idle equivalences; round isolation; read-only views | `godot --headless --path . -s tests/battle_attack_test.gd` |
| `tests/battle_attack_game_test.gd` (33 checks, real game) | each real kill path on real 1-1 enemies inside Battle (stomp, object, hammer, fireball-style, plain die, Koopa stomp, Koopa bump), exactly once, shells and post-death kills send nothing, attacks on the player recorded but nothing spawned and the player unharmed, a new round starts clean, Classic kills (with and without a stale session) report nothing | `godot --headless --fixed-fps 60 --path . -s tests/battle_attack_game_test.gd` |
| `tests/battle_round_test.gd`, `battle_round_lifecycle_test.gd` | the pause regression: a pause during PRE_ROUND or RESULTS freezes the round timers and the confirm, closing it resumes them | |
| all other Battle tests | pass; `battle_preview_test.gd` now sets `default_attacks_enabled = false` | |

## 12. Things to settle before the visible attack system

1. **Resolution of the player's incoming enemies must become event-driven.** For everyone, RESOLVED is currently a timer. For the real player a spawned enemy's life is decided by the real game (killed, despawned, hit the player), so the player's
   attacks will need `session.report_incoming_resolved(seq, how)` instead of the timer, and `ACTIVE` for the player will mean "spawn now". The queue shape does not need to change.
2. **The attack random stream is shared by the player's kills and the bots' rolls.** The player's sends happen at wall-clock moments, so a match with a real player is reproducible from the seed *and the player's send times*, not from the seed alone. A separate stream for
   player-originated picks would keep bot-vs-bot sends independent of how the player plays (full independence is impossible: bots die at different times and shift their own stream).
3. **Time resolution.** The loop is in whole Battle seconds. Attack lines and preview indicators will need sub-second interpolation (the previews already do this with `presentation_alpha`).
4. **Pressure is one number per contestant.** A visual enemy-by-enemy representation in a preview will be cosmetic only; if previews ever need the enemy to "hit" the bot, they should react to `HIT`/`KO` events, which still come from the bot model.
5. **Events carry named extras in a dictionary.** Fine for logging; a typed accessor (or a small event class) would be worth adding when several systems read them.
6. **Defeat attribution.** Every enemy killed in the real player's level counts as the player's (a shell the player kicked earlier still counts). That is right for 1-1; with enemies that kill each other independently (bombs, Bowser's hammers) the rule needs a closer look.
7. **Koopa timing.** A Koopa counts when it is stomped into a shell, not when the shell is later destroyed. If shells become a supported type, one of the two must stop counting or a Koopa is sent twice.
8. **Enemies whose scripts override the death functions without the base class** (Wiggler, Podoboo, Barrel) will need an explicit `report_battle_defeat()` call when they are added.
9. **Balance** is untouched on purpose: matches are about 11 % shorter with attacks, and the weights, delays and rates are all constants in `BattleEnemyType` / `BattleAttackSystem`.
