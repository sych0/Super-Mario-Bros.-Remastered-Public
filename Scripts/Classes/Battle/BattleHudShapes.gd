class_name BattleHudShapes
extends RefCounted
## Rounded boxes for the Battle canvas, with hairline borders. A StyleBox's border is at least one canvas unit wide;
## the reference's lines are about half a unit (2 device px at 1080p), so the box is drawn through a scaled transform:
## a 1-unit border at scale k is k units wide. Pure drawing on a CanvasItem; no state.

## Draws `rect` filled with `fill`, with a border of `hairline` canvas units in `edge` and corners of `radius` units
## (a pill when radius >= half the height).
static func box(ci: CanvasItem, rect: Rect2, fill: Color, edge: Color, radius: float, hairline := 0.5) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = edge
	s.set_border_width_all(1)
	s.set_corner_radius_all(int(ceilf(minf(radius, minf(rect.size.x, rect.size.y) / 2.0) / hairline)))
	s.anti_aliasing = true
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2(hairline, hairline))
	ci.draw_style_box(s, Rect2(rect.position / hairline, rect.size / hairline))
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## A pill: fully rounded ends.
static func pill(ci: CanvasItem, rect: Rect2, fill: Color, edge: Color, hairline := 0.5) -> void:
	box(ci, rect, fill, edge, rect.size.y / 2.0, hairline)
