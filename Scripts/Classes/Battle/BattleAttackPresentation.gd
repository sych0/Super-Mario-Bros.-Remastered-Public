class_name BattleAttackPresentation
extends RefCounted
## The visible side of the enemy send / receive loop, as plain data. It READS the authoritative event
## log (SENT, RECEIVED, INCOMING_ACTIVATED, INCOMING_RESOLVED) and turns it into what the Battle
## screen draws: the lines that fly from a sender to a target, which panes are marked as targets,
## and each contestant's count of queued / active incoming enemies (the real player's list is the
## incoming strip).
##
## The session decides everything; this decides only how it looks. It never calls a mutating method
## of BattleSession or BattleAttackSystem, never stores a reference to an event (everything it keeps
## is copied into its own records), never chooses a target and never infers an attack from what a
## pane is showing. Every piece of state is keyed by the attack's sequence id (BattleAttack.seq),
## which is what ties a line, a strip icon and an enemy in an opponent's preview to one real attack.
##
## One instance belongs to one session (a new round is a new session and so a new presentation: the
## previous round's lines, counts and icons cannot survive it). Time is a plain presentation clock
## advanced by `update(delta)`; with the same events and the same deltas the output is identical.
##
## Record of one attack (a Dictionary, owned here): {seq, sender, target, kind, state
## (BattleAttack.State), sent_tick, activated_tick, resolved_tick, cause (BattleAttack.Resolution),
## sent_at, received_at, activated_at, resolved_at (presentation clock, -1 until it happened)}.

const MAX_FLIGHTS := 256 ## a safety valve: a match never has more lines in the air than there are contestants per second
const ACTIVATION_FLASH := 0.7 ## seconds a QUEUED -> ACTIVE change keeps flashing
const RECEIVE_FLASH := 0.45 ## seconds a new arrival keeps the strip lit

var session: BattleSession = null ## read only
var clock := 0.0 ## presentation seconds
var flights: Array[BattleAttackFlight] = [] ## lines in the air or still marking their target, oldest first
var records := {} ## seq -> record
var trace_hash := 0 ## rolling hash of every event consumed, in order (replay checks)
var trace_count := 0 ## how many attack events were consumed
var keep_trace := false ## tests: also keep the consumed events as text
var trace: PackedStringArray = PackedStringArray()
var update_us := 0 ## cost of the last update(), for measurements

var _cursor := 0
var _queued := PackedInt32Array() ## per contestant: unresolved attacks still QUEUED
var _active := PackedInt32Array() ## per contestant: attacks ACTIVE
var _open: Array = [] ## per contestant: seqs of unresolved attacks, in send order
var _flight_by_seq := {}
var _marked := {} ## contestant id -> strength 0..1 of the strongest line still marking it
var _last_received := -1.0e9
var _last_activated := -1.0e9
var _last_activated_seq := -1

## A presentation of `session`'s attacks. Attacks that already happened (a presentation created
## mid-round) are replayed silently: they fill the counts and the incoming list but draw no lines.
func _init(session_: BattleSession) -> void:
	session = session_
	var n := BattleSession.CONTESTANT_COUNT
	_queued.resize(n)
	_active.resize(n)
	for i in n:
		_open.append([] as Array[int])
	_consume(true)

