class_name BattleIncomingPlan
extends RefCounted
## When the next incoming enemy may appear in the real player's level (doc 45 section 9, doc 46). Pure
## bookkeeping over plain inputs: the session's rows for the real player (`sync`), the bridge's own
## clock (`advance`), and what happened when a spawn was tried (`on_spawned` / `on_failed`). It never
## creates, orders or ends an attack; it only says which ACTIVE, not-yet-spawned attack is due.
##
##   order     strict: only the earliest pending attack (lowest seq) can be due; a later one never
##             goes first, even when the earliest cannot be placed
##   grace     nothing spawns until GRACE seconds after the level first became deliverable
##   gap       at least GAP seconds between two spawns (so never two in one frame)
##   retry     after a failed placement, the same attack is tried again RETRY seconds later
##   relax     once the head attack has been held RELAX_AFTER seconds, placement may use the relaxed rule
##   nothing is dropped: an attack leaves `pending` only when it is spawned or no longer ACTIVE
##
## The clock is the bridge's sum of physics deltas, so it stops whenever the game does (pause menu,
## pre-round, death, win) and is deterministic under a fixed frame rate.

const GRACE := 1.5
const GAP := 1.0
const RETRY := 0.25
const RELAX_AFTER := 3.0

var clock := 0.0
var deliverable := false
var ready_at := -1.0 ## clock when the level first became deliverable (-1: not yet)
var last_spawn_at := -INF
var next_try_at := 0.0
var pending: Array[int] = [] ## ACTIVE attacks on the real player whose enemy has not appeared, in seq order
var kinds := {} ## seq -> BattleEnemyType.Kind, for the pending ones
var spawned := {} ## seq -> clock: what this plan saw spawned (a seq is never due twice)
var held_seq := -1 ## the head attack placement has failed for, since `held_since`
var held_since := -1.0
var failures := 0 ## failed placements, in total (for tests and logs)

## Reads the session's rows for the real player (BattleSession.get_incoming(PLAYER_ID), in send
## order): pending = the ACTIVE ones whose enemy has not been spawned (spawned_tick < 0).
func sync(rows: Array) -> void:
	pending.clear()
	kinds.clear()
	for row in rows:
		var r: Dictionary = row
		if int(r.state) == BattleAttack.State.ACTIVE and int(r.spawned_tick) < 0 and not spawned.has(int(r.seq)):
			pending.append(int(r.seq))
			kinds[int(r.seq)] = int(r.kind)
	pending.sort()
	if held_seq >= 0 and (pending.is_empty() or pending[0] != held_seq):
		held_seq = -1
		held_since = -1.0

## Moves the clock on by `delta` seconds; `deliverable_` says whether the player is in normal play.
func advance(delta: float, deliverable_: bool) -> void:
	clock += maxf(delta, 0.0)
	deliverable = deliverable_
	if deliverable and ready_at < 0.0:
		ready_at = clock

## The seq of the attack whose enemy should be spawned now, or -1.
func next_due() -> int:
	if pending.is_empty() or not deliverable or ready_at < 0.0:
		return -1
	if clock < ready_at + GRACE - 1e-6 or clock < last_spawn_at + GAP - 1e-6 or clock < next_try_at - 1e-6:
		return -1
	return pending[0]

## Whether the head attack has been held long enough for the relaxed placement rule.
func relaxed() -> bool:
	return held_seq >= 0 and not pending.is_empty() and pending[0] == held_seq and clock - held_since >= RELAX_AFTER - 1e-6

func on_spawned(seq: int) -> void:
	spawned[seq] = clock
	last_spawn_at = clock
	pending.erase(seq)
	kinds.erase(seq)
	if held_seq == seq:
		held_seq = -1
		held_since = -1.0

## Placement found nowhere for `seq`: keep it at the head, try again after RETRY.
func on_failed(seq: int) -> void:
	failures += 1
	next_try_at = clock + RETRY
	if held_seq != seq:
		held_seq = seq
		held_since = clock

## Holding: the head attack is due by time but could not be placed (for the strip and tests).
func holding() -> bool:
	return held_seq >= 0
