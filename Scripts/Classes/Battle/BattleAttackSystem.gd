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
##   ACTIVE    after the delay, if fewer than MAX_ACTIVE are active on that contestant.
##             Against a SIMULATED BOT it stays ACTIVE for BattleEnemyType.active_ticks(kind) ticks
##             and multiplies the bot's hazard by (1 + the sum of its active enemies' weights).
##             Against the REAL PLAYER there is no timer at all: it stays ACTIVE until the real game
##             reports an outcome (`resolve_incoming`), the level it is active in ends
##             (`resolve_all`), the player is eliminated, or the round ends. While ACTIVE it is either
##             still arriving or SPAWNED (`mark_spawned`: its one real enemy is in the player's level);
##             only spawned ones end with their level, the others carry into the next one.
##   RESOLVED  over, with a BattleAttack.Resolution saying why. It no longer counts for anything.
## A contestant's attacks always activate in the order they were sent.
##
## Randomness: two streams of its own, both derived from the session seed and neither shared with
## the other or with the main simulation stream (`session.rng`, which is never drawn from here):
##   bot_rng     seed ^ BOT_SALT     every simulated bot's defeat roll, enemy kind and target pick
##   player_rng  seed ^ PLAYER_SALT  the real player's target picks (one draw per accepted defeat)
## The bot stream is consumed at a FIXED rate: exactly DRAWS_PER_BOT draws for each of the
## contestant_count-1 bots on every tick, whether or not that bot is alive, advancing or sending.
## Its state is therefore a pure function of the seed and the number of ticks, and no choice the real
## player makes (when or whether they defeat an enemy, whom it goes to) can shift a bot's rolls. The
## player stream advances only when the player's own defeat is accepted, so it is a function of the
## seed and the player's actual defeat sequence, and bots never touch it.
## (What the player sends can still change a bot's *state*, through the pressure it adds and the
## KOs that follow; that is gameplay, not randomness. `pressure_enabled = false` removes it for tests.)
## With `enabled = false` the whole match is bit-identical to the attack-free model.

const ACTIVATION_DELAY := 3
const MAX_ACTIVE := 3
const MAX_PRESSURE := 4.0
const DEFEATS_PER_LEVEL := 5.0 ## a bot defeats this many enemies per level of progress, on average
const BOT_SALT := 0x5DEECE66D
const PLAYER_SALT := 0x2545F4914F6CDD1D
const DRAWS_PER_BOT := 3 ## defeat roll, enemy kind, target pick

var enabled := true
## Whether the simulated bots defeat enemies and send them (the real player's defeats always can).
## On in a match; tests and tools switch it off to isolate the effect of a chosen send.
var bots_send := true
## Whether active incoming enemies raise a simulated bot's hazard. On in a match; tests switch it off
## so that nothing the real player sends can change how a bot plays, which isolates the random streams.
var pressure_enabled := true
var bot_rng := RandomNumberGenerator.new()
var player_rng := RandomNumberGenerator.new()
var targeting: BattleTargeting = BattleTargetingRandomSurvivor.new()
var next_seq := 0
var defeats := 0 ## enemy defeats recorded this round (the next one's BattleAttack.defeat_seq)
var player_defeats := 0 ## how many of them were the real player's
var round_ended := false ## `end_round` ran: nothing more is sent or resolved
var defeat_sources: Dictionary = {} ## BattleAttribution.Source -> kills of NATIVE enemies the real game reported, attributable or not
var incoming_kill_sources: Dictionary = {} ## BattleAttribution.Source -> kills of Battle-incoming enemies (they resolve, never send)
var history: Array[BattleAttack] = [] ## every attack of the round, in send order
var queues: Array = [] ## per contestant: Array[BattleAttack] of its unresolved attacks, in send order

func _init(seed_value: int, contestant_count: int, enabled_ := true) -> void:
	enabled = enabled_
	bot_rng.seed = seed_value ^ BOT_SALT
	player_rng.seed = seed_value ^ PLAYER_SALT
	for i in contestant_count:
		queues.append([] as Array[BattleAttack])

## The stream `sender`'s random draws come from.
func rng_for(sender: int) -> RandomNumberGenerator:
	return player_rng if sender == BattleSession.PLAYER_ID else bot_rng

# ---- sending ---------------------------------------------------------------------------------

