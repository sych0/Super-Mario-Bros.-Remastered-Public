class_name BattleTargetingRandomSurvivor
extends BattleTargeting
## The only policy so far: a random surviving opponent. Uniform over every living contestant
## except the sender (the real player is one of them), drawn from the attack system's own random
## stream, so the same seed and the same sequence of events always pick the same targets.

func choose(session: BattleSession, sender: int, rng: RandomNumberGenerator) -> int:
	var candidates := BattleTargeting.eligible(session, sender)
	if candidates.is_empty():
		return -1
	return candidates[rng.randi_range(0, candidates.size() - 1)]
