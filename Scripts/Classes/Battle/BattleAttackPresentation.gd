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
## sent_at, received_at, activated_at, spawned_at, resolved_at (presentation clock, -1 until it happened),
## landed_at (when the line reaches its target)}.
##
## What an attack on the real player LOOKS like (M6b, doc 48) is one of four phases, each a plain
## function of the authoritative state and nothing else (`phase_of`): QUEUED (sent; the line is in the
## air or the enemy waits its turn), ARRIVING (ACTIVE, its enemy not in the level yet), IN_LEVEL (ACTIVE,
## its one real enemy is in the player's level: the session's `spawned_tick`), RESOLVED (over).
## There is no second state machine here: a phase is derived, never stored, and never read back.

const MAX_FLIGHTS := 256 ## a safety valve: a match never has more lines in the air than there are contestants per second
const ACTIVATION_FLASH := 0.7 ## seconds a QUEUED -> ACTIVE change keeps flashing
const RECEIVE_FLASH := 0.45 ## seconds a new arrival keeps the strip lit (from the moment its line LANDS)
const SPAWN_FLASH := 0.6 ## seconds the strip marks that an attack's enemy just appeared in the level
const RESOLVE_FADE := 0.5 ## seconds a just-resolved attack's icon lingers in the strip, fading
const MAX_RESOLVED_KEPT := 6 ## a safety valve for the fading icons (a round never has this many at once)

## How an attack on the real player is shown. Derived from the authoritative state (`phase_of`).
enum Phase {QUEUED, ARRIVING, IN_LEVEL, RESOLVED}

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
var _resolved_recent: Array[Dictionary] = [] ## the real player's attacks that just ended, for the strip's fade
var _animate_until := 0.0 ## presentation clock until which something timed (a flash, a fade) is still running
var _targets := PackedInt32Array() ## every contestant's current target as presented: the session's initial targets, moved by TARGET_CHANGED

## A presentation of `session`'s attacks. Attacks that already happened (a presentation created
## mid-round) are replayed silently: they fill the counts and the incoming list but draw no lines.
func _init(session_: BattleSession) -> void:
	session = session_
	var n := BattleSession.CONTESTANT_COUNT
	_queued.resize(n)
	_active.resize(n)
	for i in n:
		_open.append([] as Array[int])
	_targets = session.initial_targets()
	_targets.resize(n) # (empty with the attack loop off: nobody has a target)
	_consume(true)