## The real game reported a kill that was `source` (BattleAttribution.Source). Counted for every
## source, so a kill that was NOT attributable to the player still leaves a trace and sends nothing.
func note_kill(source: int) -> void:
	defeat_sources[source] = int(defeat_sources.get(source, 0)) + 1

## The real game reported the kill of a Battle-incoming enemy (one this loop sent to the real player),
## attributed to `source`. Counted apart from native kills; such a kill never sends (doc 46, rule R0).
func note_incoming_kill(source: int) -> void:
	incoming_kill_sources[source] = int(incoming_kill_sources.get(source, 0)) + 1

## `sender` defeated an enemy of `kind`. Returns the attack it sent, or null if nothing was sent:
## attacks are off, the kind is unsupported, the match is over, the sender is already out, or
## there is nobody to send it to. A contestant who is out can never send. The target pick is drawn
## from `sender`'s own stream, and only once the defeat is accepted (an ignored defeat draws nothing).
## (A bot defeat reported from outside, as tests do, draws from the bot stream and so is not part of
## its fixed per-tick rate; the bots' own defeats come from `generate_bot_defeats`.)
func report_defeat(session: BattleSession, sender: int, kind: int) -> BattleAttack:
	if not _can_send(session, sender, kind):
		return null
	return _send(session, sender, kind, rng_for(sender).randf())

func _can_send(session: BattleSession, sender: int, kind: int) -> bool:
	return enabled and not round_ended and BattleEnemyType.is_supported(kind) \
		and not session.finished and session.contestants[sender].alive

func _send(session: BattleSession, sender: int, kind: int, draw: float) -> BattleAttack:
	if not _can_send(session, sender, kind):
		return null
	var defeat := defeats
	defeats += 1
	if sender == BattleSession.PLAYER_ID:
		player_defeats += 1
	var target := targeting.choose(session, sender, draw)
	if target < 0 or not session.contestants[target].alive or target == sender:
		session.record(BattleSession.EventType.ENEMY_DEFEATED, sender, kind, -1, {"defeat": defeat})
		return null
	var attack := BattleAttack.new()
	attack.seq = next_seq
	next_seq += 1
	attack.sender = sender
	attack.target = target
	attack.kind = kind
	attack.sent_tick = session.tick_count
	attack.defeat_seq = defeat
	history.append(attack)
	queues[target].append(attack)
	session.record(BattleSession.EventType.ENEMY_DEFEATED, sender, kind, attack.seq, {"defeat": defeat})
	session.record(BattleSession.EventType.SENT, sender, attack.seq, target, {"kind": kind})
	session.record(BattleSession.EventType.RECEIVED, target, attack.seq, sender, {"kind": kind})
	return attack

## The bots' defeat opportunities for this tick. `gains[id]` is how far bot `id` advanced this tick
## in levels (0 for a bot that is out or was eliminated this tick). A bot that advances further
## has more chances, so faster bots defeat (and send) more. Every bot, in id order, takes its
## DRAWS_PER_BOT draws from the bot stream every tick (see the class comment), then at most one
## defeat is made from them.
func generate_bot_defeats(session: BattleSession, gains: Array) -> void:
	if not enabled or not bots_send or round_ended:
		return
	for id in range(1, queues.size()):
		var roll := bot_rng.randf()
		var kind_roll := bot_rng.randf()
		var target_roll := bot_rng.randf()
		var gain: float = gains[id]
		if gain > 0.0 and roll < gain * DEFEATS_PER_LEVEL:
			_send(session, id, BattleEnemyType.pick_for_bot(kind_roll), target_roll)

# ---- lifecycle -------------------------------------------------------------------------------

## Advances every queue one tick (called by the session at the start of each tick, before the bots
## move): expired ACTIVE attacks are RESOLVED, then QUEUED ones become ACTIVE in send order. An
## attack that is ACTIVE against the real player is never expired here.
func step(session: BattleSession) -> void:
	if not enabled or round_ended:
		return
	var tick := session.tick_count
	for id in queues.size():
		var queue: Array = queues[id]
		if queue.is_empty():
			continue
		var kept: Array[BattleAttack] = []
		var active := 0
		for attack in queue:
			if attack.state == BattleAttack.State.ACTIVE and id != BattleSession.PLAYER_ID \
					and tick >= attack.activated_tick + BattleEnemyType.active_ticks(attack.kind):
				_resolve(session, attack, BattleAttack.Resolution.EXPIRED)
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
	resolve_all(session, id, BattleAttack.Resolution.TARGET_OUT)

