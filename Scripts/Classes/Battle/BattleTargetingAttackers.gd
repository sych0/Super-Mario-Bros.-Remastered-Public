class_name BattleTargetingAttackers
extends BattleTargeting
## Attackers (doc 47 B35-TARGET-006, TARGET-007): the target is one of the contestants that currently
## target `id` (`BattleSession.attackers_of`: survivors whose own target is `id`). EXPERIMENTAL: the mode was
## never selected in the reference, so the details below are the smallest deterministic reading of doc 47's
## "chosen among contestants whose current target is the player; falls back to Random when none exists":
##   candidates   `attackers_of(id)`, ascending id
##   persistence  the current target is kept while it is still an attacker
##   otherwise    the lowest-id attacker (no draw)
##   none at all  the target is left as it is (still valid) and the next send falls back to Random:
##                `fallback.choose` takes that send's draw, and the recipient becomes the target
## Re-evaluated every session tick, when the mode is selected and when its target is KO'd.

var fallback: BattleTargeting = null ## the Random policy (the router sets it)

func _init(fallback_: BattleTargeting = null) -> void:
	fallback = fallback_

func choose(session: BattleSession, sender: int, draw: float) -> int:
	var attackers := session.attackers_of(sender)
	if attackers.is_empty():
		return fallback.choose(session, sender, draw) if fallback != null else -1
	var current := session.contestants[sender].target_id
	return current if attackers.has(current) else attackers[0]

func reevaluate(session: BattleSession, id: int) -> int:
	if not session.contestants[id].alive:
		return -1
	var attackers := session.attackers_of(id)
	var current := session.contestants[id].target_id
	if attackers.is_empty():
		return super.reevaluate(session, id)
	return current if attackers.has(current) else attackers[0]

func continuous() -> bool:
	return true

func mode_available(_session: BattleSession, mode: int) -> bool:
	return mode == Mode.ATTACKERS