## Advances the presentation clock by `delta` seconds and reads the events logged since last time.
func update(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	clock += maxf(delta, 0.0)
	_consume(false)
	_prune()
	_prune_resolved()
	update_us = Time.get_ticks_usec() - t0

## Contestant `id`'s target as the presentation has caught up with it (-1: none).
func target_of(id: int) -> int:
	return _targets[id] if id >= 0 and id < _targets.size() else -1

## The real player's current target, as presented: where the reticle is (-1: none).
var player_target: int:
	get: return target_of(BattleSession.PLAYER_ID)

## Forgets everything on screen (lines, flashes). The counts stay: they mirror the session.
func clear_flights() -> void:
	flights.clear()
	_flight_by_seq.clear()
	_marked.clear()
	_resolved_recent.clear()

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
				_on_resolved(int(e.a), int(e.cause), int(e.tick), silent)
			BattleSession.EventType.INCOMING_SPAWNED:
				_on_spawned(int(e.a))
			BattleSession.EventType.TARGET_CHANGED:
				_targets[int(e.id)] = int(e.a) # not a trace event: targets are shown, not replayed as lines

func _note(type: int, seq: int, sender: int, target: int, kind: int, cause := 0) -> void:
	trace_count += 1
	trace_hash = hash([trace_hash, type, seq, sender, target, kind, cause])
	if keep_trace:
		trace.append("%d:%d:%d>%d:%d:%d" % [type, seq, sender, target, kind, cause])

func _on_sent(seq: int, sender: int, target: int, kind: int, tick: int, silent: bool) -> void:
	records[seq] = {"seq": seq, "sender": sender, "target": target, "kind": kind, "state": BattleAttack.State.QUEUED,
		"sent_tick": tick, "activated_tick": -1, "resolved_tick": -1, "cause": BattleAttack.Resolution.NONE,
		"sent_at": clock, "received_at": -1.0, "activated_at": -1.0, "resolved_at": -1.0, "spawned_at": -1.0,
		"landed_at": clock if silent else clock + BattleAttackFlight.DURATION}
	_queued[target] += 1
	_open[target].append(seq)
	_note(BattleSession.EventType.SENT, seq, sender, target, kind)
	if silent:
		return
	if target == BattleSession.PLAYER_ID:
		_animate_for(BattleAttackFlight.DURATION + RECEIVE_FLASH) # the line, then the strip's "new" outline
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
	_animate_for(ACTIVATION_FLASH)
	_note(BattleSession.EventType.INCOMING_ACTIVATED, seq, r.sender, r.target, r.kind)

## The real player's attack now has its real enemy in the level: ARRIVING becomes IN_LEVEL (the strip
## marks it for SPAWN_FLASH). Once per attack, however many times the log says it.
func _on_spawned(seq: int) -> void:
	var r: Dictionary = records.get(seq, {})
	if r.is_empty() or r.spawned_at >= 0.0:
		return
	r.spawned_at = clock
	_animate_for(SPAWN_FLASH)
	_note(BattleSession.EventType.INCOMING_SPAWNED, seq, r.sender, r.target, r.kind)

func _on_resolved(seq: int, cause: int, tick: int, silent := false) -> void:
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
	if r.target == BattleSession.PLAYER_ID and not silent and cause != BattleAttack.Resolution.TARGET_OUT and cause != BattleAttack.Resolution.ROUND_ENDED:
		# the player being out or the round ending clears the whole strip at once; anything else fades
		_resolved_recent.append({"seq": seq, "kind": r.kind, "cause": cause, "spawned": r.spawned_at >= 0.0, "at": clock})
		if _resolved_recent.size() > MAX_RESOLVED_KEPT:
			_resolved_recent.pop_front()
		_animate_for(RESOLVE_FADE)
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

## The phase an attack is in, from its authoritative state and whether its real enemy is in the level.
static func phase_of(state: int, spawned: bool) -> int:
	if state == BattleAttack.State.RESOLVED:
		return Phase.RESOLVED
	if state == BattleAttack.State.QUEUED:
		return Phase.QUEUED
	return Phase.IN_LEVEL if spawned else Phase.ARRIVING

static func phase_name(phase: int) -> String:
	return Phase.keys()[phase] if phase >= 0 and phase < Phase.size() else "?"

## The real player's unresolved incoming attacks, in send order, as copies: {seq, sender, kind, state,
## spawned (its real enemy is in the level), phase (Phase: QUEUED / ARRIVING / IN_LEVEL), in_transit (its line
## has not landed yet), flash (1..0 after it became ACTIVE), fresh (1..0 after its line landed), arrive
## (1..0 after its enemy appeared in the level)}. This is the incoming strip.
func player_incoming() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for seq in _open[BattleSession.PLAYER_ID]:
		var r: Dictionary = records[seq]
		var landed: bool = clock >= r.landed_at
		out.append({"seq": seq, "sender": r.sender, "kind": r.kind, "state": r.state, "spawned": r.spawned_at >= 0.0,
			"phase": phase_of(r.state, r.spawned_at >= 0.0), "in_transit": not landed,
			"flash": _fade(r.activated_at, ACTIVATION_FLASH), "fresh": _fade(r.landed_at, RECEIVE_FLASH) if landed else 0.0,
			"arrive": _fade(r.spawned_at, SPAWN_FLASH)})
	return out

## (queued, arriving, in level) among the real player's unresolved attacks: `counts(PLAYER_ID).y` split in two.
func player_phase_counts() -> Vector3i:
	var out := Vector3i.ZERO
	for seq in _open[BattleSession.PLAYER_ID]:
		var r: Dictionary = records[seq]
		match phase_of(r.state, r.spawned_at >= 0.0):
			Phase.QUEUED:
				out.x += 1
			Phase.ARRIVING:
				out.y += 1
			Phase.IN_LEVEL:
				out.z += 1
	return out

## The real player's attacks that ended in the last RESOLVE_FADE seconds, oldest first, as copies:
## {seq, kind, cause, spawned (its enemy had been in the level), fade (1..0)}. The strip lets their icons
## fade where they were. Nothing else reads them, and none exists for a player who is out or a round that ended.
func player_resolved() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in _resolved_recent:
		out.append({"seq": e.seq, "kind": e.kind, "cause": e.cause, "spawned": e.spawned, "fade": _fade(e.at, RESOLVE_FADE)})
	return out

## Anything that is still animating (the strip must keep redrawing while true).
func is_animating() -> bool:
	return not flights.is_empty() or clock - _last_activated < ACTIVATION_FLASH or clock - _last_received < RECEIVE_FLASH \
		or clock < _animate_until or _has_arriving()

func _has_arriving() -> bool:
	for seq in _open[BattleSession.PLAYER_ID]:
		var r: Dictionary = records[seq]
		if r.state == BattleAttack.State.ACTIVE and r.spawned_at < 0.0:
			return true
	return false

func _animate_for(seconds: float) -> void:
	_animate_until = maxf(_animate_until, clock + seconds)

func _prune_resolved() -> void:
	while not _resolved_recent.is_empty() and clock - float(_resolved_recent[0].at) >= RESOLVE_FADE:
		_resolved_recent.pop_front()

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
