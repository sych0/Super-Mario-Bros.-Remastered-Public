# 49 — Battle: targeting core, milestone M-T1 (what was built and verified)

Status: implemented on top of `19d9cf2` (M6b, doc 48) with doc 47 (the SMB35 reference, `fc3e833`) brought onto this branch as a document only. Nothing was rolled back.
Doc 47 §19 asks for the milestone's document to be `docs/48-battle-targeting-core-m-t1.md`; doc 48 was already taken by M6b, so this is **doc 49**.

M-T1 gives every contestant one persistent, always valid **target**, makes every send go to the sender's target as that sender's mode updates it, shows the real player's target with
the red reticle, and exposes who is aiming at whom. The player's four targeting modes exist as policies behind one router and can be selected through a **provisional** key binding.
It changes no timer, no balance constant, no attack line, no incoming-enemy rule and no layout geometry.

## 0. How the brief and doc 47 were reconciled

Doc 47's M-T1 (§18, §19) is: B35-TARGET-001, 002, 004, 007, with B35-PERF-001 optional. It does **not** include the selector (TARGET-005) or the Lowest Time / Most Coins / Attackers
policies (TARGET-006); doc 47 files those under M-TMODE, behind Q5 and Q6. The M-T1 brief given for this pass asks for the strategy architecture for all four modes, a player mode state with a
selection API, and "only the minimum provisional/test binding necessary for physical acceptance" if Q5 is still open. So:

| Item | Done? | Basis |
|---|---|---|
| B35-TARGET-001 persistent target for every contestant, `TARGET_CHANGED` | **yes** | doc 47 §19 |
| B35-TARGET-002 the red reticle on the player's target pane | **yes** | doc 47 §19 |
| B35-TARGET-004 Random: a new pick per send; the target is the last recipient | **yes** | doc 47 §19 |
| B35-TARGET-007 bots hold targets; `attackers_of` (data only) | **yes** | doc 47 §19 |
| Targeting-mode architecture: Random, Lowest Time, Attackers, Most Coins (deferred) behind one router; `player_target_mode` on the session | **yes** | the brief; doc 47 TARGET-006 supplies the rules |
| Provisional mode keys (I / J / K / L) and a small labelled readout | **yes, provisional** | the brief (Q5 open) |
| B35-TARGET-005 the SMB35 selector (four pills, fade, placement) | **no** | not in M-T1; Q5 is open |
| B35-TARGET-003 reticle flight replacing the gold line | **no** | M-T2, needs Q7 |
| Bot mode mix | **no** | Q6; bots stay Random |
| B35-PERF-001 freeze KO'd atlas cells | **no, deferred to M-K** | section 9 |

## 1. Files

| File | Change |
|---|---|
| `Scripts/Classes/Battle/BattleTargeting.gd` | The policy base: `Mode` enum, `choose` / `on_send` / `reevaluate` / `continuous` / `mode_available`, and the shared helpers `eligible`, `is_valid_target`, `replacement`, `initial`, `mix` |
| `Scripts/Classes/Battle/BattleTargetingRandomSurvivor.gd` | Random (unchanged rule) |
| `Scripts/Classes/Battle/BattleTargetingLowestTime.gd`, `BattleTargetingAttackers.gd`, `BattleTargetingMostCoins.gd` (new) | The other three policies |
| `Scripts/Classes/Battle/BattleTargetingModes.gd` (new) | The stock router: bots → Random, the player → the policy of `session.player_target_mode` |
| `Scripts/Classes/Battle/BattleAttackSystem.gd` | `init_targets`, `set_target`, `after_kos`, `update_targets`; the send path asks `targeting.on_send` and sets the sender's target to the recipient; the default `targeting` is the router; snapshot carries the initial targets |
| `Scripts/Classes/Battle/BattleSession.gd` | `EventType.TARGET_CHANGED` (appended); `player_target_mode`; `set_player_target_mode`, `target_mode_available`, `target_of`, `attackers_of`, `initial_targets`; hooks in `step()` and `_apply_kos`; snapshot carries targets and mode |
| `Scripts/Classes/Battle/BattleContestant.gd` | `target_id` is live (it was reserved) |
| `Scripts/Classes/Battle/BattleAttackPresentation.gd` | Reads `TARGET_CHANGED`: `target_of(id)`, `player_target` (read-only; it asks the session for the initial targets, as the source-scan test requires) |
| `Scripts/Classes/Battle/BattleTargetReticle.gd` (new) | The bracket, drawn on the canvas between the panes and the attack layer |
| `Scripts/Classes/Battle/BattleScreen.gd` | Builds the reticle; which pane it is on (`_reticle_target`); the provisional keys (`select_target_mode`, `_unhandled_input`); the provisional readout in strip B |
| `docs/47-smb35-implementation-reference.md` | Brought from `origin/docs/smb35-reference` (`fc3e833`), unchanged |
| tests | Section 10 |

