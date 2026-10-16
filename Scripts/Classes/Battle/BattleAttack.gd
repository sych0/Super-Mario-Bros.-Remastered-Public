class_name BattleAttack
extends RefCounted
## One enemy sent from one contestant to another. Owned and changed only by BattleAttackSystem;
## everything outside reads copies (`to_dict`). The lifecycle is QUEUED -> ACTIVE -> RESOLVED.

enum State {QUEUED, ACTIVE, RESOLVED}

var seq := 0 ## order in which attacks were sent this round (0, 1, 2...), never reused
var sender := 0
var target := 0
var kind := 0 ## BattleEnemyType.Kind
var sent_tick := 0
var state := State.QUEUED
var activated_tick := -1
var resolved_tick := -1
var resolved_by_ko := false ## resolved early because the target was eliminated

func to_dict() -> Dictionary:
	return {"seq": seq, "sender": sender, "target": target, "kind": kind, "sent_tick": sent_tick,
		"state": state, "activated_tick": activated_tick, "resolved_tick": resolved_tick, "resolved_by_ko": resolved_by_ko}