## The ACTIVE attack numbered `seq`, aimed at the real player, now has its one real enemy in the
## player's level. Refused (false, nothing changed) unless the attack exists, is aimed at the real
## player, is ACTIVE, has not been spawned before, and the round is open: a second report for the
## same attack can never make a second enemy count.
func mark_spawned(session: BattleSession, seq: int) -> bool:
	if not enabled or round_ended or seq < 0 or seq >= history.size():
		return false
	var attack: BattleAttack = history[seq]
	if attack.target != BattleSession.PLAYER_ID or attack.state != BattleAttack.State.ACTIVE or attack.spawned_tick >= 0:
		return false
	attack.spawned_tick = session.tick_count
	session.record(BattleSession.EventType.INCOMING_SPAWNED, attack.target, attack.seq, attack.sender, {"kind": attack.kind})
	return true

## Resolves the ACTIVE attack numbered `seq` with `cause`. Returns false, and changes nothing, if
## there is no such attack, it is still QUEUED (it has not reached its target yet), it is already
## RESOLVED (a duplicate report is harmless), the round has ended, or `cause` is NONE or EXPIRED
## (an expiry is the bots' timer, not something the game reports).
func resolve_incoming(session: BattleSession, seq: int, cause: int, extra := {}) -> bool:
	if not enabled or round_ended or seq < 0 or seq >= history.size():
		return false
	if cause == BattleAttack.Resolution.NONE or cause == BattleAttack.Resolution.EXPIRED:
		return false
	var attack: BattleAttack = history[seq]
	if attack.state != BattleAttack.State.ACTIVE:
		return false
	queues[attack.target].erase(attack)
	_resolve(session, attack, cause, extra)
	return true

## Resolves every unresolved attack on `id` (or only its ACTIVE ones, or only its ACTIVE ones whose
## enemy has been spawned) with `cause`, in send order. Returns how many were resolved.
func resolve_all(session: BattleSession, id: int, cause: int, active_only := false, spawned_only := false) -> int:
	if not enabled:
		return 0
	var kept: Array[BattleAttack] = []
	var n := 0
	for attack in queues[id]:
		var keep: bool = ((active_only or spawned_only) and attack.state != BattleAttack.State.ACTIVE) or (spawned_only and attack.spawned_tick < 0)
		if keep:
			kept.append(attack)
		else:
			_resolve(session, attack, cause)
			n += 1
	queues[id] = kept
	return n

## The round is over: whatever is still unresolved, on anyone, ends with ROUND_ENDED, and the system
## closes (no more sends, activations or resolutions). Safe to call twice. Returns how many it resolved.
func end_round(session: BattleSession) -> int:
	if round_ended:
		return 0
	var n := 0
	if enabled:
		for id in queues.size():
			n += resolve_all(session, id, BattleAttack.Resolution.ROUND_ENDED)
	round_ended = true
	return n

func _resolve(session: BattleSession, attack: BattleAttack, cause: int, extra := {}) -> void:
	attack.state = BattleAttack.State.RESOLVED
	attack.resolved_tick = session.tick_count
	attack.resolution = cause
	var fields := {"kind": attack.kind, "cause": cause}
	fields.merge(extra)
	session.record(BattleSession.EventType.INCOMING_RESOLVED, attack.target, attack.seq, attack.sender, fields)

# ---- reading ---------------------------------------------------------------------------------

## The extra hazard multiplier `id` carries right now: the summed weights of its ACTIVE enemies.
func pressure(id: int) -> float:
	if not enabled or not pressure_enabled:
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
		rows.append([d.seq, d.sender, d.target, d.kind, d.sent_tick, d.state, d.activated_tick, d.resolved_tick, d.resolution, d.defeat_seq, d.spawned_tick])
	return {"enabled": enabled, "bots_send": bots_send, "pressure_enabled": pressure_enabled, "round_ended": round_ended,
		"next_seq": next_seq, "defeats": defeats, "player_defeats": player_defeats, "defeat_sources": defeat_sources.duplicate(),
		"incoming_kill_sources": incoming_kill_sources.duplicate(),
		"bot_rng_state": bot_rng.state, "player_rng_state": player_rng.state, "history": rows}
