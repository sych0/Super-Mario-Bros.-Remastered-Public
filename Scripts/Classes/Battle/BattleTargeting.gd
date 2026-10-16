class_name BattleTargeting
extends RefCounted
## Who an attack goes to. The attack system only ever asks `choose()`, so a later targeting mode
## (attackers, most coins, lowest time, a manual choice...) is another subclass of this class and
## nothing in sending, queues or delivery changes. The policy is given the session's authoritative
## state to read and the attack system's own random stream; it must not change either.

## The contestant id `sender`'s attack goes to, or -1 if nobody can be targeted.
func choose(_session: BattleSession, _sender: int, _rng: RandomNumberGenerator) -> int:
	return -1

## Contestants that may be targeted by `sender`: alive and not the sender, in ascending id order
## (the player included while alive). Every policy starts from this list.
static func eligible(session: BattleSession, sender: int) -> Array[int]:
	var out: Array[int] = []
	for c in session.contestants:
		if c.alive and c.id != sender:
			out.append(c.id)
	return out
