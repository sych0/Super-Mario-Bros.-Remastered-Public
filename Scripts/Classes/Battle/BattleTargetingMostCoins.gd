class_name BattleTargetingMostCoins
extends BattleTargeting
## Most Coins (doc 47 B35-TARGET-006): the target is the survivor with the most coins; ties to the lower id.
## EXPERIMENTAL and DEFERRED: SMB35 never selected this mode in the reference, and Battle has no coin data
## yet (coins are a later milestone and a Zack decision, Q4). This class therefore invents nothing. Its coin
## values come only from `coin_source`, a Callable(contestant: BattleContestant) -> int that the coin
## milestone will supply from authoritative state. With no source it is *unavailable*: the player cannot
## select it, it never picks a target, and the session holds no coin field.

var coin_source := Callable()

func available() -> bool:
	return coin_source.is_valid()

## The survivor with the most coins; -1 when unavailable or nobody else is in.
func most(session: BattleSession, sender: int) -> int:
	if not available():
		return -1
	var best := -1
	var best_coins := 0
	for id in BattleTargeting.eligible(session, sender):
		var coins: int = coin_source.call(session.contestants[id])
		if best < 0 or coins > best_coins:
			best = id
			best_coins = coins
	return best

func choose(session: BattleSession, sender: int, _draw: float) -> int:
	return most(session, sender)

func reevaluate(session: BattleSession, id: int) -> int:
	if not available():
		return super.reevaluate(session, id) # nothing to follow: behave as a plain valid-target keeper
	return most(session, id) if session.contestants[id].alive else -1

func continuous() -> bool:
	return available()

func mode_available(_session: BattleSession, mode: int) -> bool:
	return mode == Mode.MOST_COINS and available()
