class_name BattleTargetingRandomSurvivor
extends BattleTargeting
## Random (doc 47 B35-TARGET-004), the default for the player and the only policy bots use. Every send
## goes to a freshly drawn survivor: uniform over every living contestant except the sender (the real
## player is one of them), picked by the sender's own random draw, so the same seed and the same sequence
## of events always pick the same targets. Repeats are allowed. The sender's target is then the recipient
## (the reticle stays on the last recipient until the next send); between sends it only changes when it is
## KO'd, to the next survivor.

func choose(session: BattleSession, sender: int, draw: float) -> int:
	var candidates := BattleTargeting.eligible(session, sender)
	if candidates.is_empty():
		return -1
	return candidates[mini(int(draw * candidates.size()), candidates.size() - 1)]

func mode_available(_session: BattleSession, mode: int) -> bool:
	return mode == Mode.RANDOM
