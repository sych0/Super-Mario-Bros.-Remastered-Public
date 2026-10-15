class_name BattlePlaceholderRenderer
extends BattlePreviewRenderer
## Placeholder preview: sky, scrolling ground ticks, a goal marker and a Mario-coloured block
## that moves with the contestant's level progress and grows with power state.

const SKY := Color(0.36, 0.58, 0.99)
const GROUND := Color(0.65, 0.3, 0.1)
const GROUND_H := 48.0
const MARIO_COLORS := [Color(0.85, 0.15, 0.1), Color(0.85, 0.15, 0.1), Color(1.0, 0.75, 0.2)]

func draw(canvas: CanvasItem, c: BattleContestant, size: Vector2) -> void:
	canvas.draw_rect(Rect2(Vector2.ZERO, size), SKY)
	var ground_y := size.y - GROUND_H
	canvas.draw_rect(Rect2(0, ground_y, size.x, GROUND_H), GROUND)
	# Ground ticks scroll left as the contestant advances through the level.
	var scroll := fposmod(c.progress * 192.0, 48.0)
	for i in 7:
		canvas.draw_rect(Rect2(i * 48.0 - scroll, ground_y, 4, GROUND_H), GROUND.darkened(0.35))
	# Goal pole at the far right.
	canvas.draw_rect(Rect2(size.x - 28, ground_y - 96, 6, 96), Color.WHITE)
	var height := 16.0 if c.power == 0 else 32.0
	var x := 16.0 + clampf(c.progress, 0.0, 1.0) * (size.x - 64.0)
	canvas.draw_rect(Rect2(x, ground_y - height, 16, height), MARIO_COLORS[clampi(c.power, 0, 2)])
