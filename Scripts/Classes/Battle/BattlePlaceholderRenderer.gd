class_name BattlePlaceholderRenderer
extends BattlePreviewRenderer
## Placeholder preview in the look of the reference's opponent cells: purple-blue sky, brick
## ground, green hills that scroll with the contestant's level progress, and a small Mario
## kept at the centre (the camera follows him), taller when powered up.

const SKY := Color(0.53, 0.53, 1.0)
const GROUND := Color(0.62, 0.36, 0.08)
const GROUND_DARK := Color(0.25, 0.12, 0.02)
const HILL := Color(0.05, 0.6, 0.1)
const GROUND_H := 32.0
const HILL_SPACING := 176.0
const LEVEL_SCROLL := 1056.0 # logical px a full level's progress scrolls the background
const MARIO_COLORS := [Color(0.85, 0.15, 0.1), Color(0.85, 0.15, 0.1), Color(1.0, 0.75, 0.2)]

func draw(canvas: CanvasItem, c: BattleContestant, size: Vector2) -> void:
	canvas.draw_rect(Rect2(Vector2.ZERO, size), SKY)
	var ground_y := size.y - GROUND_H
	var scroll := clampf(c.progress, 0.0, 1.0) * LEVEL_SCROLL + c.levels_cleared * 37.0
	# Hills (triangles) repeat and scroll.
	var first := floori(scroll / HILL_SPACING)
	for i in range(first, first + int(size.x / HILL_SPACING) + 2):
		var x := i * HILL_SPACING - scroll + 24.0
		canvas.draw_colored_polygon(PackedVector2Array([
			Vector2(x, ground_y), Vector2(x + 40, ground_y - 40), Vector2(x + 80, ground_y)]), HILL)
	canvas.draw_rect(Rect2(0, ground_y, size.x, GROUND_H), GROUND)
	canvas.draw_rect(Rect2(0, ground_y, size.x, 3), GROUND.lightened(0.4))
	for i in range(floori(scroll / 16.0), floori(scroll / 16.0) + int(size.x / 16.0) + 2):
		canvas.draw_rect(Rect2(i * 16.0 - scroll, ground_y + 3, 2, GROUND_H - 3), GROUND_DARK)
	var height := 16.0 if c.power == 0 else 32.0
	canvas.draw_rect(Rect2(size.x / 2.0 - 8.0, ground_y - height, 16, height), MARIO_COLORS[clampi(c.power, 0, 2)])
