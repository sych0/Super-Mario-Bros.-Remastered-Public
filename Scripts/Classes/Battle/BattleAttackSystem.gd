class_name BattleAttackSystem
extends RefCounted
## The authoritative enemy send / receive loop of one Battle round, owned by its BattleSession
## (`session.attacks`). Pure data and rules: no scene tree, no presentation, no back-reference to
## the session (every call is handed the session it works on, so there is no reference cycle).
##
## Send: a contestant defeats an enemy (`report_defeat`; the real player through the game's kill
## path, a bot through `generate_bot_defeats`). The BattleTargeting policy picks a surviving
## opponent and the enemy joins that contestant's incoming queue.
##
## Incoming lifecycle, per contestant, in Battle seconds (session ticks):
##   QUEUED    sent. It waits ACTIVATION_DELAY ticks, in send order.
##   ACTIVE    after the delay, if fewer than MAX_ACTIVE are active on that contestant. It stays
##             ACTIVE for BattleEnemyType.active_ticks(kind) ticks. A simulated bot's hazard is
##             multiplied by (1 + the sum of its active enemies' weights) while they are.
##   RESOLVED  expired, or its target was eliminated. It no longer counts for anything.
## A contestant's attacks always activate in the order they were sent.
##
## Randomness: one stream of its own, seeded from the session seed. The bots' own stream is never
## drawn from here, so with no active incoming enemy a bot's fate is exactly what it was without
## attacks, and with `enabled = false` the whole match is bit-identical to the attack-free model.

const ACTIVATION_DELAY := 3
const MAX_ACTIVE := 3
const MAX_PRESSURE := 4.0
const DEFEATS_PER_LEVEL := 5.0 ## a bot defeats this many enemies per level of progress, on average
const RNG_SALT := 0x5DEECE66D

var enabled := true
## Whether the simulated bots defeat enemies and send them (the real player's defeats always can).
## On in a match; tests and tools switch it off to isolate the effect of a chosen send.
var bots_send := true
var rng := RandomNumberGenerator.new()
var targeting: BattleTargeting = BattleTargetingRandomSurvivor.new()
var next_seq := 0
var defeats := 0 ## enemy defeats recorded this round
var history: Array[BattleAttack] = [] ## every attack of the round, in send order
var queues: Array = [] ## per contestant: Array[BattleAttack] of its unresolved attacks, in send order

func _init(seed_value: int, contestant_count: int, enabled_ := true) -> void:
	enabled = enabled_
	rng.seed = seed_value ^ RNG_SALT
	for i in contestant_count:
		queues.append([] as Array[BattleAttack])

# ---- sending ---------------------------------------------------------------------------------

## `sender` defeated an enemy of `kind`. Returns the attack it sent, or null if nothing was sent:
## attacks are off, the kind is unsupported, the match is over, the sender is already out, or
## there is nobody to send it to. A contestant who is out can never send.
func report_defeat(session: BattleSession, sender: int, kind: int) -> BattleAttack:
	if not enabled or not BattleEnemyType.is_supported(kind) or session.finished or not session.contestants[sender].alive:
		return null
	defeats += 1
	var target := targeting.choose(session, sender, rng)
	if target < 0 or not session.contestants[target].alive or target == sender:
		session.record(BattleSession.EventType.ENEMY_DEFEATED, sender, kind, -1)
		return null
	var attack := BattleAttack.new()
	attack.seq = next_seq
	next_seq += 1
	attack.sender = sender
	attack.target = target
	attack.kind = kind
	attack.sent_tick = session.tick_count
	history.append(attack)
	queues[target].append(attack)
	session.record(BattleSession.EventType.ENEMY_DEFEATED, sender, kind, attack.seq)
	session.record(BattleSession.EventType.SENT, sender, attack.seq, target, {"kind": kind})
	session.record(BattleSession.EventType.RECEIVED, target, attack.seq, sender, {"kind": kind})
	return attack

