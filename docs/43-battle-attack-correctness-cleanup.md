# 43 — Battle attacks: correctness cleanup (separate random streams, event-driven player incoming, kill attribution)

Status: implemented on top of `9b32252` (doc 42). Three correctness issues that would have become harder to untangle once attacks are visible: the attack loop had **one** random stream shared by the
player's kills and the bots' rolls; an attack against the real player **resolved on a timer** even though a real, spawned enemy's life will be decided by the game; and **every** enemy death in the player's level
counted as the player's. This pass fixes those three and nothing else. There is no new visual, no new enemy type, no targeting mode, and no balance change (rates, weights, delays and durations are untouched).

## 1. Files

| File | Change |
|---|---|
| `Scripts/Classes/Battle/BattleAttackSystem.gd` | Two random streams (`bot_rng`, `player_rng`) replace `rng`; the bot stream is consumed at a fixed rate; ACTIVE attacks on the real player have no timer; `resolve_incoming`, `resolve_all`, `end_round`, `note_kill`; `pressure_enabled` test knob; `player_defeats`, `defeat_sources`, `round_ended`; snapshot carries both stream states |
| `Scripts/Classes/Battle/BattleAttack.gd` | `Resolution` enum and `resolution` field replace `resolved_by_ko`; `defeat_seq` (which defeat of the round it was sent for); `resolution_name()` |
| `Scripts/Classes/Battle/BattleAttribution.gd` (new) | The attribution model: `Source {UNKNOWN, PLAYER, ENEMY, ENVIRONMENT}` and the pure function `of(cause)`; `tag_block_bump` |
| `Scripts/Classes/Battle/BattleSession.gd` | `report_enemy_kill(script_path, source)` replaces `report_player_defeat(script_path)`; `resolve_player_incoming(seq, cause)`, `resolve_player_active(cause)`, `end_round()`; `_finish()` closes the attack loop; `INCOMING_RESOLVED` carries `cause`, `ENEMY_DEFEATED` carries `defeat` |
| `Scripts/Classes/Battle/BattleTargeting.gd`, `BattleTargetingRandomSurvivor.gd` | `choose(session, sender, draw)`: a policy is handed one uniform draw instead of a stream |
| `Scripts/Classes/Battle/BattleHandler.gd` | Remembers the session its level belongs to and ends that session's ACTIVE player attacks when the level leaves the tree (`LEVEL_TRANSITION`) |
| `Scripts/Classes/Entities/Enemy.gd` | `report_battle_defeat(cause)`: the single reporting point now takes what killed the enemy and asks `BattleAttribution` who that is |
| `Scripts/Classes/Entities/Enemies/Goomba.gd`, `KoopaTroopa.gd` | Pass the cause they already have (`enemy_death(player)`; `summon_shell(…, cause)` from the stomp / the block bounce) |
| `Scripts/Classes/Components/BlockBouncingDetection.gd` | `last_block`: the block of the latest bounce, for handlers connected without its argument (the Koopa's) |
| `Scripts/Classes/Entities/Player.gd` | One Battle-only line: tag the block it bumps from below (`BattleAttribution.tag_block_bump`) |
| `Scripts/Classes/Entities/Projectile.gd` | One line: a child of the player's projectile inherits its `IsPlayerProjectile` meta |
| `tests/battle_attack_test.gd`, `tests/battle_attack_game_test.gd` | Updated, and the new tests (section 7) |

Classic and other modes are unchanged: everything above is either Battle-only code, gated on `Global.current_game_mode == BATTLE`, or inert metadata (`last_block`, the inherited projectile meta).
`BattleScreen.gd` needed no change: the round ends through the session finishing or the player being eliminated, and both close the attack loop (section 4).

## 2. Random streams

Three independent deterministic streams exist for a round, all derived from the one Battle seed:

| Stream | Seed | Used for |
|---|---|---|
| `session.rng` (main simulation) | `seed` | contestant setup and the bots' own movement / hazard. **Never drawn from by the attack code**, and unchanged by this pass |
| `attacks.bot_rng` | `seed ^ BOT_SALT` (`0x5DEECE66D`, the old shared stream's salt) | every simulated bot's defeat roll, enemy kind and target pick |
| `attacks.player_rng` | `seed ^ PLAYER_SALT` (`0x2545F4914F6CDD1D`) | the real player's target picks |

**The bot stream is consumed at a fixed rate.** On every tick, each of the 34 bots takes exactly `DRAWS_PER_BOT` (3: defeat roll, kind, target) draws, whether or not that bot is alive, advancing or sending, and then at most one defeat is
made from them. The stream's state is therefore a pure function of the seed and the number of ticks. Nothing the real player does (when or whether they defeat an enemy, whom it goes to, whether they have been eliminated) can shift
any bot's rolls. (A bot defeat reported from outside, as tests do with `report_enemy_defeat(bot, …)`, draws from the bot stream and is not part of that fixed rate; the bots' own defeats all come from `generate_bot_defeats`.)

**The player stream advances once per accepted player defeat** (accepted = attacks on, a supported kind, round not over, the player still alive; whether anyone can be targeted does not matter). Its n-th draw is therefore a
function of the seed and n alone. A defeat that is ignored (not attributable to the player, an unsupported enemy, after the player's death) draws nothing. The bots never touch it.

`BattleTargeting.choose(session, sender, draw)` is handed one uniform `draw` in `[0, 1)` taken from the sender's stream by the attack system; a policy is a pure function of the state and that number and owns no randomness. This is the
only interface change. `BattleTargetingRandomSurvivor` picks `eligible[int(draw * n)]`.

What this does and does not make independent, stated precisely: the *random numbers* a bot sees are independent of the player. What the player **sends** can still change a bot's *state* (an active enemy raises its hazard, which can
eliminate it earlier, which changes who is alive and so what a later draw is applied to). That is gameplay, not randomness, and it is intended. `attacks.pressure_enabled = false` removes it so a test can show the streams alone are
independent (section 7).

Consequence for existing seeds: because the draws are now laid out per bot per tick, a seed's *bot attack sequence* is not the one doc 42 produced (the attack-free outcome is bit-identical, and the attack rates are the same by
construction). Re-measured over 200 seeds: 23.1 sends per match are aimed at the real player (doc 42: about 23), the Goomba / Koopa mix is 70 % / 30 % (bot_spawn 0.7 / 0.3), and the median match is 352 ticks with attacks against
388 without (doc 42: 344 against 388; the difference is the new draw layout, not a rate change).

