class_name BattleHudLayout
extends RefCounted
## Pure geometry for the Battle screen, modelled on the Super Mario Bros. 35 reference: the
## real player's classic 256x240 gameplay area stays centred in the game's native 16:9
## viewport; each side panel is 3 columns x 6 rows of portrait preview cells (~0.78 aspect),
## with the top inner-corner cell replaced by a badge (course on the left, alive count on the
## right). That leaves 17 opponent cells per side. No scene-tree access, so it is testable.

const GAME_SIZE := Vector2(256, 240)
const OPPONENTS := 34
const SLOTS_PER_SIDE := 17
const COLUMNS := 3
const ROWS := 6
const MARGIN := 1.0
const GAP := 2.0
const BOTTOM_MARGIN := 2.0
const CELL_ASPECT := 129.0 / 165.0 # width / height, measured from the reference

## Returns {viewport, center, left, right, slots[34], cell, top, badge_left, badge_right,
## status_left, status_right}. `slots[i]` is the preview rect for contestant i + 1
## (1..17 left panel, 18..34 right).
static func compute(viewport: Vector2) -> Dictionary:
	var panel_w := maxf((viewport.x - GAME_SIZE.x) / 2.0, 0.0)
	var left := Rect2(0, 0, panel_w, viewport.y)
	var center := Rect2(panel_w, 0, GAME_SIZE.x, viewport.y)
	var right := Rect2(center.end.x, 0, panel_w, viewport.y)
	var cell_w := floorf((panel_w - 2.0 * MARGIN - (COLUMNS - 1) * GAP) / COLUMNS)
	var cell := Vector2(cell_w, floorf(cell_w / CELL_ASPECT))
	var grid_h := ROWS * cell.y + (ROWS - 1) * GAP
	var top := viewport.y - BOTTOM_MARGIN - grid_h # free strip above the grid (status text)
	var used_w := COLUMNS * cell.x + (COLUMNS - 1) * GAP
	var slots: Array[Rect2] = []
	var cells := {}
	for side in 2:
		var panel := left if side == 0 else right
		var x0 := panel.position.x + floorf((panel.size.x - used_w) / 2.0)
		# Cell index 0..17 in reading order; the inner top corner (left: col 2, right: col 0) is the badge.
		var badge_index := 2 if side == 0 else 0
		var count := 0
		for k in COLUMNS * ROWS:
			var col := k % COLUMNS
			var row := k / COLUMNS
			var rect := Rect2(Vector2(x0 + col * (cell.x + GAP), top + row * (cell.y + GAP)), cell)
			if k == badge_index:
				cells[side] = rect
				continue
			slots.append(rect)
			count += 1
	var badge_l: Rect2 = cells[0]
	var badge_r: Rect2 = cells[1]
	# Badges hang down from the top edge to just past the first row, like the reference.
	badge_l = Rect2(badge_l.position.x, 0, badge_l.size.x, badge_l.end.y - cell.y * 0.35)
	badge_r = Rect2(badge_r.position.x, 0, badge_r.size.x, badge_r.end.y)
	var strip_h := maxf(top - 2.0, 0.0)
	return {
		"viewport": viewport, "center": center, "left": left, "right": right,
		"slots": slots, "cell": cell, "top": top,
		"badge_left": badge_l, "badge_right": badge_r,
		# Text strips above the grid, beside each badge.
		"status_left": Rect2(left.position.x + MARGIN, 1, badge_l.position.x - left.position.x - MARGIN - 1, strip_h),
		"status_right": Rect2(badge_r.end.x + 1, 1, right.end.x - badge_r.end.x - MARGIN - 1, strip_h),
	}
