class_name BattleTargetingRandomSurvivor
extends BattleTargeting
## The only policy so far: a random surviving opponent. Uniform over every living contestant
## except the sender (the real player is one of them), picked by the sender's own random draw, so
## the same seed and the same sequence of events always pick the same targets.

func choose(session: BattleSession, sender: int, draw: float) -> int:
	var candidates := BattleTargeting.eligible(session, sender)
	if candidates.is_empty():
		return -1
	return candidates[mini(int(draw * candidates.size()), candidates.size() - 1)]
