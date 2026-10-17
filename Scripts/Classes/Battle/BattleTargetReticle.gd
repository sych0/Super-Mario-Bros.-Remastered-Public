class_name BattleTargetReticle
extends Control
## The red four-corner bracket of the real player's targeting (doc 47 B35-TARGET-002, B35-TARGET-003): four thick rounded L-shaped
## corners on the opponent pane the real player is aiming at, over the pane and under the attack layer. A view only: BattleScreen
## tells it which pane holds the persistent bracket (`set_target`, 1..34, or 0/-1 for none) and which of the player's sends are in
## the air (`sync_flights`, from the attack presentation), and advances its clock (`advance`); it reads no session and owns no
## state about the match. Every dimension below was measured on the reference video at 60 fps (doc 54).
##
## THE BRACKET. Each corner is an L with arms ARM (11) units long and THICK (4.5) units thick, its outer corner rounded with the same
## radius, in a bright red (245, 0, 0). The outer box of the four corners is the pane's own rectangle inset by
## BattleSendStyle.REST_INSET (30.5 x 39.0 on a 32.75 x 41.5 pane): the bracket sits INSIDE the pane's edge and covers the corners
## of its picture. (Doc 47 / doc 50 had it as a 0.75-unit hairline outside the pane; the zoomed frames show the thick one.)
##
## IDLE PULSE. Once settled, the box swells from its rest size to a slightly larger one and back every 59 frames
## (BattleSendStyle.pulse), starting from the landing. Nothing else happens when it lands: no flash, no ring, no punch.
##
## THE SEND. When the real player's defeat sends an enemy, the reticle itself flies: the old bracket is gone, a bracket appears at
## the middle of the game window and moves along a straight line at constant speed to the centre of the authoritative recipient's pane
## in BattleSendStyle.SECONDS (15 frames), where it becomes the persistent bracket. While a send is in the air the persistent
## bracket is not shown (it is the one in the air). A newer send cancels an older one in the air: only the newest is drawn (the
## presentation enforces that; this class draws whatever it is given). The recipient is the attack's (fixed when it was logged);
## changing the targeting mode in flight moves the persistent bracket, never a flight. A recipient eliminated in flight fades the
## bracket out where it is.

const COLOR := Color8(245, 0, 0) ## measured: median (241, 0, 0), core (253, 0, 1); r > 225, g < 50, b < 70 in 8 bits
const ARM := 11.0 ## length of each arm, from the outer corner
const THICK := 4.5 ## thickness of each arm
const RADIUS := 4.5 ## the outer corner's rounding
const ARC_STEPS := 6

var layout := {}
var target := 0 ## the contestant id the persistent bracket is on, or 0 for none
var age := 0.0 ## seconds since the persistent bracket settled (the idle pulse's clock)
var flying: Array = [] ## the player's sends in the air at the last sync: {seq, target, progress, cut, fade}

var _persistent_shown := false ## the persistent bracket is drawn (a target, and nothing of the player's is in the air)

func _init(layout_: Dictionary = {}) -> void:
	name = "TargetReticle"
	layout = layout_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = BattleHudLayout.CANVAS
	visible = false

## Puts the persistent bracket on opponent `id` (1..34); anything else hides it. Cheap to call every frame. A bracket that moves to
## another pane starts its idle cycle again.
func set_target(id: int) -> void:
	var next := id if id >= 1 and id <= BattleHudLayout.OPPONENTS else 0
	if next == target:
		return
	target = next
	age = 0.0
	_update_visible()
	queue_redraw()

## Tells the reticle which of the player's sends are in the air now (`BattleAttackPresentation.player_flights`). Call every frame.
func sync_flights(now: Array) -> void:
	flying = now
	_update_visible()
	if not flying.is_empty():
		queue_redraw()

## Nothing of the reticle is left: no bracket, no flight (a round ended or a new one began).
func clear() -> void:
	target = 0
	flying = []
	age = 0.0
	_update_visible()
	queue_redraw()

func advance(delta: float) -> void:
	if delta <= 0.0 or not _persistent_shown:
		return
	age += delta
	queue_redraw() # the idle pulse moves every frame

## The four corners of a bracket whose outer box is `box`: [top-left, top-right, bottom-left, bottom-right] polygons, each an L whose
## outer corner is rounded. Pure, so tests can check the geometry.
static func corner_polygons(box: Rect2) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var corners := [[box.position, 1.0, 1.0], [Vector2(box.end.x, box.position.y), -1.0, 1.0],
		[Vector2(box.position.x, box.end.y), 1.0, -1.0], [box.end, -1.0, -1.0]]
	for c in corners:
		var o: Vector2 = c[0]
		var sx: float = c[1]
		var sy: float = c[2]
		var pts := PackedVector2Array()
		pts.append(o + Vector2(0.0, ARM) * Vector2(sx, sy))
		pts.append(o + Vector2(0.0, RADIUS) * Vector2(sx, sy))
		for i in range(1, ARC_STEPS):
			var a := PI + (PI * 0.5) * i / ARC_STEPS
			pts.append(o + Vector2(RADIUS + RADIUS * cos(a), RADIUS + RADIUS * sin(a)) * Vector2(sx, sy))
		pts.append(o + Vector2(RADIUS, 0.0) * Vector2(sx, sy))
		pts.append(o + Vector2(ARM, 0.0) * Vector2(sx, sy))
		pts.append(o + Vector2(ARM, THICK) * Vector2(sx, sy))
		pts.append(o + Vector2(THICK, THICK) * Vector2(sx, sy))
		pts.append(o + Vector2(THICK, ARM) * Vector2(sx, sy))
		out.append(pts)
	return out

## The middle of each of a bracket's eight arms (two per corner: along the top / bottom edge, then along the side), which are always
## inside the red. Tests sample them.
static func arm_centers(box: Rect2) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var corners := [[box.position, 1.0, 1.0], [Vector2(box.end.x, box.position.y), -1.0, 1.0],
		[Vector2(box.position.x, box.end.y), 1.0, -1.0], [box.end, -1.0, -1.0]]
	for c in corners:
		var o: Vector2 = c[0]
		var s := Vector2(c[1], c[2])
		out.append(o + Vector2(ARM * 0.75, THICK * 0.5) * s)
		out.append(o + Vector2(THICK * 0.5, ARM * 0.75) * s)
	return out

## The outer box of the persistent bracket on pane `id`, as drawn `age_` seconds after it settled.
func persistent_box(id: int, age_: float) -> Rect2:
	return BattleAttackGeometry.pulse_box(layout.slots[id - 1], BattleSendStyle.pulse(age_))

## Whether the persistent bracket is drawn (a target, and none of the player's sends in the air).
func persistent_visible() -> bool:
	return _persistent_shown

## Whether anything of the reticle is on the canvas: the persistent bracket or a send in the air.
func has_content() -> bool:
	return _persistent_shown or not flying.is_empty()

func _update_visible() -> void:
	var shown := target >= 1 and flying.is_empty()
	if shown and not _persistent_shown:
		age = 0.0 # it has just landed (or just appeared): the idle cycle starts here
	_persistent_shown = shown
	visible = has_content()

func _draw() -> void:
	if _persistent_shown:
		_draw_bracket(persistent_box(target, age), 1.0)
	for f in flying:
		_draw_bracket(BattleAttackGeometry.send_rect(layout, int(f.target), float(f.progress)), float(f.fade))

func _draw_bracket(box: Rect2, alpha: float) -> void:
	var c := COLOR
	c.a = alpha
	for poly in corner_polygons(box):
		draw_colored_polygon(poly, c)
