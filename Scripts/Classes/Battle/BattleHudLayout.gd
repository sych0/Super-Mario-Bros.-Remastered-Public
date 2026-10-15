class_name BattleHudLayout
extends RefCounted
## Pure geometry for the Battle screen (doc 38, section 4). The Battle canvas is the 16:9
## 480x270 logical screen of the reference; the real player's classic 256x240 game runs in its
## own SubViewport shown as the centre window. Everything the screen draws is placed from the
## constants below, so matching the framing to reference.jpg means editing numbers here only.
## Each side panel is 3 columns x 6 rows of portrait cells (the reference's 129:165 aspect),
## with the top inner-corner cell replaced by a badge (course on the left, alive count on the
## right). That leaves 17 opponent cells per side. No scene-tree access, so it is testable.

const CANVAS := Vector2(480, 270)
const GAME_SIZE := Vector2(256, 240) ## the classic gameplay viewport, never resized
const GAME_RECT := Rect2(112, 3, 256, 240) ## where the game window sits on the canvas (whole pixels)
const FRAME_RECT := Rect2(108, 0, 264, 268) ## the gold frame around the game window
const STRIP_A := Rect2(112, 245, 256, 11) ## progress (later the incoming queue)
const STRIP_B := Rect2(112, 257, 256, 11) ## coins / item (later)
const PANEL_W := 108.0 ## the left panel is x 0..108, the right one x 372..480
const OPPONENTS := 34
const SLOTS_PER_SIDE := 17
const COLUMNS := 3
const ROWS := 6
const CELL := Vector2(32, 41)
const GAP := 2.0
const GRID_TOP := 12.0 ## free strip above the grids (TIME / RANK text, badges hang through it)
const GRID_X_LEFT := 4.0
const GRID_X_RIGHT := 376.0
const BADGE_LEFT := Rect2(72, 0, 32, 30) ## course
const BADGE_RIGHT := Rect2(376, 0, 32, 44) ## alive count

## Returns {canvas, game, frame, strip_a, strip_b, left, right, slots[34], cell, top,
## badge_left, badge_right, status_left, status_right}. `slots[i]` is the preview rect for
## contestant i + 1 (1..17 left panel, 18..34 right).
static func compute() -> Dictionary:
	var left := Rect2(0, 0, PANEL_W, CANVAS.y)
	var right := Rect2(CANVAS.x - PANEL_W, 0, PANEL_W, CANVAS.y)
	var slots: Array[Rect2] = []
	for side in 2:
		var x0 := GRID_X_LEFT if side == 0 else GRID_X_RIGHT
		# Cell index 0..17 in reading order; the inner top corner (left: col 2, right: col 0) is the badge.
		var badge_index := COLUMNS - 1 if side == 0 else 0
		for k in COLUMNS * ROWS:
			if k == badge_index:
				continue
			var col := k % COLUMNS
			var row := k / COLUMNS
			slots.append(Rect2(Vector2(x0 + col * (CELL.x + GAP), GRID_TOP + row * (CELL.y + GAP)), CELL))
	var grid_w := COLUMNS * CELL.x + (COLUMNS - 1) * GAP
	return {
		"canvas": CANVAS, "game": GAME_RECT, "frame": FRAME_RECT, "strip_a": STRIP_A, "strip_b": STRIP_B,
		"left": left, "right": right, "slots": slots, "cell": CELL, "top": GRID_TOP,
		"badge_left": BADGE_LEFT, "badge_right": BADGE_RIGHT,
		# One text line each in the strip above the grid, beside the badge.
		"status_left": Rect2(GRID_X_LEFT, 0, BADGE_LEFT.position.x - GRID_X_LEFT - GAP, GRID_TOP),
		"status_right": Rect2(BADGE_RIGHT.end.x + GAP, 0, GRID_X_RIGHT + grid_w - BADGE_RIGHT.end.x - GAP, GRID_TOP),
	}
