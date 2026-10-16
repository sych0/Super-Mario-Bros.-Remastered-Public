class_name BattleTargeting
extends RefCounted
## Who an attack goes to, and who each contestant is currently aiming at (doc 47 §4, milestone M-T1).
## The attack system only ever asks this class: a later targeting mode (a bot mix, a manual choice...) is
## another subclass and nothing in sending, queues or delivery changes. A policy is a pure function of the
## session's authoritative state and the single uniform draw the attack system took from the sender's own
## random stream; it owns no randomness, must not change either, and never draws on its own. The attack
## system draws exactly once per accepted send whatever the policy does with the number, so changing the
## player's mode never moves a random stream.
##
## Every contestant holds one persistent target (`BattleContestant.target_id`): an alive contestant other
## than itself, or -1 when there is none. The attack system keeps it valid and logs TARGET_CHANGED:
##   send       `on_send` returns the recipient; the sender's target becomes the recipient
##   KO         whoever aimed at the contestant who went out re-targets on the same tick (`reevaluate`)
##   tick       a policy that `continuous` (the player's Lowest Time / Attackers / Most Coins) is
##              re-evaluated at the end of every session tick and when the mode changes
##
## A policy is asked three things:
##   choose(session, sender, draw)     the recipient of a send right now (the compatibility entry: a test
##                                     policy that only overrides this still routes every send)
##   on_send(session, sender, draw)    the same, as the send path calls it; defaults to `choose`
##   reevaluate(session, id)           the target `id` should hold right now; defaults to "keep it while it
##                                     is valid, else the next survivor" (`replacement`), which needs no draw

## The player's targeting modes, in the order of SMB35's selector cross (doc 47 B35-TARGET-005).
enum Mode {RANDOM, LOWEST_TIME, MOST_COINS, ATTACKERS}

## The contestant id `sender`'s attack goes to, or -1 if nobody can be targeted.
func choose(_session: BattleSession, _sender: int, _draw: float) -> int:
	return -1

## The recipient of `sender`'s send; the attack system then makes it the sender's persistent target.
func on_send(session: BattleSession, sender: int, draw: float) -> int:
	return choose(session, sender, draw)

## The target `id` should hold now. The default keeps a valid one and otherwise sweeps to the next
## survivor; a policy that follows a measure (time, coins, attackers) overrides it.
func reevaluate(session: BattleSession, id: int) -> int:
	if not session.contestants[id].alive:
		return -1
	var current := session.contestants[id].target_id
	if BattleTargeting.is_valid_target(session, id, current):
		return current
	return BattleTargeting.replacement(session, id, current)

## Whether this policy follows a measure that changes while play goes on, so the attack system must
## re-evaluate it every tick. `Random` does not: its target changes only on a send or a KO.
func continuous() -> bool:
	return false

## Whether the attack system must re-evaluate contestant `id` every tick (a router answers per contestant).
func is_continuous_for(_session: BattleSession, _id: int) -> bool:
	return continuous()

## Whether the player may select `mode` right now (Most Coins is unavailable until coin data exists).
func mode_available(_session: BattleSession, mode: int) -> bool:
	return mode == Mode.RANDOM

static func mode_name(mode: int) -> String:
	return Mode.keys()[mode] if mode >= 0 and mode < Mode.size() else "?"

## Contestants that may be targeted by `sender`: alive and not the sender, in ascending id order
## (the player included while alive). Every policy starts from this list.
static func eligible(session: BattleSession, sender: int) -> Array[int]:
	var out: Array[int] = []
	for c in session.contestants:
		if c.alive and c.id != sender:
			out.append(c.id)
	return out

## Whether `target` is a legal target for `id`: an alive contestant other than `id`, while `id` is in.
static func is_valid_target(session: BattleSession, id: int, target: int) -> bool:
	return target >= 0 and target < session.contestants.size() and target != id \
		and session.contestants[target].alive and session.contestants[id].alive

## The survivor that follows `old` (the next higher id still in, wrapping), skipping `id` itself; -1 when
## nobody else is in. No draw: a KO re-target sweeps to the neighbouring pane, as SMB35's reticle does.
static func replacement(session: BattleSession, id: int, old: int) -> int:
	var candidates := eligible(session, id)
	if candidates.is_empty():
		return -1
	var after := old if old >= 0 else id
	for c in candidates:
		if c > after:
			return c
	return candidates[0]

## The first target a contestant holds, before any send. A fixed function of the match seed and the id
## (no random stream is drawn from, so the streams' counts are exactly those of the sends and the ticks):
## uniform over everyone else, -1 when nobody else exists.
static func initial(session: BattleSession, id: int) -> int:
	var candidates := eligible(session, id)
	if candidates.is_empty():
		return -1
	return candidates[mix(session.seed_value, id) % candidates.size()]

## A small integer hash of (seed, id): non-negative, 31 bits, identical on every platform (no overflow).
static func mix(seed_value: int, id: int) -> int:
	var x: int = (seed_value & 0x7FFFFFFF) ^ (id * 40503 + 0x1F123BB5)
	x = ((x ^ (x >> 15)) * 1103515245 + 12345) & 0x7FFFFFFF
	x = ((x ^ (x >> 13)) * 1103515245 + 12345) & 0x7FFFFFFF
	return x ^ (x >> 16)
