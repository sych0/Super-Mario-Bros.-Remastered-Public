class_name BattleTargetingLowestTime
extends BattleTargeting
## Lowest Time (doc 47 B35-TARGET-006): the target is the survivor with the least `time_left`. Sends go to
## it and do not change it. It is re-evaluated every session tick, when the mode is selected and when its
## target is KO'd; a tie goes to the lower id. Whether SMB35 re-evaluates continuously or only on a send or
## a KO is Unknown in doc 47, which recommends continuous. Under today's flat clock every contestant has
## the same time, so the lowest id in is the target until the time economy (a later milestone) differentiates them.

## The survivor `sender` should aim at: lowest `time_left`, ties to the lower id; -1 when nobody else is in.
static func lowest(session: BattleSession, sender: int) -> int:
	var best := -1
	for id in BattleTargeting.eligible(session, sender):
		if best < 0 or session.contestants[id].time_left < session.contestants[best].time_left:
			best = id
	return best

func choose(session: BattleSession, sender: int, _draw: float) -> int:
	return lowest(session, sender)

func reevaluate(session: BattleSession, id: int) -> int:
	return lowest(session, id) if session.contestants[id].alive else -1

func continuous() -> bool:
	return true

func mode_available(_session: BattleSession, mode: int) -> bool:
	return mode == Mode.LOWEST_TIME
