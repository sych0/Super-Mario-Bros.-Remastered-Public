class_name BattleTargetReticle
extends Control
## The red four-corner bracket of the real player's targeting (doc 47 B35-TARGET-002, B35-TARGET-003): thick L-shaped corners
## just outside a pane's edge, over the pane and under the attack layer. A view only: BattleScreen tells it which pane holds
## the persistent bracket (`set_target`, 1..34, or 0/-1 for none), which of the player's sends are in the air
## (`sync_flights`, from the attack presentation) and when to punch (`pulse`), and advances its clock (`advance`); it reads no
## session and owns no state about the match.
##
## THE SEND. When the real player's defeat sends an enemy, the reticle itself flies: the bracket leaves its pane, appears at the
## middle of the game window and flies to the authoritative recipient's pane in BattleAttackFlight.SEND_SECONDS (eased, a
## straight path, the pane's own size all the way), where it settles as the persistent bracket and punches. Nothing else is drawn
## for the send: no line, no enemy, no tint. While a send is in the air the persistent bracket is not shown (it is the one in
## the air); with two sends in the air both brackets fly and each lands on its own recipient. The recipient is the attack's
## (fixed when it was logged); changing the targeting mode in flight moves the persistent bracket, never a flight. A recipient
## that is eliminated in flight fades the bracket out where it is.
##
## Sizes are on the 480x270 canvas (4 device px per unit at 1080p): arms are a quarter of the pane's width, 0.75 units
## (3 device px) thick, and their inner edge sits 0.5 units (2 device px) outside the pane. That puts the whole bracket
## inside the 1.25-1.5 unit gap between panes, so it never covers a picture. A change of the persistent bracket's pane (a KO
## re-target, a mode change) is instant, as in the reference. The punch (the bracket starts a little wide and a soft halo fades,
## `pulse_amount`, 0.3 s) is the arrival emphasis of a send and the answer to choosing a mode; its length is not measured.

const COLOR := Color(1.0, 0.1, 0.1, 1.0) ## pure red: r > 225, g < 50, b < 70 in 8 bits (measured on the reference)
const HALO := Color(1.0, 0.2, 0.15, 1.0)
const THICKNESS := 0.75
const OUTSET := 0.5 ## from the pane's edge to the bracket's inner edge
const ARM_FRACTION := 0.25
const PULSE_SECONDS := BattleSendStyle.LANDING_PUNCH_SECONDS
const PULSE_SPREAD := 2.0 ## how far outward the bracket starts at the beginning of a punch

var layout := {}
var target := 0 ## the contestant id the persistent bracket is on, or 0 for none
var pulses := {} ## contestant id -> seconds since its pane was punched (a landing, a mode choice)
var flying: Array = [] ## the player's sends in the air at the last sync: {seq, target, progress, cut, fade}
var landed: Array[int] = [] ## ids of the panes a flight landed on at the last `sync_flights`

var _persistent_shown := false ## the persistent bracket is drawn (a target, and nothing of the player's is in the air)

func _init(layout_: Dictionary = {}) -> void:
	name = "TargetReticle"
	layout = layout_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = BattleHudLayout.CANVAS
	visible = false

## Puts the persistent bracket on opponent `id` (1..34); anything else hides it. Cheap to call every frame. Moving to another
## pane does not punch (a KO re-target is a plain move); `pulse` and a landing do.
func set_target(id: int) -> void:
	var next := id if id >= 1 and id <= BattleHudLayout.OPPONENTS else 0
	if next == target:
		return
	target = next
	_update_visible()
	queue_redraw()

## Tells the reticle which of the player's sends are in the air now (`BattleAttackPresentation.player_flights`). A flight that was
## in the air and is gone without having been cut has landed: its pane punches. Call every frame.
func sync_flights(now: Array) -> void:
	landed.clear()
	var still := {}
	for f in now:
		still[int(f.seq)] = true
	for f in flying:
		if not still.has(int(f.seq)) and not bool(f.cut):
			landed.append(int(f.target))
			pulse_at(int(f.target))
	flying = now
	_update_visible()
	if not flying.is_empty():
		queue_redraw()

## Nothing of the reticle is left: no bracket, no flight, no punch (a round ended or a new one began).
func clear() -> void:
	target = 0
	flying = []
	pulses.clear()
	landed.clear()
	_update_visible()
	queue_redraw()

## A punch on the persistent bracket's pane (a mode was picked).
func pulse() -> void:
	if target >= 1:
		pulse_at(target)

## A punch on opponent `id`'s pane.
func pulse_at(id: int) -> void:
	if id >= 1 and id <= BattleHudLayout.OPPONENTS:
		pulses[id] = 0.0
		_update_visible()
		queue_redraw()

func advance(delta: float) -> void:
	if delta <= 0.0 or pulses.is_empty():
		return
	for id in pulses.keys():
		pulses[id] = float(pulses[id]) + delta
		if float(pulses[id]) >= PULSE_SECONDS:
			pulses.erase(id)
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

## Whether the persistent bracket is drawn (a target, and none of the player's sends in the air).
func persistent_visible() -> bool:
	return _persistent_shown

## Whether anything of the reticle is on the canvas: the persistent bracket, a send in the air, or a punch fading.
func has_content() -> bool:
	return _persistent_shown or not flying.is_empty() or not pulses.is_empty()

func _update_visible() -> void:
	_persistent_shown = target >= 1 and flying.is_empty()
	visible = has_content()

func _draw() -> void:
	# a punch fading on a pane the persistent bracket is not on (a flight just landed there): the bracket's own fade
	for id in pulses:
		var pane: Rect2 = layout.slots[int(id) - 1]
		var p := pulse_amount(float(pulses[id]))
		var halo := HALO
		halo.a = 0.4 * p
		for r in corner_rects(pane, 1.0, THICKNESS * 3.0):
			draw_rect(r, halo)
		if not (_persistent_shown and int(id) == target):
			var c := COLOR
			c.a = p
			for r in corner_rects(pane, PULSE_SPREAD * p):
				draw_rect(r, c)
	if _persistent_shown:
		var pane: Rect2 = layout.slots[target - 1]
		var p := pulse_amount(float(pulses.get(target, PULSE_SECONDS)))
		for r in corner_rects(pane, PULSE_SPREAD * p):
			draw_rect(r, COLOR)
	for f in flying:
		var c := COLOR
		c.a = float(f.fade)
		for r in corner_rects(BattleAttackGeometry.send_rect(layout, int(f.target), float(f.progress))):
			draw_rect(r, c)
