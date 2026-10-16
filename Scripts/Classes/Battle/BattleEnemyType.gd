class_name BattleEnemyType
extends RefCounted
## Battle's own list of enemy types: plain integers and a data table, never scene nodes or
## PackedScenes. The real game's enemies are mapped to a kind by their script path at the moment
## they are defeated (`kind_for_script`); everything after that (events, queues, pressure, bots)
## only ever sees the kind. Adding an enemy type later is one `Kind` value plus one table row.
##
## Table fields:
##   name         for logs and later UI
##   script       the game script that identifies it
##   weight       hazard pressure it adds to a simulated bot while it is ACTIVE
##   active_ticks how long it stays ACTIVE (Battle seconds) before it is RESOLVED
##   bot_spawn    relative chance that a simulated bot's defeat is of this kind

enum Kind {NONE, GOOMBA, KOOPA}

const DATA := {
	Kind.GOOMBA: {"name": "GOOMBA", "script": "res://Scripts/Classes/Entities/Enemies/Goomba.gd", "weight": 0.5, "active_ticks": 5, "bot_spawn": 0.7},
	Kind.KOOPA: {"name": "KOOPA", "script": "res://Scripts/Classes/Entities/Enemies/KoopaTroopa.gd", "weight": 0.8, "active_ticks": 7, "bot_spawn": 0.3},
}

static func is_supported(kind: int) -> bool:
	return DATA.has(kind)

## Every supported kind, in a fixed (ascending) order.
static func kinds() -> Array[int]:
	var out: Array[int] = []
	for k in DATA:
		out.append(k)
	out.sort()
	return out

## The Battle kind of the game script at `path`, or NONE if it is not a supported enemy
## (shells, piranha plants, bosses... are not sent yet).
static func kind_for_script(path: String) -> int:
	for k in DATA:
		if DATA[k].script == path:
			return k
	return Kind.NONE

static func kind_name(kind: int) -> String:
	return DATA[kind].name if DATA.has(kind) else "NONE"

static func weight(kind: int) -> float:
	return DATA[kind].weight if DATA.has(kind) else 0.0

static func active_ticks(kind: int) -> int:
	return DATA[kind].active_ticks if DATA.has(kind) else 0

## The kind a simulated bot defeats for a uniform roll `u` in [0, 1): weighted by `bot_spawn`.
static func pick_for_bot(u: float) -> int:
	var total := 0.0
	var ks := kinds()
	for k in ks:
		total += DATA[k].bot_spawn
	var acc := 0.0
	for k in ks:
		acc += DATA[k].bot_spawn / total
		if u < acc:
			return k
	return ks[ks.size() - 1]
