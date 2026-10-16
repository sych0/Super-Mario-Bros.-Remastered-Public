class_name BattleTargetReticle
extends Control
## The red four-corner bracket on the real player's current target pane (doc 47 B35-TARGET-002): thick L-shaped
## corners just outside the pane's edge, over the pane and under the attack layer. A view only: BattleScreen tells it
## which pane (`set_target`, 1..34, or 0/-1 for none) and when to punch (`pulse`), and advances its clock; it reads no
## session and owns no state about the match.
##
## Sizes are on the 480x270 canvas (4 device px per unit at 1080p): arms are a quarter of the pane's width, 0.75 units
## (3 device px) thick, and their inner edge sits 0.5 units (2 device px) outside the pane. That puts the whole bracket
## inside the 1.25-1.5 unit gap between panes, so it never covers a picture. It is drawn at the target the frame the
## target changes (the reference's reticle does not slide between panes); what answers a change is a punch: the bracket
## starts a little wide, snaps in and a soft red halo fades from it (`pulse_amount`, 0.3 s). The punch also plays when
## the player picks a targeting mode, so the selection is felt on the pane it lands on.
##
## The send animation of the reference (the reticle flying from the game window to the recipient, B35-TARGET-003) is
## not built here: it is milestone M-T2, and the gold send line stays until then.

const COLOR := Color(1.0, 0.1, 0.1, 1.0) ## pure red: r > 225, g < 50, b < 70 in 8 bits (measured on the reference)
const HALO := Color(1.0, 0.2, 0.15, 1.0)
const THICKNESS := 0.75
const OUTSET := 0.5 ## from the pane's edge to the bracket's inner edge
const ARM_FRACTION := 0.25
const PULSE_SECONDS := 0.3
const PULSE_SPREAD := 2.0 ## how far outward the bracket starts at the beginning of a punch

var layout := {}
var target := 0 ## the contestant id the bracket is on, or 0 for none
var pulse_age := 1.0e9 ## seconds since the last punch

func _init(layout_: Dictionary = {}) -> void:
	name = "TargetReticle"
	layout = layout_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = BattleHudLayout.CANVAS
	visible = false

## Puts the bracket on opponent `id` (1..34); anything else hides it. Cheap to call every frame. Moving to a new pane
## punches.
func set_target(id: int) -> void:
	var shown := id >= 1 and id <= BattleHudLayout.OPPONENTS
	var next := id if shown else 0
	if next == target and shown == visible:
		return
	if next != target and shown:
		pulse_age = 0.0
	target = next
	visible = shown
	queue_redraw()

## A punch on the current pane (a mode was picked).
func pulse() -> void:
	pulse_age = 0.0
	queue_redraw()

func advance(delta: float) -> void:
	if delta > 0.0 and pulse_age < PULSE_SECONDS:
		pulse_age += delta
		queue_redraw()

## 1 at the start of a punch down to 0 at PULSE_SECONDS (eased out).
static func pulse_amount(age_: float) -> float:
	if age_ < 0.0:
		return 1.0
	if age_ >= PULSE_SECONDS:
		return 0.0
	var t := age_ / PULSE_SECONDS
	return (1.0 - t) * (1.0 - t)

## The four brackets' corner rectangles for the pane `rect`: [top-left horizontal, top-left vertical, ...],
## eight rects, each just outside the pane edge (`spread` more units outward: the punch). Pure, so tests can check the
## geometry.
static func corner_rects(rect: Rect2, spread := 0.0, thickness := THICKNESS) -> Array[Rect2]:
	var arm := rect.size.x * ARM_FRACTION
	var t := thickness
	var out: Array[Rect2] = []
	var o := rect.grow(OUTSET + THICKNESS + spread) # the outer edge of the bracket
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
	var pane: Rect2 = layout.slots[target - 1]
	var p := pulse_amount(pulse_age)
	if p > 0.0:
		var halo := HALO
		halo.a = 0.4 * p
		for r in corner_rects(pane, 1.0, THICKNESS * 3.0):
			draw_rect(r, halo)
	for r in corner_rects(pane, PULSE_SPREAD * p):
		draw_rect(r, COLOR)