No change to the timer, `BattleBotSimulator`, `BattleIncomingSpawner`, the attack lines, the strip, the preview architecture, `BattleHudLayout`, the classic HUD, any enemy or Classic code.

## 2. The model

**One persistent target per contestant** (`BattleContestant.target_id`): an alive contestant other than itself, or **-1** when there is none. Invariant, checked on every tick of 200 whole matches:
alive contestants have a valid target while two or more are in; a contestant who is out has none; with one left (or none) nobody has one. With the attack loop off nobody has a target and nothing is logged.

**When a target changes** (and `TARGET_CHANGED` is logged: `id`, `a` = new target, `b` = old target, never when nothing changed):

| Cause | Rule |
|---|---|
| a send | the sender's target becomes the recipient (logged after the send's own `ENEMY_DEFEATED`, `SENT`, `RECEIVED`, which keep their order) |
| its target is KO'd | the same tick, in the same call: `after_kos` runs once all of a tick's KOs are applied (a group of simultaneous KOs is handled together) |
| the player's mode follows a measure | at the end of every session tick, and when the mode is selected |
| the contestant itself goes out | its target becomes -1 |

**Initial targets.** Every contestant holds a first target from the moment the session exists. It is a fixed function of the seed and the id (`BattleTargeting.mix`, a 31-bit integer hash, then `candidates[hash % n]`): **no random stream is drawn from**,
so the streams' counts stay exactly those of the sends and the ticks. They are state, not events: `BattleAttackSystem.initial_targets` keeps them and a presentation made mid-round replays the log from there. This also matches the reference's
countdown reticle, which was *not* the first recipient (doc 47 TARGET-004): the first send draws a new target.

**Re-targeting after a KO** (for Random, and as the fallback elsewhere) sweeps to the next survivor after the old target (the next higher id, wrapping), skipping the contestant itself. No draw. This is also what the reference's reticle visibly does, stepping through neighbouring panes.

**Streams (doc 43, unchanged).** The attack system still takes exactly **one** draw from the sender's stream per accepted send, whatever the policy does with it, so changing the player's mode never moves a stream.
Tested: the player stream advances exactly once per accepted player send in Random, Lowest Time and Attackers and by nothing else (KOs, re-targeting and mode changes draw nothing); the bot stream advances exactly 3 × 34 draws per tick;
the player's mode never changes what the bots send, to whom or when (150 ticks, bot attacks identical), nor the main simulation stream.

## 3. The policies

`BattleTargeting` is the one interface the attack system uses. A policy is a pure function of the session state and one uniform draw; it owns no randomness. Three questions:
`choose` / `on_send` (the recipient of a send), `reevaluate` (the target a contestant should hold now; the default keeps a valid one, else sweeps), and `continuous` (must be re-evaluated every tick). A test policy that only
overrides `choose` still routes every send, exactly as before. Mode selection and availability are on the session, so nothing outside the router knows the modes exist.

| Mode | Candidates | Rule | Re-evaluated | Ties | Persistence |
|---|---|---|---|---|---|
| **RANDOM** (default) | alive, not the sender | a uniform draw from the sender's stream per send; the target is then the last recipient. Repeats are allowed | on a KO only (sweep) | n/a | until the next send or its KO |
| **LOWEST_TIME** | alive, not the sender | the lowest `time_left`; sends go to it and do not change it | every tick, on selection, on a KO | lower id | follows the clock |
| **ATTACKERS** | `attackers_of(player)`: survivors whose own target is the player | the current target if it is still an attacker; otherwise the lowest-id attacker. With **no** attacker the target is left as it is (still valid) and a send falls back to **Random**, using that send's draw | every tick, on selection, on a KO | lower id | kept while it still attacks |
| **MOST_COINS** | alive, not the sender | the most coins, from `coin_source` only | when available | lower id | n/a: **unavailable** |

