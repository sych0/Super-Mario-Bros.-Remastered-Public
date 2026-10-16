class_name BattleTargetingModes
extends BattleTargeting
## The stock targeting of a Battle round: a router over the four policies. Simulated bots always use
## Random (a bot mode mix is a Zack decision, Q6). The real player uses the policy of
## `BattleSession.player_target_mode`, which they change during the round. A test, or a later feature, that
## wants every send routed one particular way replaces `BattleAttackSystem.targeting` with its own
## BattleTargeting; the router is only the default, and the rest of the attack system does not know the
## modes exist.

var random := BattleTargetingRandomSurvivor.new()
var lowest_time := BattleTargetingLowestTime.new()
var most_coins := BattleTargetingMostCoins.new()
var attackers := BattleTargetingAttackers.new(random)

## The policy that governs contestant `id` in `session` right now.
func policy_for(session: BattleSession, id: int) -> BattleTargeting:
	if id != BattleSession.PLAYER_ID:
		return random
	return policy_for_mode(session.player_target_mode)

func policy_for_mode(mode: int) -> BattleTargeting:
	match mode:
		Mode.LOWEST_TIME:
			return lowest_time
		Mode.MOST_COINS:
			return most_coins
		Mode.ATTACKERS:
			return attackers
	return random

func choose(session: BattleSession, sender: int, draw: float) -> int:
	return policy_for(session, sender).choose(session, sender, draw)

func on_send(session: BattleSession, sender: int, draw: float) -> int:
	return policy_for(session, sender).on_send(session, sender, draw)

func reevaluate(session: BattleSession, id: int) -> int:
	return policy_for(session, id).reevaluate(session, id)

func is_continuous_for(session: BattleSession, id: int) -> bool:
	return policy_for(session, id).continuous()

func mode_available(session: BattleSession, mode: int) -> bool:
	if mode < 0 or mode >= Mode.size():
		return false
	match mode:
		Mode.MOST_COINS:
			return most_coins.available()
	return true
