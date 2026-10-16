class_name BattleHudLayout
extends RefCounted
## Pure geometry and colours for the Battle screen (doc 38 section 4, reshaped by the UI fidelity pass,
## doc 50, to the measurements of doc 47 section 2). The Battle canvas is the 16:9 480x270 logical screen of
## the reference (1080p / 4); the real player's classic 256x240 game runs in its own SubViewport and is shown
## as the centre window, cropped on the display to 256x224 (the viewport itself, its camera, walls and enemy
## activation never change). Everything the screen draws is placed from the constants below, so matching the
## framing to the reference means editing numbers here only. Each side panel is 3 columns x 6 rows of portrait
## cells with the top inner-corner cell replaced by a badge (course on the left, alive count on the right),
## which leaves 17 opponent cells per side. No scene-tree access, so it is testable.
##
## Many values are not whole logical pixels (the reference's cells are 131x166 device px = 32.75x41.5): they are
## exact at the 4x of a 1080p window and snap to device pixels at other sizes. Doc 47 reference ids are in the
## comments (B35-LAYOUT-001...006, B35-TARGET-005, B35-INCOMING-001, B35-TIMER-009, B35-COIN-001/002).

const CANVAS := Vector2(480, 270)
const GAME_SIZE := Vector2(256, 240) ## the classic gameplay viewport, never resized
## Rows of the viewport that are not shown: the top and bottom 8 (the NES overscan reading of doc 47 LAYOUT-001; which 16 rows
## SMB35 hides was not measured). The classic HUD row lives in the hidden top rows, and the Battle HUD replaces it.
const GAME_CROP_TOP := 8.0
const GAME_CROP_BOTTOM := 8.0
const GAME_RECT := Rect2(112, 8, 256, 224) ## the visible window (B35-LAYOUT-001)
const FRAME_RECT := Rect2(108, 0, 264, 268) ## the gold frame around the window and the two strips
const STRIP_A := Rect2(111.5, 236, 257, 12) ## the incoming bar (B35-LAYOUT-003)
const STRIP_B := Rect2(111.5, 249, 257, 13) ## the status strip
const PANEL_W := 108.0 ## the left panel is x 0..108, the right one x 372..480
const OPPONENTS := 34
const SLOTS_PER_SIDE := 17
const COLUMNS := 3
const ROWS := 6
const CELL := Vector2(32.75, 41.5) ## 131 x 166 device px at 1080p (B35-LAYOUT-004)
const COLUMN_PITCH := 34.0
const ROW_PITCH := 43.0
const GRID_TOP := 10.5
const GRID_X_LEFT := 1.25
const GRID_X_RIGHT := 377.25
const BADGE_LEFT := Rect2(72.5, 0, 30, 30) ## COURSE
const BADGE_RIGHT := Rect2(376.25, 0, 30.75, 43.75) ## ALIVE

# ---- the HUD inside the window (B35-LAYOUT-002), in canvas units ------------------------------------------------
const HUD_COINS := Rect2(115, 10, 35, 9) ## the coin counter (B35-COIN-001)
const HUD_ITEM_BOX := Rect2(112.5, 20, 40, 40) ## the item box (B35-COIN-002): reserved, empty until the coin milestone
const HUD_TIMER := Rect2(296, 10, 69, 18) ## clock icon and the large timer (B35-TIMER-009)
## The targeting selector's cross (B35-TARGET-005): pill rects and the centre glyph, measured at 1080p and divided by 4.
const SELECTOR_LOWEST_TIME := Rect2(225, 13.75, 28.75, 8.75)
const SELECTOR_RANDOM := Rect2(200, 28.75, 28.75, 8.25)
const SELECTOR_MOST_COINS := Rect2(252.5, 28.75, 42.5, 8.25)
const SELECTOR_ATTACKERS := Rect2(225, 42, 28.75, 8.5)
const SELECTOR_CENTER := Vector2(239.5, 32.5)

# ---- colours: measured (doc 47 LAYOUT-006), in 8 bits ----------------------------------------------------------------
const WALLPAPER := Color8(255, 190, 0)
const FRAME_LIGHT := Color8(255, 217, 56)
const FRAME_DARK := Color8(255, 182, 0)
const OUTLINE := Color8(59, 51, 33) ## the thin dark line just outside the window, and the strips' borders
const OUTLINE_WIDTH := 0.5

## Returns {canvas, game, game_size, game_crop, frame, frame_inner, strip_a, strip_b, left, right, slots[34], cell, top,
## badge_left, badge_right, hud}. `slots[i]` is the preview rect for contestant i + 1 (1..17 left panel, 18..34 right).
## `hud` holds the in-window element rects (`coins`, `item_box`, `timer`, `selector`: {lowest_time, random, most_coins,
## attackers, center, cross}).
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
			slots.append(Rect2(Vector2(x0 + col * COLUMN_PITCH, GRID_TOP + row * ROW_PITCH), CELL))
	var cross := SELECTOR_RANDOM.merge(SELECTOR_LOWEST_TIME).merge(SELECTOR_MOST_COINS).merge(SELECTOR_ATTACKERS)
	return {
		"canvas": CANVAS, "game": GAME_RECT, "game_size": GAME_SIZE, "game_crop": Vector2(0, GAME_CROP_TOP),
		"frame": FRAME_RECT, "frame_inner": FRAME_RECT.grow(-2.0),
		"strip_a": STRIP_A, "strip_b": STRIP_B,
		"left": left, "right": right, "slots": slots, "cell": CELL, "top": GRID_TOP,
		"badge_left": BADGE_LEFT, "badge_right": BADGE_RIGHT,
		"hud": {
			"coins": HUD_COINS, "item_box": HUD_ITEM_BOX, "timer": HUD_TIMER,
			"selector": {"lowest_time": SELECTOR_LOWEST_TIME, "random": SELECTOR_RANDOM, "most_coins": SELECTOR_MOST_COINS,
				"attackers": SELECTOR_ATTACKERS, "center": SELECTOR_CENTER, "cross": cross},
		},
	}
