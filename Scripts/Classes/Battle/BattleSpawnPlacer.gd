class_name BattleSpawnPlacer
extends RefCounted
## Where an incoming enemy may appear in the real player's level (doc 45 section 8, doc 46). Pure: it
## sees the world only through two probe callables, so the same rule runs on live physics in the game
## and on ASCII maps in tests, and the same inputs always give the same answer.
##
##   solid(cell: Vector2i) -> bool   is the 16 px cell solid terrain (tiles, blocks, pipes)?
##   blocked(rect: Rect2) -> bool    does an enemy or shell body overlap this world rect?
##
## The rule, in a fixed order (the first candidate that passes wins):
##   1. Sides. AHEAD first: columns from the last one fully inside the view's right edge, moving toward
##      Mario, while the column centre is at least MIN_AHEAD px ahead of him; the enemy faces left,
##      toward him. BEHIND only if ahead has nothing: columns from the first one fully inside the left
##      edge, moving toward Mario, while the centre is at least MIN_BEHIND px behind him; facing right.
##   2. A floor in the column: a solid cell with HEADROOM_CELLS empty cells above it (so the body is not
##      in terrain), its surface inside [view top + HUD_BAND + 32, view bottom] (fully visible, below
##      the HUD). Of several, the one nearest Mario's feet; on a tie, the lower. A column with no floor
##      (a pit, the inside of a wall) is skipped: nothing ever spawns over a pit.
##   3. Footing: the next column toward Mario has a floor at the same height (not a lip over a gap).
##   4. Clearance: no enemy or shell body in the box above the spot, no other live incoming enemy
##      within SEPARATION px on that floor, and not overlapping Mario's body.
## Nothing found: a failure with a reason. The caller holds the attack and retries; never forces it.
## `relaxed` (after the caller has held an attack for a while): MIN_AHEAD / MIN_BEHIND shrink and
## footing is not required. A floor, visibility and clearance are still required.

const TILE := 16
const HALF_TILE := 8
const HUD_BAND := 32
const MIN_AHEAD := 80
const MIN_BEHIND := 112
const RELAXED_AHEAD := 48
const RELAXED_BEHIND := 80
const SEPARATION := 32
const HEADROOM_CELLS := 2 ## a Goomba is 16 px tall, a Koopa 24: two empty cells hold either
const CLEAR_BOX := Rect2(-12, -22, 24, 20) ## relative to the feet: must hold no enemy or shell body
const BODY_BOX := Rect2(-8, -24, 16, 24) ## relative to the feet: the spawned enemy's body
const MARIO_BOX := Rect2(-12, -32, 24, 32) ## relative to Mario's feet: his body, big or small

## Finds a spot. Returns {ok: true, position: Vector2 (feet), direction: -1 | 1, side: "ahead" | "behind",
## column: int} or {ok: false, reason: String}. `others` are the feet positions of live incoming enemies.
static func place(view: Rect2, mario: Vector2, solid: Callable, blocked: Callable, others: Array = [], relaxed := false) -> Dictionary:
	var min_ahead := RELAXED_AHEAD if relaxed else MIN_AHEAD
	var min_behind := RELAXED_BEHIND if relaxed else MIN_BEHIND
	var tally := {"columns": 0, "floors": 0, "footing": 0}
	# ahead: from the right edge toward Mario
	var first := int(floor(view.end.x / TILE)) - 1
	var last := int(ceil(view.position.x / TILE))
	for cx in range(first, last - 1, -1):
		if cx * TILE + HALF_TILE < mario.x + min_ahead:
			break
		var spot := _try_column(cx, -1, view, mario, solid, blocked, others, relaxed, tally)
		if not spot.is_empty():
			spot.side = "ahead"
			return spot
	# behind: from the left edge toward Mario
	for cx in range(last, first + 1):
		if cx * TILE + HALF_TILE > mario.x - min_behind:
			break
		var spot := _try_column(cx, 1, view, mario, solid, blocked, others, relaxed, tally)
		if not spot.is_empty():
			spot.side = "behind"
			return spot
	var reason := "blocked"
	if tally.columns == 0:
		reason = "no column far enough from Mario"
	elif tally.floors == 0:
		reason = "no visible floor"
	elif tally.footing == 0:
		reason = "no footing"
	return {"ok": false, "reason": reason}

## The floor surface y in column `cx` (nearest Mario's feet; on a tie the lower), or INF.
static func floor_in(cx: int, view: Rect2, mario_y: float, solid: Callable) -> float:
	var top := int(ceil((view.position.y + HUD_BAND + 32) / TILE))
	var bottom := int(floor(view.end.y / TILE))
	var best := INF
	for cy in range(top, bottom + 1):
		if is_floor(cx, cy, solid):
			var y := float(cy * TILE)
			if best == INF or absf(y - mario_y) < absf(best - mario_y) or (absf(y - mario_y) == absf(best - mario_y) and y > best):
				best = y
	return best

## A solid cell with HEADROOM_CELLS empty cells above it.
static func is_floor(cx: int, cy: int, solid: Callable) -> bool:
	if not solid.call(Vector2i(cx, cy)):
		return false
	for h in range(1, HEADROOM_CELLS + 1):
		if solid.call(Vector2i(cx, cy - h)):
			return false
	return true

static func _try_column(cx: int, toward: int, view: Rect2, mario: Vector2, solid: Callable, blocked: Callable, others: Array, relaxed: bool, tally: Dictionary) -> Dictionary:
	tally.columns += 1
	var y := floor_in(cx, view, mario.y, solid)
	if y == INF:
		return {}
	tally.floors += 1
	var cy := int(y / TILE)
	if not relaxed and not is_floor(cx + toward, cy, solid):
		return {}
	tally.footing += 1
	var pos := Vector2(cx * TILE + HALF_TILE, y)
	if blocked.call(Rect2(pos + CLEAR_BOX.position, CLEAR_BOX.size)):
		return {}
	for o in others:
		var other: Vector2 = o
		if absf(other.x - pos.x) < SEPARATION and absf(other.y - pos.y) < TILE:
			return {}
	if Rect2(pos + BODY_BOX.position, BODY_BOX.size).intersects(Rect2(mario + MARIO_BOX.position, MARIO_BOX.size)):
		return {}
	return {"ok": true, "position": pos, "direction": toward, "column": cx}
