class_name BattleHudLayout
extends RefCounted
## Pure geometry for the Battle screen. The real player's gameplay keeps its classic
## 256x240 area centred in the game's native 16:9 viewport; opponent preview slots and the
## status blocks live in the two side panels. No scene-tree access, so it is unit-testable.
## All proportions are constants here so the arrangement can be tuned in one place.

const GAME_SIZE := Vector2(256, 240)
const OPPONENTS := 34
const SLOTS_PER_SIDE := 17
const COLUMNS := 3
const MARGIN := 2.0
const GAP := 2.0
const TOP := 14.0
const STATUS_TOP := 172.0

## Returns {viewport, center, left, right, slots[34], cell, status_left, status_right}.
## `slots[i]` is the preview rect for contestant i + 1 (1..17 left panel, 18..34 right).
static func compute(viewport: Vector2) -> Dictionary:
	var panel_w := maxf((viewport.x - GAME_SIZE.x) / 2.0, 0.0)
	var left := Rect2(0, 0, panel_w, viewport.y)
	var center := Rect2(panel_w, 0, GAME_SIZE.x, viewport.y)
	var right := Rect2(center.end.x, 0, panel_w, viewport.y)
	var cell_w := floorf((panel_w - 2.0 * MARGIN - (COLUMNS - 1) * GAP) / COLUMNS)
	var cell := Vector2(cell_w, floorf(cell_w * GAME_SIZE.y / GAME_SIZE.x))
	var used_w := COLUMNS * cell.x + (COLUMNS - 1) * GAP
	var slots: Array[Rect2] = []
	for i in OPPONENTS:
		var panel := left if i < SLOTS_PER_SIDE else right
		var k := i % SLOTS_PER_SIDE
		var col := k % COLUMNS
		var row := k / COLUMNS
		var x := panel.position.x + floorf((panel.size.x - used_w) / 2.0) + col * (cell.x + GAP)
		var y := TOP + row * (cell.y + GAP)
		slots.append(Rect2(Vector2(x, y), cell))
	return {
		"viewport": viewport, "center": center, "left": left, "right": right,
		"slots": slots, "cell": cell,
		"status_left": Rect2(left.position.x + MARGIN, STATUS_TOP, panel_w - 2.0 * MARGIN, viewport.y - STATUS_TOP - MARGIN),
		"status_right": Rect2(right.position.x + MARGIN, STATUS_TOP, panel_w - 2.0 * MARGIN, viewport.y - STATUS_TOP - MARGIN),
	}
