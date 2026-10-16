class_name BattleTargetReticle
extends Control
## The red four-corner bracket on the real player's current target pane (doc 47 B35-TARGET-002): thick
## L-shaped corners just outside the pane's edge, over the pane and under the attack layer. A view only:
## BattleScreen tells it which pane (`set_target`, 1..34, or 0/-1 for none) and it draws; it reads no
## session and owns no state about the match. It redraws only when the target changes.
##
## Sizes are on the 480x270 canvas (4 device px per unit at 1080p): arms are a quarter of the pane's width,
## about 3-4 device px thick at 1080p, and sit in the 2-unit gap between panes, so they never cover the picture.

const COLOR := Color(1.0, 0.1, 0.1, 1.0) ## pure red: r > 225, g < 50, b < 70 in 8 bits (measured on the reference)
const THICKNESS := 1.0
const ARM_FRACTION := 0.25

var layout := {}
var target := 0 ## the contestant id the bracket is on, or 0 for none

func _init(layout_: Dictionary = {}) -> void:
	name = "TargetReticle"
	layout = layout_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = BattleHudLayout.CANVAS
	visible = false

## Puts the bracket on opponent `id` (1..34); anything else hides it. Cheap to call every frame.
func set_target(id: int) -> void:
	var shown := id >= 1 and id <= BattleHudLayout.OPPONENTS
	var next := id if shown else 0
	if next == target and shown == visible:
		return
	target = next
	visible = shown
	queue_redraw()

## The four brackets' corner rectangles for the pane `rect`: [top-left horizontal, top-left vertical, ...],
## eight rects, each just outside the pane edge. Pure, so tests can check the geometry.
static func corner_rects(rect: Rect2) -> Array[Rect2]:
	var arm := rect.size.x * ARM_FRACTION
	var t := THICKNESS
	var out: Array[Rect2] = []
	var o := rect.grow(t) # the outer edge of the bracket
	# top-left
	out.append(Rect2(o.position, Vector2(arm + t, t)))
	out.append(Rect2(o.position, Vector2(t, arm + t)))
	# top-right
	out.append(Rect2(Vector2(o.end.x - arm - t, o.position.y), Vector2(arm + t, t)))
	out.append(Rect2(Vector2(o.end.x - t, o.position.y), Vector2(t, arm + t)))
	# bottom-left
	out.append(Rect2(Vector2(o.position.x, o.end.y - t), Vector2(arm + t, t)))
	out.append(Rect2(Vector2(o.position.x, o.end.y - arm - t), Vector2(t, arm + t)))
	# bottom-right
	out.append(Rect2(Vector2(o.end.x - arm - t, o.end.y - t), Vector2(arm + t, t)))
	out.append(Rect2(Vector2(o.end.x - t, o.end.y - arm - t), Vector2(t, arm + t)))
	return out

func _draw() -> void:
	if target < 1 or target > BattleHudLayout.OPPONENTS:
		return
	for r in corner_rects(layout.slots[target - 1]):
		draw_rect(r, COLOR)
