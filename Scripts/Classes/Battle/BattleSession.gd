class_name BattleSession
extends RefCounted
## Authoritative match state for Battle Mode: contestants, the match clock, KO order and
## placements. Pure data + rules; never touches the scene tree.
##
## Slot 0 is the real player, slots 1..34 are simulated bots. Every contestant owns a
## match-long `time_left` that persists across level transitions (kill/time bonuses can
## later be applied to it without changing who owns it).

enum KoCause {NONE, HAZARD, TIME, FORFEIT}
## Things that happened to a contestant. Derived from state changes only (never from the rng),
## so recording them cannot change a match. Used by the opponent previews to stage outcomes.
## The attack events (ENEMY_DEFEATED onwards) are written by BattleAttackSystem.
## (New types are only ever appended, so recorded values never change meaning.)
enum EventType {HIT, POWER_UP, LEVEL_CLEAR, KO, ENEMY_DEFEATED, SENT, RECEIVED, INCOMING_ACTIVATED, INCOMING_RESOLVED, INCOMING_SPAWNED, TARGET_CHANGED}

const CONTESTANT_COUNT := 35
const PLAYER_ID := 0
const START_TIME := 600
const MAX_RESOLVE_STEPS := 20000

## The active match. Static so it outlives level scene changes (like BooRaceHandler state).
static var current: BattleSession = null
static var _last_uid := 0

## This session's identity, unique for the life of the program (1, 2, 3...). Attack sequence numbers
## restart at 0 every round, so an enemy carrying an attack's identity carries this too (doc 46):
## a report from an earlier round's enemy can never be taken for this round's attack. Not part of
## `snapshot()`: it says which session, not what happened in it.
var uid := 0

var seed_value := 0
var rng := RandomNumberGenerator.new()
var contestants: Array[BattleContestant] = []
var tick_count := 0
var alive_count := 0
var finished := false
var winner_id := -1
var world := 1
var level := 1
## Append-only event log: {tick, id, type (EventType), a, b}.
## HIT: a = new power. POWER_UP: a = new power. LEVEL_CLEAR: a = levels cleared. KO: a = KoCause.
## Attack events (id = the contestant they happened to; `kind` = BattleEnemyType.Kind):
##   ENEMY_DEFEATED  id = the defeater, a = kind, b = the attack's seq (-1 if there was nobody to send it to)
##   SENT            id = sender,   a = seq, b = target, kind
##   RECEIVED        id = target,   a = seq, b = sender, kind (the same moment as SENT, from the target's side)
##   INCOMING_ACTIVATED  id = target, a = seq, b = sender, kind
##   INCOMING_RESOLVED   id = target, a = seq, b = sender, kind, cause = BattleAttack.Resolution
##                       (+ source = BattleAttribution.Source when the real game killed its enemy)
##   INCOMING_SPAWNED    id = target (the real player), a = seq, b = sender, kind: its one real enemy is in the level
##   (ENEMY_DEFEATED also carries `defeat`, the round's defeat number it was sent for.)
##   TARGET_CHANGED  id = the contestant, a = its new target (-1: none), b = its old target. Logged on a send, a KO
##                   of the target, a measure-following mode's tick and a mode change; never for the first
##                   targets, which every contestant holds from the start (`BattleAttackSystem.initial_targets`).
var events: Array[Dictionary] = []
## The enemy send / receive loop of this round (state, queues, targeting, its own random streams).
var attacks: BattleAttackSystem = null
## How the real player's sends pick their recipient (BattleTargeting.Mode). RANDOM at the start of every
## round: a new session is a new round and nothing carries over. Changed during the round with
## `set_player_target_mode`; bots always use Random.
var player_target_mode := BattleTargeting.Mode.RANDOM
## Whether new sessions run the attack system. Tests switch it off to compare with the attack-free model.
static var default_attacks_enabled := true

## Creates a fresh match and makes it the current one. Nothing is inherited from before.
static func begin(seed_value_: int) -> BattleSession:
	current = BattleSession.new(seed_value_)
	return current

static func clear() -> void:
	current = null

