class_name BattleAttack
extends RefCounted
## One enemy sent from one contestant to another. Owned and changed only by BattleAttackSystem;
## everything outside reads copies (`to_dict`). The lifecycle is QUEUED -> ACTIVE -> RESOLVED.

enum State {QUEUED, ACTIVE, RESOLVED}

## Why an attack stopped being unresolved. NONE until it is RESOLVED.
##   EXPIRED            its active time ran out (simulated bots' incoming enemies only; an enemy
##                      that is active against the real player never expires by time)
##   TARGET_OUT         its target was eliminated
##   DEFEATED_BY_PLAYER the real player defeated the enemy that represented it (game-reported)
##   DESPAWNED          the enemy left the active area / was removed (game-reported)
##   LEVEL_TRANSITION   the level it was active in ended (game-reported)
##   ROUND_ENDED        the round ended and cleaned up what was left
##   OTHER              anything else the game reports
enum Resolution {NONE, EXPIRED, TARGET_OUT, DEFEATED_BY_PLAYER, DESPAWNED, LEVEL_TRANSITION, ROUND_ENDED, OTHER}

var seq := 0 ## order in which attacks were sent this round (0, 1, 2...), never reused
var sender := 0
var target := 0
var kind := 0 ## BattleEnemyType.Kind
var sent_tick := 0
var state := State.QUEUED
var activated_tick := -1
var resolved_tick := -1
var resolution := Resolution.NONE
var defeat_seq := 0 ## which defeat of the round (0, 1, 2...) this attack was sent for
## Real player only: the tick its enemy was physically spawned into the player's level, or -1 while
## it has not been (QUEUED, or ACTIVE and still arriving). Set once, by
## BattleSession.report_player_incoming_spawned: one attack is never more than one enemy.
var spawned_tick := -1

static func resolution_name(resolution_: int) -> String:
	return Resolution.keys()[resolution_] if resolution_ >= 0 and resolution_ < Resolution.size() else "?"

func to_dict() -> Dictionary:
	return {"seq": seq, "sender": sender, "target": target, "kind": kind, "sent_tick": sent_tick,
		"state": state, "activated_tick": activated_tick, "resolved_tick": resolved_tick,
		"resolution": resolution, "defeat_seq": defeat_seq, "spawned_tick": spawned_tick}