* **Default mode: RANDOM.** It is what the game does today and what the reference player used throughout M2.
* **Lowest Time and the flat clock.** Doc 47 recommends continuous evaluation ("Unknown" whether SMB35 does that or only on send / KO). Under today's flat 600 s clock every contestant has the same time, so Lowest Time
  aims at the lowest alive id until the time economy (a later, Zack-gated milestone) gives times a spread. The player's own time never counts.
* **Attackers: what "attacking" means.** Doc 47's definition is used: `attackers_of(id)` is the survivors whose current *target* is `id` (bots hold targets that persist until their next send or KO). The alternative reading,
  "senders of unresolved attacks on the player", is not used; it would need no persistent bot targets but would not match the reference's "who is aiming at you".
* **Most Coins** is implemented as a complete strategy but **no coin data exists** (coins are a later milestone and Q4), so none was invented: a contestant has no coin field, the policy is *unavailable*, `set_player_target_mode(MOST_COINS)` is
  refused and changes nothing, and the provisional key shows "MOST COINS: NOT AVAILABLE YET". Its values come only from `BattleTargetingMostCoins.coin_source`, a `Callable(contestant) -> int` that the coin milestone will supply from
  authoritative state. A test supplies one to prove the selection logic (richest, ties to the lower id, follows the coins each tick, never the player's own).
* **Bots** keep Random; the router returns Random for every contestant but the player. A bot mode mix is Q6.

## 4. Session API

```
session.player_target_mode                 BattleTargeting.Mode, RANDOM at the start of every round (a new session carries nothing over)
session.set_player_target_mode(mode)       true if the mode is now `mode`; false, changing nothing, for an unknown or unavailable mode,
                                           a player who is out, a finished round, or a round without the attack loop. Takes effect at once:
                                           the target is re-evaluated now and every later send uses the mode; attacks already made are untouched
session.target_mode_available(mode)
session.target_of(id)                      the contestant's target, or -1
session.attackers_of(id)                   survivors whose target is `id`, ascending (exact after every tick of whole matches)
session.initial_targets()                  a copy, for a presentation made mid-round
```
Changing the mode does not alter what counts as a send, the attack counts, the enemy kind, queue state, activation, pressure or physical spawning (tested: identical queues and attacks in any mode).

## 5. The reticle

`BattleTargetReticle`: pure red (255, 26, 26) four-corner brackets, arms a quarter of the pane's width, 1 canvas unit (4 px at 1080p) thick, in the 2-unit gap outside the pane's edge, so the picture is never covered.
It sits above the opponent panes and below the attack layer. It shows only in **PRE_ROUND and PLAYING**, with two or more alive and the player in, on exactly one alive pane, and never on a pane showing its KO card. It is a view: `BattleScreen` tells it which pane
(from the presentation's `player_target`, which reads `TARGET_CHANGED`, so it moves on the frame the change is presented) and it redraws only when that changes.
The reference's bracket is about 0.75 units thick and 0.5 outside the pane; this one is slightly heavier for legibility at lower resolutions (a tuning note, not a requirement).

## 6. Mode selection: PROVISIONAL

Q5 (the selector's controller mapping) is open, so there is no shipping control scheme and no gamepad binding. For physical acceptance only:

* **I / J / K / L** select **Lowest Time / Random / Attackers / Most Coins**, laid out like SMB35's selector cross (up, left, down, right). They are read in `BattleScreen._unhandled_input` from the physical key, **not** through the game's InputMap, so no setting,
  no other mode and no Classic input is touched. A held key (echo) does nothing.
* They work only in PRE_ROUND and PLAYING and not while the game is paused (the tree or `Global.game_paused`); the player's state is untouched by a pause.
* A tiny labelled readout in strip B (previously plain gold): `TARGET: RANDOM   [I J K L: MODE, PROVISIONAL]`. Pressing L shows `MOST COINS: NOT AVAILABLE YET` for 2.5 s. Hidden with the attack loop off.
  It is a single node (`TargetModeReadout`) and is meant to be removed when the SMB35 selector (M-TMODE) lands.

## 7. What changed for existing behaviour

* Recipients are unchanged in Random (the same draw picks the same survivor); the new fact is that the choice now persists as the sender's target.
* `battle_screen_render_test` (GL): one pixel sample moved. It checked that strip B is plain gold at the strip's middle; that is now where the provisional readout's text is, so the colour is sampled at both ends of the strip instead.
* `battle_attack_test`: one expectation changed. "With the machinery on but nothing sent, the event log equals the attack-free one" is now "...apart from `TARGET_CHANGED`"; with persistent targets, contestants re-target when their target goes out. The same check still
  requires an identical rng state, match length, winner and every contestant's outcome, and that the attack-free log has no `TARGET_CHANGED`. No other assertion was weakened.
* The attack-free model is bit-identical: the preview golden hashes pass unchanged.
* Nothing in M6a (incoming enemies, placement, pacing, transitions, R0) or M6b (strip phases, arrival brackets) was touched.

## 8. Doc 47 ambiguities and the choices made

1. Doc 47 gives no stream for non-send re-targets (the initial target and the KO replacement), and §19 requires "one player draw per accepted send" and "exactly 3 × 34 bot draws per tick". Both re-targets are therefore draw-free (a seed hash and a sweep).
2. Whether Random repeats: Unknown in the reference; repeats are allowed, as before.
3. Lowest Time continuous vs. on send / KO: continuous (the doc's recommendation).
4. Attackers: the details in section 3 are the smallest deterministic reading of one sentence; the mode was never selected in the reference. Marked experimental in code.
5. Doc 47 §19 names `docs/48-...` for this document; 48 was taken (M6b), so this is 49. It also names branch `battle-mode` at `fa88f68`; the work continues on `claude/youthful-tesla-99o9hl` after `19d9cf2`.
6. TARGET-001 says the player "has a valid target while playing, ≥2 are alive and the round is open": with ≥2 alive the invariant holds for every contestant, and after the round closes (`finished`) the survivor has none.

## 9. Deferred, and why

* **B35-PERF-001 (freeze KO'd atlas cells)** is optional in doc 47 ("if the milestone has time, otherwise move it to M-K") and the brief allows it only if it falls out naturally. It does not: the pane shows the *live picture under a KO wash*,
  so stopping the cell's rendering would blank the picture until the KO card (B35-KO-001/002) replaces it. Doc 47's own recommendation is to ship it with those cards in M-K.
* The reticle's flight, the gold line's removal, bot→bot lines, the frame flash and the pane pips: M-T2 (Q7).
* The selector, coins, the time economy, the pale tint, the 224-row window and everything else listed as not-yet in the brief.

## 10. Tests

| File | Checks | What |
|---|---|---|
| `tests/battle_targeting_test.gd` (new, pure) | 120 | Initial targets (valid, no event, deterministic, spread, no stream or main-rng draw, attack-free sessions have none); Random (target = last recipient, event content and order, repeats, 10,000 sends uniform: chi-square, the player never targeted); KO re-targeting (the same call, sweep, wrap, group KOs, the KO'd hold none, the last two aim at each other, the winner none); `attackers_of` (exact, ascending, after every tick of 12 matches); Lowest Time (selects, follows, ties, never self, KO replacement, stable); Attackers (no attackers: target kept and the send uses Random's draw; lowest id; kept while an attacker; moves when it stops; KO replacement; always an actual attacker over 10 matches); Most Coins (no coin state, unavailable, refused, with a supplied source richest / ties / follows / never self, unavailable again); the mode API (default, unknown, current, survives ticks and KOs, resets per round, refused when out / finished / off, custom policies still route); modes change only future sends (history, counts and queues untouched); streams (the player stream once per send in three modes; the bot stream 3 × 34 per tick; the player's mode never changes the bots' sends); 200 whole matches in every mode with no invalid target; determinism; the presentation's target; event numbering |
| `tests/battle_attack_screen_test.gd` (+19) | 75 | The reticle is on the canvas, over the panes and under the attack layer; on the target while playing; the real I / K / L / J key events select modes; echo ignored; Most Coins refused with the readout; paused: no selection and nothing changes; a KO moves it and it is never on a KO'd pane over two seconds; it shows in PRE_ROUND and PLAYING and not in LOADING / ROUND_OVER / RESULTS; the new round is Random with the reticle on its own target; with the loop off no reticle, readout or mode; the reticle is on a real send's recipient |
| `tests/battle_attack_game_test.gd` (+12) | 81 | Real kills (stomp, star, hammer, fireball-style hit) go to the Lowest Time target and to an attacker and to a Random survivor; the mode and the reticle hold while the game runs; Most Coins refused; the player never targets themself |
| `tests/battle_attack_render_test.gd` (+9, GL) | 49 | The target pane has a pure-red bracket at all four corners (r > 225, g < 50, b < 70), no other pane has one, the picture is not covered, it follows Lowest Time, and after a KO it moves and none is left on the KO'd pane, exactly one pane has one |
| `tests/battle_attack_test.gd` | 168 | The one expectation of section 7 |
| `tests/battle_screen_render_test.gd` | 32 | The one sample of section 7 |
| Existing suites (unchanged) | | session 21, round 49, screen 111, HUD 51, preview atlas 44, preview 77 (golden hashes), attack view 118, incoming plan 95, incoming view 107, round lifecycle 103, incoming game 83, arrival game 110; GL: incoming render 12, arrival render 32, preview render 24 |

**Result: all 16 headless suites and all 5 GL suites pass, with no script errors in any log.**

Mutations run against `battle_targeting_test`, each caught and reverted: KO re-targeting disabled (20 checks fail), the recipient not becoming the target (11), Lowest Time ties going to the higher id (3), the per-tick re-evaluation removed (12).

Commands: `godot --headless --fixed-fps 60 --path . -s tests/<suite>.gd`; GL: `xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 -s tests/<suite>.gd -- pack=SandboxStandIn`.

## 11. Differences between accepted work and the SMB35 reference that are NOT M-T1 (recorded for the later milestones, not changed)

Taken from doc 47's gap matrix; M6b's visuals were not re-measured against the video.
* **TARGET-003 / Q7**: the player's send is still the gold line with an enemy head (0.55 s) plus a yellow target tint; the reference flies the reticle. During a send the gold tint and the new red bracket now show at once on the recipient (M-T2).
* **ATTACK-002 / INCOMING-004 / Q7**: bot→bot white lines, pane pips and the red window-frame flash remain.
* **INCOMING-001 (M-INC)**: the strip is a static icon list with "ARRIVING n / QUEUED m" text; the reference is a moving icon bar with no text.
* **INCOMING-003 / Q13**: incoming enemies look native (a doc 46 decision); M6b adds white arrival brackets. The reference tints them pale.
* **INCOMING-005 / 006 (M-INC / M-TMODE)**: no WATCH OUT pill and no eye counter; `attackers_of(0)` now exists to feed the counter.
* **Strip B** now holds the provisional readout; in the reference it is the status strip (eye counter, WATCH OUT, chest bonus), so the readout has to go when those arrive.
* **ATTACK-003 / Q15**: rule R0 stands.

## 12. Zack decisions still needed

* **Before M-T2**: Q7 (may the doc 44 presentation change: reticle flight replaces the gold line; remove bot→bot lines; frame flash; pane pips).
* **Before M-TMODE** (the real selector): Q5 (controller mapping, and so the provisional keys' replacement) and Q6 (bots Random only, or a mix).
* **To make Lowest Time meaningful**: Q1 / Q2 / Q3 (the time economy; today every contestant has the same time). **To enable Most Coins**: Q4 (coins).
* Later milestones' questions (Q8–Q15) are unaffected.

## 13. For physical testing

1. Start a Battle. Strip B shows `TARGET: RANDOM [I J K L: MODE, PROVISIONAL]`, and a **red four-corner bracket** sits on one opponent's pane from the READY countdown on.
2. Stomp or kill an enemy: the enemy goes to the pane the bracket is on, and the bracket moves to the new recipient (Random).
3. Wait for that opponent to be eliminated: the bracket moves to a neighbouring pane at once, and is never left on a dead pane.
4. Press **I** (Lowest Time): the bracket goes to the lowest-numbered living opponent (all times are equal today) and stays there across kills.
5. Press **K** (Attackers): with nobody aiming at you the bracket stays and your next kill goes to a random survivor; once a bot has sent an enemy at you, the bracket jumps to it and sticks while it keeps aiming at you.
6. Press **L** (Most Coins): nothing changes and the strip says it is not available yet. **J** returns to Random.
7. Open the pause menu and press the keys: nothing changes. Close it: the mode and bracket are as they were.
8. Die or win: the bracket disappears on the results card; the next round starts in Random with a fresh target.
9. Incoming enemies, their arrival brackets, the incoming strip, pause behaviour and the previews should look and behave exactly as in M6b.