## 3. Attacks aimed at the real player

Lifecycle, unchanged in shape: `QUEUED` (waits `ACTIVATION_DELAY` ticks, in send order) → `ACTIVE` (at most `MAX_ACTIVE` per contestant) → `RESOLVED`. What changed is who ends an ACTIVE attack:

* **Aimed at a simulated bot:** the deterministic timer, exactly as before. `Resolution.EXPIRED`.
* **Aimed at the real player:** **no timer.** It stays ACTIVE until the real game reports an outcome, the level it is active in ends, the player is eliminated, or the round ends. While three are active a fourth stays QUEUED and
  activates (the next tick) when a slot frees, in order.

`BattleAttack.Resolution` says why an attack ended: `NONE` (not resolved yet), `EXPIRED` (a bot's timer), `TARGET_OUT` (the target was eliminated), `DEFEATED_BY_PLAYER`, `DESPAWNED`, `LEVEL_TRANSITION` (these three are
reported by the game), `ROUND_ENDED`, `OTHER`. The `INCOMING_RESOLVED` event carries `cause`; the old `ko` flag and `resolved_by_ko` are gone (`cause == TARGET_OUT` is the same fact).

The API on `BattleSession`:

| Call | Meaning |
|---|---|
| `resolve_player_incoming(seq, cause) -> bool` | The game reports the outcome of the ACTIVE attack numbered `seq` (the `seq` in the `SENT` / `INCOMING_ACTIVATED` events and `get_incoming`). Returns `true` if it was resolved. Refused (`false`, nothing changed) for an unknown id, an attack not aimed at the real player, one still QUEUED (it is not in a level yet), one already resolved (a duplicate is harmless), a closed round, or `cause` `NONE` / `EXPIRED` |
| `resolve_player_active(cause) -> int` | Resolves every ACTIVE attack on the real player with `cause`; QUEUED ones stay. Used for the level transition |
| `end_round() -> int` | Resolves everything still unresolved, on anyone, with `ROUND_ENDED` and closes the loop |

Nothing in the game calls `resolve_player_incoming` yet: no enemy is spawned into the player's level, so there is nothing for the game to report. The method exists so the visible-attack milestone only has to call it. Until then an
attack ACTIVE against the player stays ACTIVE until the level, the player or the round ends. It has no effect on the player (as in doc 42: no pressure on the player, no hidden penalty, nothing spawned) – tested again.