func _init(seed_value_: int = 0) -> void:
	_last_uid += 1
	uid = _last_uid
	seed_value = seed_value_
	rng.seed = seed_value_
	var ranks: Array[int] = []
	for i in CONTESTANT_COUNT:
		ranks.append(i)
	for i in range(CONTESTANT_COUNT - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := ranks[i]
		ranks[i] = ranks[j]
		ranks[j] = tmp
	for i in CONTESTANT_COUNT:
		var c := BattleContestant.new()
		c.id = i
		c.is_bot = i != PLAYER_ID
		c.time_left = START_TIME
		c.skill = rng.randf()
		c.tiebreak = ranks[i]
		contestants.append(c)
	alive_count = CONTESTANT_COUNT
	attacks = BattleAttackSystem.new(seed_value_, CONTESTANT_COUNT, default_attacks_enabled)
	if attacks.enabled:
		attacks.init_targets(self)

func get_player() -> BattleContestant:
	return contestants[PLAYER_ID]

## Advances the match one fixed second: match timers, bots, and any resulting KOs.
func step() -> void:
	if finished:
		return
	tick_count += 1
	attacks.step(self) # incoming enemies activate / expire first, so this tick's bots feel them
	var gains: Array = []
	if attacks.enabled:
		gains.resize(CONTESTANT_COUNT)
		gains.fill(0.0)
	var knocked_out: Array[BattleContestant] = []
	for c in contestants:
		if not c.alive:
			continue
		var cause := KoCause.NONE
		if c.is_bot and not c.world_driven:
			var power_before := c.power
			var cleared_before := c.levels_cleared
			var distance_before := c.levels_cleared + c.progress
			cause = BattleBotSimulator.step_bot(c, tick_count, rng, attacks.pressure(c.id))
			if attacks.enabled and cause == KoCause.NONE:
				gains[c.id] = c.levels_cleared + c.progress - distance_before
			if c.power < power_before:
				_log(EventType.HIT, c.id, c.power)
			if c.levels_cleared > cleared_before:
				_log(EventType.LEVEL_CLEAR, c.id, c.levels_cleared)
			if c.power > power_before:
				_log(EventType.POWER_UP, c.id, c.power)
		else:
			c.time_left -= 1
			if c.time_left <= 0:
				cause = KoCause.TIME
		if cause != KoCause.NONE:
			c.ko_cause = cause
			knocked_out.append(c)
	attacks.generate_bot_defeats(self, gains) # bots that are still in may defeat (and send) an enemy
	_apply_kos(knocked_out)
	attacks.update_targets(self) # the measure-following targets (the player's Lowest Time / Attackers) catch up with this tick

# ---- opponents that play a real game (BattleBotWorld, doc 56) ----

## Makes contestant `id` a real-game opponent (or a simulated one again). Set before the round starts: from then on the
## session rolls nothing for it (its clock still runs here), and its game reports the rest through the functions below.
func set_world_driven(id: int, on := true) -> void:
	if id != PLAYER_ID:
		contestants[id].world_driven = on

## Whether `id` plays a real game: the real player, or a world-driven opponent. Enemies sent to a real game become real
## enemies in it, and stay ACTIVE until that game reports what happened to them.
func is_real(id: int) -> bool:
	return id == PLAYER_ID or contestants[id].world_driven

## Live in-level progress (0..1) of world-driven opponent `id`. Only moves forward within a level.
func report_bot_progress(id: int, value: float) -> void:
	var c := contestants[id]
	if c.world_driven and c.alive and not finished:
		c.progress = maxf(c.progress, clampf(value, 0.0, 1.0))

## World-driven opponent `id` cleared its course.
func report_bot_level_complete(id: int) -> void:
	var c := contestants[id]
	if c.world_driven and c.alive and not finished:
		c.levels_cleared += 1
		c.progress = 0.0
		_log(EventType.LEVEL_CLEAR, id, c.levels_cleared)

## World-driven opponent `id`'s Mario is now in power state `power` (0 small, 1 big, 2 fire): a HIT or a POWER_UP.
func report_bot_power(id: int, power: int) -> void:
	var c := contestants[id]
	if not c.world_driven or not c.alive or finished or power == c.power:
		return
	var before := c.power
	c.power = power
	_log(EventType.HIT if power < before else EventType.POWER_UP, id, power)

# ---- inputs from the real player (via BattleHandler) ----

func report_level_start(world_: int, level_: int) -> void:
	world = world_
	level = level_
	get_player().progress = 0.0

## Live in-level progress of the real player (0..1). Only moves forward within a level.
func report_player_progress(value: float) -> void:
	var p := get_player()
	if p.alive and not finished:
		p.progress = maxf(p.progress, clampf(value, 0.0, 1.0))

func report_level_complete() -> void:
	var p := get_player()
	if p.alive and not finished:
		p.levels_cleared += 1
		p.progress = 0.0
		_log(EventType.LEVEL_CLEAR, PLAYER_ID, p.levels_cleared)

## `id` defeated an enemy of BattleEnemyType.Kind `kind`. Returns the attack that was sent, or null
## if none was (see BattleAttackSystem.report_defeat). This is the trusted entry: the caller has
## already decided the defeat counts (the simulated bots, tests); the real game goes through
## `report_enemy_kill`, which decides that from the kill's attribution.
func report_enemy_defeat(id: int, kind: int) -> BattleAttack:
	return attacks.report_defeat(self, id, kind)

## The real game killed an enemy whose game script is at `script_path` (called by
## Enemy.report_battle_defeat, in Battle only), and `source` (BattleAttribution.Source) says what
## the kill is attributable to. `origin` is the enemy's Battle-incoming identity
## (BattleAttribution.origin_of): empty for the level's own (native) enemies.
##   native:   the kill is counted by source; an enemy is sent only when the source is PLAYER and the
##             enemy is a kind Battle supports (shells, plants and bosses are not sent yet). The enemy
##             is turned into a plain BattleEnemyType.Kind here, at the edge, and only that goes on.
##   incoming: `report_incoming_kill` - it resolves its own attack and NEVER sends (rule R0).
## The session decides everything else (whether anything is sent, and to whom). No-op without a
## current session.
## `by` is the contestant whose game the kill happened in: the real player, or a world-driven opponent (doc 56), whose own
## Mario is "the player" of its game (`source` PLAYER means him).
static func report_enemy_kill(script_path: String, source: int, origin := PackedInt64Array(), by := PLAYER_ID) -> BattleAttack:
	if current == null or not current.is_real(by):
		return null
	if not origin.is_empty():
		current.report_incoming_kill(origin, source, by)
		return null
	if by == PLAYER_ID:
		current.attacks.note_kill(source)
	if source != BattleAttribution.Source.PLAYER:
		return null
	var kind := BattleEnemyType.kind_for_script(script_path)
	if kind == BattleEnemyType.Kind.NONE:
		return null
	return current.report_enemy_defeat(by, kind)

## The real game killed an enemy that this session sent to the real player; `origin` is its identity
## (BattleAttribution.origin_of: [session uid, seq, sender, kind]). If it is this session's attack, aimed
## at the real player, ACTIVE and spawned, that attack is resolved: DEFEATED_BY_PLAYER when the kill is
## the player's (`source` PLAYER), OTHER otherwise, with `source` on the event. Anything else is residue
## (its attack already ended: a squashed Goomba, the Koopa that woke from a stomped incoming Koopa's
## shell) or stale (another round's): counted, nothing more. Never an ENEMY_DEFEATED, never a send,
## never a player-stream draw: an incoming enemy's death is not a defeat that sends (rule R0, doc 46).
## Returns whether an attack was resolved.
func report_incoming_kill(origin: PackedInt64Array, source: int, by := PLAYER_ID) -> bool:
	if by == PLAYER_ID:
		attacks.note_incoming_kill(source)
	if origin.size() != BattleAttribution.ORIGIN_SIZE or origin[0] != uid:
		return false
	var seq := int(origin[1])
	if seq < 0 or seq >= attacks.history.size():
		return false
	var attack: BattleAttack = attacks.history[seq]
	if attack.target != by or attack.sender != int(origin[2]) or attack.kind != int(origin[3]) or attack.spawned_tick < 0:
		return false
	var cause := BattleAttack.Resolution.DEFEATED_BY_PLAYER if source == BattleAttribution.Source.PLAYER else BattleAttack.Resolution.OTHER
	return attacks.resolve_incoming(self, seq, cause, {"source": source})

## Contestant `id`'s current target (an alive contestant other than itself), or -1: nobody else is in, `id` is
## out, or the attack loop is off. While two or more are alive every alive contestant has one.
func target_of(id: int) -> int:
	return contestants[id].target_id

## Every contestant's first target, as a copy: what each held before the first TARGET_CHANGED was logged.
## A presentation made mid-round starts from this and replays the log (empty with the attack loop off).
func initial_targets() -> PackedInt32Array:
	return attacks.initial_targets.duplicate()

## The survivors whose current target is `id`, in ascending id order (doc 47 B35-TARGET-007). `attackers_of(0)`
## is "who is aiming at the real player right now".
func attackers_of(id: int) -> Array[int]:
	var out: Array[int] = []
	for c in contestants:
		if c.alive and c.target_id == id:
			out.append(c.id)
	return out

## Selects how the real player's sends are aimed (BattleTargeting.Mode). Takes effect at once: the target is
## re-evaluated now, and every later send uses the mode; sends already made are untouched. Returns false, and
## changes nothing, for an unknown mode, one that is unavailable (Most Coins, until coin data exists), a
## player who is out, a finished round or a round without the attack loop. Selecting the current mode is a
## no-op that returns true.
func set_player_target_mode(mode: int) -> bool:
	if finished or not attacks.enabled or not get_player().alive or not target_mode_available(mode):
		return false
	if mode == player_target_mode:
		return true
	player_target_mode = mode
	attacks.set_target(self, PLAYER_ID, attacks.targeting.reevaluate(self, PLAYER_ID))
	return true

## Whether the player can select `mode` right now.
func target_mode_available(mode: int) -> bool:
	return mode >= 0 and mode < BattleTargeting.Mode.size() and attacks.targeting.mode_available(self, mode)

## `id`'s unresolved incoming enemies (QUEUED and ACTIVE, in send order) as read-only copies.
func get_incoming(id: int) -> Array[Dictionary]:
	return attacks.incoming(id)

## The real game reports the outcome of an enemy that is ACTIVE against the real player: the attack
## numbered `seq` (BattleAttack.seq, as in the SENT / INCOMING_ACTIVATED events and `get_incoming`) is
## resolved with `cause`, a BattleAttack.Resolution (DEFEATED_BY_PLAYER, DESPAWNED, LEVEL_TRANSITION,
## OTHER). Returns whether it was resolved; false, with nothing changed, if `seq` is unknown, is not
## aimed at the real player, is still QUEUED, was already resolved (a duplicate is harmless), or the
## round has ended. There is no timer on these: this is the only way an active attack on the real
## player ends, besides the player's elimination, a level transition and the end of the round.
func resolve_player_incoming(seq: int, cause: int) -> bool:
	return resolve_incoming_on(PLAYER_ID, seq, cause)

## The same, for the attack numbered `seq` on real-game contestant `target` (the player or a world-driven opponent).
func resolve_incoming_on(target: int, seq: int, cause: int) -> bool:
	if seq < 0 or seq >= attacks.history.size() or attacks.history[seq].target != target or not is_real(target):
		return false
	return attacks.resolve_incoming(self, seq, cause)

## Every ACTIVE attack on the real player ends with `cause`, spawned or not; QUEUED ones stay.
## (Tools and tests; a level transition uses `resolve_player_spawned`.) Returns how many were resolved.
func resolve_player_active(cause: int) -> int:
	return attacks.resolve_all(self, PLAYER_ID, cause, true)

## The real game's incoming enemy for the ACTIVE attack numbered `seq` is now in the player's level
## (called by BattleIncomingSpawner once the node is added). Returns false, with nothing changed,
## unless that attack is aimed at the real player, ACTIVE, not spawned before, and the round is open:
## one attack is never two enemies, however often this is called. Logs INCOMING_SPAWNED.
func report_player_incoming_spawned(seq: int) -> bool:
	return attacks.mark_spawned(self, seq)

## The same, for real-game contestant `target`.
func report_incoming_spawned(target: int, seq: int) -> bool:
	return attacks.mark_spawned(self, seq, target)

## The level the real player was in is gone (BattleHandler leaving the tree): every ACTIVE attack on
## them whose enemy was SPAWNED in it ends with `cause` (BattleAttack.Resolution.LEVEL_TRANSITION).
## ACTIVE attacks whose enemy never appeared were never in that level: they stay ACTIVE, keep their
## place in the order, and are delivered in the next level or room. QUEUED ones keep waiting too.
## Returns how many were resolved.
func resolve_player_spawned(cause: int) -> int:
	return resolve_spawned_on(PLAYER_ID, cause)

## The same, for real-game contestant `target` (a world-driven opponent leaving a level).
func resolve_spawned_on(target: int, cause: int) -> int:
	if not is_real(target):
		return 0
	return attacks.resolve_all(self, target, cause, true, true)

## Closes the round's enemy loop: everything still unresolved, on anyone, ends with ROUND_ENDED, and
## nothing more is sent or resolved. Runs by itself when the match finishes. Returns how many it resolved.
func end_round() -> int:
	return attacks.end_round(self)

## KOs a contestant now. Ignored if they are already out or the match is over.
func report_ko(id: int, cause: KoCause) -> void:
	var c := contestants[id]
	if finished or not c.alive:
		return
	c.ko_cause = cause
	_apply_kos([c] as Array[BattleContestant])

## Runs the bots forward until the match has a winner.
func resolve_to_end() -> void:
	var steps := 0
	while not finished and steps < MAX_RESOLVE_STEPS:
		step()
		steps += 1
	if not finished:
		# Safety cap: rank whoever is left with the standard rule.
		var left: Array[BattleContestant] = []
		for c in contestants:
			if c.alive:
				left.append(c)
		_sort_best_first(left)
		for i in left.size():
			left[i].placement = i + 1
		_finish(left[0].id)

# ---- ranking ----

func _apply_kos(group: Array[BattleContestant]) -> void:
	if group.is_empty():
		return
	_sort_best_first(group)
	var best_place := alive_count - group.size() + 1
	for i in group.size():
		var c := group[i]
		c.alive = false
		c.ko_tick = tick_count
		c.placement = best_place + i
		_log(EventType.KO, c.id, c.ko_cause)
		attacks.on_contestant_out(self, c.id)
	alive_count -= group.size()
	attacks.after_kos(self) # whoever aimed at someone who went out re-targets on this same tick
	if alive_count == 1:
		for c in contestants:
			if c.alive:
				c.placement = 1
				_finish(c.id)
	elif alive_count == 0:
		_finish(group[0].id)

func _log(type: EventType, id: int, a := 0, b := 0) -> void:
	record(type, id, a, b)

## Appends an event stamped with the current tick. `extra` adds named fields (the attack events'
## `kind` and `ko`).
func record(type: int, id: int, a := 0, b := 0, extra := {}) -> void:
	var e := {"tick": tick_count, "id": id, "type": type, "a": a, "b": b}
	e.merge(extra)
	events.append(e)

## Everything that decides a match, as plain data (for determinism checks). Includes the rng
## state, so any hidden extra rng use shows up.
func snapshot() -> Dictionary:
	var rows: Array = []
	for c in contestants:
		rows.append([c.alive, c.ko_tick, c.ko_cause, c.placement, c.levels_cleared, c.progress, c.power, c.time_left, c.skill, c.tiebreak])
	var targets: Array = []
	for c in contestants:
		targets.append(c.target_id)
	return {"tick": tick_count, "alive": alive_count, "finished": finished, "winner": winner_id,
		"rng_state": rng.state, "rows": rows, "attacks": attacks.snapshot(),
		"targets": targets, "player_target_mode": player_target_mode}

func _finish(winner: int) -> void:
	finished = true
	winner_id = winner
	attacks.end_round(self) # the round is over: nothing may stay active or queued into the next one

func _sort_best_first(arr: Array[BattleContestant]) -> void:
	arr.sort_custom(func(a: BattleContestant, b: BattleContestant) -> bool: return a.outranks(b))

## Current standing of `id` (1 = best). Alive contestants are ranked against the other
## survivors with the normal rule; KO'd contestants return their final placement.
func get_provisional_rank(id := PLAYER_ID) -> int:
	var c := contestants[id]
	if not c.alive:
		return c.placement
	var rank := 1
	for other in contestants:
		if other.alive and other != c and other.outranks(c):
			rank += 1
	return rank

## Contestant ids ordered by placement (1st first). Only complete once `finished`.
func get_ranking() -> Array[int]:
	var sorted: Array[BattleContestant] = contestants.duplicate()
	sorted.sort_custom(func(a: BattleContestant, b: BattleContestant) -> bool:
		return a.placement < b.placement)
	var out: Array[int] = []
	for c in sorted:
		out.append(c.id)
	return out

func describe_result() -> String:
	var p := get_player()
	var lines := "[Battle] seed=%d ticks=%d winner=#%d player: place %d/%d (%s, %d levels)" % [
		seed_value, tick_count, winner_id, p.placement, CONTESTANT_COUNT,
		KoCause.keys()[p.ko_cause], p.levels_cleared]
	var top := get_ranking().slice(0, 5)
	lines += "\n[Battle] top: " + ", ".join(top.map(func(i): return "%d.#%d" % [contestants[i].placement, i]))
	return lines