## Advances the presentation clock by `delta` seconds and reads the events logged since last time.
func update(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	clock += maxf(delta, 0.0)
	_consume(false)
	_prune()
	update_us = Time.get_ticks_usec() - t0

## Forgets everything on screen (lines, flashes). The counts stay: they mirror the session.
func clear_flights() -> void:
	flights.clear()
	_flight_by_seq.clear()
	_marked.clear()

# ---- reading the log --------------------------------------------------------------------------------

func _consume(silent: bool) -> void:
	var events: Array[Dictionary] = session.events
	while _cursor < events.size():
		var e: Dictionary = events[_cursor]
		_cursor += 1
		match int(e.type):
			BattleSession.EventType.SENT:
				_on_sent(int(e.a), int(e.id), int(e.b), int(e.kind), int(e.tick), silent)
			BattleSession.EventType.RECEIVED:
				_on_received(int(e.a))
			BattleSession.EventType.INCOMING_ACTIVATED:
				_on_activated(int(e.a), int(e.tick))
			BattleSession.EventType.INCOMING_RESOLVED:
				_on_resolved(int(e.a), int(e.cause), int(e.tick))
			BattleSession.EventType.INCOMING_SPAWNED:
				_on_spawned(int(e.a))

func _note(type: int, seq: int, sender: int, target: int, kind: int, cause := 0) -> void:
	trace_count += 1
	trace_hash = hash([trace_hash, type, seq, sender, target, kind, cause])
	if keep_trace:
		trace.append("%d:%d:%d>%d:%d:%d" % [type, seq, sender, target, kind, cause])

func _on_sent(seq: int, sender: int, target: int, kind: int, tick: int, silent: bool) -> void:
	records[seq] = {"seq": seq, "sender": sender, "target": target, "kind": kind, "state": BattleAttack.State.QUEUED,
		"sent_tick": tick, "activated_tick": -1, "resolved_tick": -1, "cause": BattleAttack.Resolution.NONE,
		"sent_at": clock, "received_at": -1.0, "activated_at": -1.0, "resolved_at": -1.0, "spawned_at": -1.0}
	_queued[target] += 1
	_open[target].append(seq)
	_note(BattleSession.EventType.SENT, seq, sender, target, kind)
	if silent:
		return
	var flight := BattleAttackFlight.new()
	flight.seq = seq
	flight.sender = sender
	flight.target = target
	flight.kind = kind
	flight.born = clock
	flights.append(flight)
	_flight_by_seq[seq] = flight
	if flights.size() > MAX_FLIGHTS: # never in a real match; the oldest line goes first
		var dropped: BattleAttackFlight = flights.pop_front()
		_flight_by_seq.erase(dropped.seq)

func _on_received(seq: int) -> void:
	var r: Dictionary = records.get(seq, {})
	if r.is_empty():
		return
	r.received_at = clock
	_last_received = clock
	_note(BattleSession.EventType.RECEIVED, seq, r.sender, r.target, r.kind)

func _on_activated(seq: int, tick: int) -> void:
	var r: Dictionary = records.get(seq, {})
	if r.is_empty() or r.state != BattleAttack.State.QUEUED:
		return
	r.state = BattleAttack.State.ACTIVE
	r.activated_tick = tick
	r.activated_at = clock
	_queued[r.target] -= 1
	_active[r.target] += 1
	_last_activated = clock
	_last_activated_seq = seq
	_note(BattleSession.EventType.INCOMING_ACTIVATED, seq, r.sender, r.target, r.kind)

## The real player's attack now has its real enemy in the level (M6a only records it; M6b draws it).
func _on_spawned(seq: int) -> void:
	var r: Dictionary = records.get(seq, {})
	if r.is_empty() or r.spawned_at >= 0.0:
		return
	r.spawned_at = clock
	_note(BattleSession.EventType.INCOMING_SPAWNED, seq, r.sender, r.target, r.kind)

func _on_resolved(seq: int, cause: int, tick: int) -> void:
	var r: Dictionary = records.get(seq, {})
	if r.is_empty() or r.state == BattleAttack.State.RESOLVED:
		return
	if r.state == BattleAttack.State.ACTIVE:
		_active[r.target] -= 1
	else:
		_queued[r.target] -= 1
	r.state = BattleAttack.State.RESOLVED
	r.resolved_tick = tick
	r.cause = cause
	r.resolved_at = clock
	_open[r.target].erase(seq)
	_note(BattleSession.EventType.INCOMING_RESOLVED, seq, r.sender, r.target, r.kind, cause)
	if cause == BattleAttack.Resolution.TARGET_OUT:
		var f: BattleAttackFlight = _flight_by_seq.get(seq, null)
		if f != null and f.cut_at < 0.0:
			f.cut_at = clock # the target is out: the line fades instead of landing on a KO

## Drops lines that have finished and recomputes which contestants are marked as targets.
func _prune() -> void:
	_marked.clear()
	if flights.is_empty():
		return
	var kept: Array[BattleAttackFlight] = []
	for f in flights:
		var s := f.strength(clock)
		if s <= 0.0:
			_flight_by_seq.erase(f.seq)
			continue
		kept.append(f)
		if s > float(_marked.get(f.target, 0.0)):
			_marked[f.target] = s
	flights = kept

# ---- what the screen asks -----------------------------------------------------------------------------

## Attacks of `id` that are still QUEUED / ACTIVE (x = queued, y = active). Mirrors the session's
## queue for `id`.
func counts(id: int) -> Vector2i:
	return Vector2i(_queued[id], _active[id])

## 0..1: how strongly a line currently marks contestant `id` as its target (0 = not at all).
func target_strength(id: int) -> float:
	return float(_marked.get(id, 0.0))

## The ids currently marked as a target.
func marked_ids() -> Array:
	return _marked.keys()

## The real player's unresolved incoming attacks, in send order, as copies: {seq, sender, kind, state,
## spawned (its real enemy is in the level), flash (1..0 after it became ACTIVE), fresh (1..0 after it
## arrived)}. This is the incoming strip.
func player_incoming() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for seq in _open[BattleSession.PLAYER_ID]:
		var r: Dictionary = records[seq]
		out.append({"seq": seq, "sender": r.sender, "kind": r.kind, "state": r.state, "spawned": r.spawned_at >= 0.0,
			"flash": _fade(r.activated_at, ACTIVATION_FLASH), "fresh": _fade(r.received_at, RECEIVE_FLASH)})
	return out

## Anything that is still animating (the strip must keep redrawing while true).
func is_animating() -> bool:
	return not flights.is_empty() or clock - _last_activated < ACTIVATION_FLASH or clock - _last_received < RECEIVE_FLASH

## The most recent QUEUED -> ACTIVE change, as {seq, kind, flash}; empty if none yet.
func last_activation() -> Dictionary:
	if _last_activated_seq < 0:
		return {}
	var r: Dictionary = records[_last_activated_seq]
	return {"seq": r.seq, "kind": r.kind, "flash": _fade(r.activated_at, ACTIVATION_FLASH)}

func _fade(at: float, length: float) -> float:
	if at < 0.0:
		return 0.0
	return clampf(1.0 - (clock - at) / length, 0.0, 1.0)

## The flight of attack `seq`, or null once it is over (or if it never had one).
func flight_of(seq: int) -> BattleAttackFlight:
	return _flight_by_seq.get(seq, null)

## Compact text form of the presented event sequence, for replay checks.
func signature() -> String:
	return "%d:%d" % [trace_count, trace_hash]