## 4. Round and level cleanup

* **Level transition.** `BattleHandler` is a child of each level and remembers the session it was created for. When the level leaves the tree (completed, replaced, or the round restarting) it calls
  `resolve_player_active(LEVEL_TRANSITION)` on *that* session, never on whatever session is current by then. QUEUED attacks keep waiting and become active in the next level.
* **The player is eliminated** (death or time out): everything aimed at them ends as `TARGET_OUT`, as for any eliminated contestant. The bots then play the match out as before.
* **The round ends** (the match finishes, e.g. the player wins): `_finish()` calls `end_round()`: every attack still unresolved ends as `ROUND_ENDED`, the loop closes (no sends, activations or resolutions; calling it again is
  harmless). A finished session has no unresolved attack.
* **Nothing leaks into the next round**: a new round is a new session with a new attack system (empty queues, sequence numbers from 0, an open loop, an empty `defeat_sources`).

## 5. Kill attribution

`BattleAttribution.Source`: `UNKNOWN` (the zero value, so anything not set is unknown), `PLAYER`, `ENEMY`, `ENVIRONMENT`.

The real game reports a kill in exactly one place, `Enemy.report_battle_defeat(cause)`, with whatever killed the enemy (the thing its death function was already handed). `BattleAttribution.of(cause)` turns that into a `Source`;
`BattleSession.report_enemy_kill(script_path, source)` counts the kill by source in `attacks.defeat_sources` and **sends an enemy only when the source is `PLAYER`**. No enemy subclass carries Battle logic: Goomba and Koopa only pass
the cause they already had. `of()` recognises nodes by group, metadata and script path (never by class reference), so `Enemy` and the classes it is told about cannot form a dependency cycle.

| Real kill path | What is passed | Source |
|---|---|---|
| Stomp on a Goomba (from above or below) | the `Player` | **PLAYER** |
| Stomp on a Koopa (turns into a shell) | the `Player` | **PLAYER** |
| Star-powered touch (`invincible_player_hit` → `die_from_object`) | the `Player` | **PLAYER** |
| Hammer (`die_from_hammer`) | the `Player` | **PLAYER** |
| Player's fireball / projectile (`FireballDetection`) | the `Projectile` carrying `IsPlayerProjectile` (children of it inherit the meta) | **PLAYER** |
| A shell the player kicked running into it (`ShellDetection`) | the `Shell`; `Shell.player` is the kicker | **PLAYER** if that player still exists, else UNKNOWN |
| A block the player bumped from below bouncing it (Goomba `die_from_object(block)`, Koopa `block_bounced()` via `BlockBouncingDetection.last_block`) | the `Block`, tagged by the player as it bumped it | **PLAYER** if the bump was ≤ `BUMP_FRAMES` (30) physics frames ago, else UNKNOWN |
| Another enemy, including an enemy's projectile | the enemy | ENEMY |
| Spike ball, falling icicle (`IcicleDetection`) | the object | ENVIRONMENT |
| An unkicked shell, an explosion (`ExplosionDetection`), a block nobody was seen bumping, an unrecognised object | the object | UNKNOWN |
| `Enemy.die()` (no cause: Crate-spawned kills, Challenge-mode shell limit) | nothing | UNKNOWN |

**Reliably attributed to the player:** stomp (Goomba, Koopa), star, hammer, the player's fireballs, a shell the player kicked, a block the player bumped (the block case verified from the tag onward on real nodes; the Player's tag line
itself is asserted from the source, see section 8).