## The bots' defeat opportunities for this tick. `gains[id]` is how far bot `id` advanced this tick
## in levels (0 for a bot that is out or was eliminated this tick). A bot that advances further
## has more chances, so faster bots defeat (and send) more. One roll per advancing bot per tick,
## in id order.
func generate_bot_defeats(session: BattleSession, gains: Array) -> void:
	if not enabled or not bots_send:
		return
	for id in range(1, gains.size()):
		var gain: float = gains[id]
		if gain > 0.0 and rng.randf() < gain * DEFEATS_PER_LEVEL:
			report_defeat(session, id, BattleEnemyType.pick_for_bot(rng.randf()))

# ---- lifecycle -------------------------------------------------------------------------------

## Advances every queue one tick (called by the session at the start of each tick, before the bots
## move): expired ACTIVE attacks are RESOLVED, then QUEUED ones become ACTIVE in send order.
func step(session: BattleSession) -> void:
	if not enabled:
		return
	var tick := session.tick_count
	for id in queues.size():
		var queue: Array = queues[id]
		if queue.is_empty():
			continue
		var kept: Array[BattleAttack] = []
		var active := 0
		for attack in queue:
			if attack.state == BattleAttack.State.ACTIVE and tick >= attack.activated_tick + BattleEnemyType.active_ticks(attack.kind):
				_resolve(session, attack, false)
			else:
				kept.append(attack)
				if attack.state == BattleAttack.State.ACTIVE:
					active += 1
		for attack in kept:
			if attack.state != BattleAttack.State.QUEUED:
				continue
			if tick < attack.sent_tick + ACTIVATION_DELAY or active >= MAX_ACTIVE:
				break # later attacks were sent later: nothing behind this one may go first
			attack.state = BattleAttack.State.ACTIVE
			attack.activated_tick = tick
			active += 1
			session.record(BattleSession.EventType.INCOMING_ACTIVATED, id, attack.seq, attack.sender, {"kind": attack.kind})
		queues[id] = kept

## `id` has been eliminated: whatever was still coming for them is over.
func on_contestant_out(session: BattleSession, id: int) -> void:
	if not enabled:
		return
	for attack in queues[id]:
		_resolve(session, attack, true)
	queues[id] = [] as Array[BattleAttack]

func _resolve(session: BattleSession, attack: BattleAttack, by_ko: bool) -> void:
	attack.state = BattleAttack.State.RESOLVED
	attack.resolved_tick = session.tick_count
	attack.resolved_by_ko = by_ko
	session.record(BattleSession.EventType.INCOMING_RESOLVED, attack.target, attack.seq, attack.sender, {"kind": attack.kind, "ko": by_ko})

# ---- reading ---------------------------------------------------------------------------------

## The extra hazard multiplier `id` carries right now: the summed weights of its ACTIVE enemies.
func pressure(id: int) -> float:
	if not enabled:
		return 0.0
	var total := 0.0
	for attack in queues[id]:
		if attack.state == BattleAttack.State.ACTIVE:
			total += BattleEnemyType.weight(attack.kind)
	return minf(total, MAX_PRESSURE)

## `id`'s unresolved attacks (QUEUED and ACTIVE) in send order, as copies: presentation code can
## read them but cannot change the queue.
func incoming(id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for attack in queues[id]:
		out.append(attack.to_dict())
	return out

func active_count(id: int) -> int:
	var n := 0
	for attack in queues[id]:
		if attack.state == BattleAttack.State.ACTIVE:
			n += 1
	return n

## Every attack of the round so far (resolved ones included), as copies, in send order.
func attack_history() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for attack in history:
		out.append(attack.to_dict())
	return out

## Everything that decides the loop, as plain data (for determinism checks).
func snapshot() -> Dictionary:
	var rows: Array = []
	for attack in history:
		var d := attack.to_dict()
		rows.append([d.seq, d.sender, d.target, d.kind, d.sent_tick, d.state, d.activated_tick, d.resolved_tick, d.resolved_by_ko])
	return {"enabled": enabled, "bots_send": bots_send, "next_seq": next_seq, "defeats": defeats, "rng_state": rng.state, "history": rows}
