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
enum EventType {HIT, POWER_UP, LEVEL_CLEAR, KO}

const CONTESTANT_COUNT := 35
const PLAYER_ID := 0
const START_TIME := 600
const MAX_RESOLVE_STEPS := 20000

## The active match. Static so it outlives level scene changes (like BooRaceHandler state).
static var current: BattleSession = null

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
var events: Array[Dictionary] = []

## Creates a fresh match and makes it the current one. Nothing is inherited from before.
static func begin(seed_value_: int) -> BattleSession:
	current = BattleSession.new(seed_value_)
	return current

static func clear() -> void:
	current = null

func _init(seed_value_: int = 0) -> void:
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

func get_player() -> BattleContestant:
	return contestants[PLAYER_ID]

## Advances the match one fixed second: match timers, bots, and any resulting KOs.
func step() -> void:
	if finished:
		return
	tick_count += 1
	var knocked_out: Array[BattleContestant] = []
	for c in contestants:
		if not c.alive:
			continue
		var cause := KoCause.NONE
		if c.is_bot:
			var power_before := c.power
			var cleared_before := c.levels_cleared
			cause = BattleBotSimulator.step_bot(c, tick_count, rng)
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
	_apply_kos(knocked_out)

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
	alive_count -= group.size()
	if alive_count == 1:
		for c in contestants:
			if c.alive:
				c.placement = 1
				_finish(c.id)
	elif alive_count == 0:
		_finish(group[0].id)

func _log(type: EventType, id: int, a := 0, b := 0) -> void:
	events.append({"tick": tick_count, "id": id, "type": type, "a": a, "b": b})

## Everything that decides a match, as plain data (for determinism checks). Includes the rng
## state, so any hidden extra rng use shows up.
func snapshot() -> Dictionary:
	var rows: Array = []
	for c in contestants:
		rows.append([c.alive, c.ko_tick, c.ko_cause, c.placement, c.levels_cleared, c.progress, c.power, c.time_left, c.skill, c.tiebreak])
	return {"tick": tick_count, "alive": alive_count, "finished": finished, "winner": winner_id,
		"rng_state": rng.state, "rows": rows}

func _finish(winner: int) -> void:
	finished = true
	winner_id = winner

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