**UNKNOWN by design:** `die()` with no cause, explosions (a bomb is not provably the player's), shells nobody kicked, blocks bumped by something other than the player within the window (shells / spike balls hitting blocks are not traced),
and anything `of()` does not recognise. Kills that are not kills at all – an enemy falling into a pit or leaving the active area is despawned, never passes through a death function – are not reported and send nothing.

Other rules, all tested: one enemy reports once and **the first report wins** (an enemy first killed with no known cause cannot be claimed by a later `die_from_object(player)`); a stomped Goomba that then runs `die()`,
`die_from_hammer` and `damage` sends exactly one enemy; shells are not a supported kind, so killing the shell a stomped Koopa left behind is not a second send; a stale session in Classic is never touched.

## 6. Events

`ENEMY_DEFEATED` gains `defeat` (the round's defeat number, also stored on the attack as `defeat_seq`); `INCOMING_RESOLVED` carries `cause` (`BattleAttack.Resolution`) instead of `ko`. Nothing else changed, the send / receive /
activation order is unchanged, and the preview driver and tracks ignore the new fields.

## 7. Tests

| File | New or changed |
|---|---|
| `tests/battle_attack_test.gd` (167 checks, pure) | **Streams:** seeds are `seed ^ salt`, all three streams differ, attack code never touches `session.rng`; the bot stream's state after every tick is identical with and without player defeats (60 ticks), and equals exactly 3 draws × 34 bots per tick; the player stream advances only with the player's accepted defeats; every bot attack (sender, target, kind, tick) is identical over 150 ticks with no player kills, early kills and late kills (pressure off); with pressure on the bot stream still does not move; the player's n-th target is the same for the same seed and defeat sequence (bots sending or not), the n-th *draw* is the same whenever the defeats happen, differs by seed, and does not depend on later defeats. **Player incoming:** QUEUED → ACTIVE in order with the cap; still ACTIVE after 120 ticks, no `INCOMING_RESOLVED`; resolve by `seq` (state, cause, tick, event fields, queue); duplicate / unknown / QUEUED / `NONE` / `EXPIRED` refused with nothing changed; a freed slot activates the next one; bot-targeted attacks keep their timer (`EXPIRED`) and cannot be resolved through the player API, side by side with a player one; elimination → `TARGET_OUT`. **Cleanup:** level transition resolves ACTIVE only, twice is harmless; `end_round` resolves active and queued as `ROUND_ENDED`, closes the loop, covers bots, idempotent; a finished match (player win, player loss with the bots playing it out, a full simulated match) leaves nothing unresolved and every attack has a cause; the next round starts empty. **Attribution:** the pure model on real script instances, bump tags and their expiry; the session counts every source and sends only for PLAYER, leaving no event / defeat / attack / stream draw for the others. Updated for `resolution` / `cause` / the two streams |
| `tests/battle_attack_game_test.gd` (67 checks, real game) | **Attribution matrix on real prefabs in a real Battle level:** PLAYER – Goomba stomp, star touch, hammer, the player's fireball through the Goomba's `FireballDetection`, a shell the player kicked through `ShellDetection`, a block the player bumped, Koopa stomp, a Koopa bounced off a bumped block; no send – another enemy, an enemy's projectile (ENEMY), spike ball and icicle through `IcicleDetection` (ENVIRONMENT), `die()`, an unknown object, an unkicked shell, an unbumped block, a Koopa bounced with no block known / off an unbumped block, a stale bump (UNKNOWN); one report per enemy; Classic reports nothing. **Player incoming in the live round:** three attacks stay ACTIVE for twelve Battle seconds, nothing resolved or spawned, the player unharmed; a fourth waits; resolve by id; duplicate refused; level transition (the real `BattleHandler` leaving the tree) → `LEVEL_TRANSITION`; winning the round → `ROUND_ENDED`; dying with an attack active → `TARGET_OUT` and nothing left unresolved; the next round starts clean |
| All other Battle tests | unchanged and passing: `battle_session_test` (21), `battle_round_test` (49), `battle_screen_test` (111), `battle_hud_test` (51), `battle_preview_atlas_test` (44), `battle_preview_test` (77, golden attack-free hashes), `battle_round_lifecycle_test` (103), and the GL render tests `battle_screen_render_test` (32), `battle_preview_render_test` (24) |

## 8. Known limits

1. The Player-side tag (`Player.handle_block_collision_detection` → `tag_block_bump`) is covered by a source-level check plus real-node tests from the tag onward; a physical headless bump (the player's `BlockCollision` area did not overlap a
   hand-placed brick in the test level) was not reproduced, so a real jump into a brick is the one path worth a manual look.
2. A bumped block's kill is attributed to the player only inside `BUMP_FRAMES` of the bump (30 physics frames, about half a second, about the length of a block bounce). A bounce caused by something else inside that window would be
   attributed to the player; shell- and spike-ball-caused bounces are not traced.
3. Until the visible-attack milestone nothing reports `DEFEATED_BY_PLAYER` or `DESPAWNED`; an attack ACTIVE against the player lasts until the level, the player or the round ends.
4. Enemies whose scripts override the death functions without the base class (Wiggler, Podoboo, Barrel) still need an explicit `report_battle_defeat(cause)` call when they become supported, as noted in doc 42.
5. Balance is untouched. The only measurable difference from doc 42 is the bot sends' exact sequence per seed (section 2).
