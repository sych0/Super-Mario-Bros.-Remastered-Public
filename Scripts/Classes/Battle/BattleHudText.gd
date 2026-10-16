class_name BattleHudText
extends RefCounted
## Text for the Battle canvas, from the project's one bitmap font (FontMain; doc 50, typography). No other
## typeface is used on this screen. The font's glyph cell is 16x16 with the character's ink in its middle:
## 7x7 px at (4,4), and FontMain squeezes the advance to 8 px. So a string of n characters is (8n - 1) px of ink
## wide and 7 tall at scale 1, and every position here is the position of that INK box: layout code can think in
## the pixels it sees. Outlines are the glyphs redrawn one pixel round the face (a bitmap font has none of its own).
## Pure drawing helpers on a CanvasItem; no scene tree, no state.

const ADVANCE := 8.0
const INK_H := 7.0
const INK_INSET := 4.0 ## where the ink starts inside the 16x16 cell, in x and y
const CELL := 16.0
const OUTLINE_DIRS: Array[Vector2] = [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1),
	Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]

## The width of `text`'s ink at `scale`.
static func ink_width(text: String, scale: float) -> float:
	return maxf(ADVANCE * text.length() - 1.0, 0.0) * scale

static func ink_height(scale: float) -> float:
	return INK_H * scale

## The largest scale (up to `wanted`) at which `text` fits in `max_width`.
static func fit_scale(text: String, max_width: float, wanted: float) -> float:
	if text.is_empty():
		return wanted
	return minf(wanted, max_width / maxf(ink_width(text, 1.0), 1.0))

## Draws `text` with the top-left of its ink at `top_left`. `outline_px` > 0 first draws it in `outline` at the
## eight surrounding offsets.
static func draw(ci: CanvasItem, font: Font, text: String, top_left: Vector2, scale: float, color: Color,
		outline := Color(0, 0, 0, 0), outline_px := 0.0) -> void:
	if font == null or text.is_empty() or scale <= 0.0:
		return
	if outline.a > 0.0 and outline_px > 0.0:
		for dir in OUTLINE_DIRS:
			_string(ci, font, text, top_left + dir * outline_px, scale, outline)
	_string(ci, font, text, top_left, scale, color)

## Draws `text` with its ink box placed inside `rect`: `align` is 0..1 in each axis (0.5 = centred).
static func draw_in(ci: CanvasItem, font: Font, text: String, rect: Rect2, scale: float, color: Color,
		align := Vector2(0.5, 0.5), outline := Color(0, 0, 0, 0), outline_px := 0.0) -> void:
	var box := Vector2(ink_width(text, scale), ink_height(scale))
	var free := rect.size - box
	draw(ci, font, text, rect.position + Vector2(free.x * align.x, free.y * align.y), scale, color, outline, outline_px)

static func _string(ci: CanvasItem, font: Font, text: String, ink_top_left: Vector2, scale: float, color: Color) -> void:
	ci.draw_set_transform(ink_top_left - Vector2(INK_INSET, INK_INSET) * scale, 0.0, Vector2(scale, scale))
	ci.draw_string(font, Vector2(0, CELL), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, color)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
