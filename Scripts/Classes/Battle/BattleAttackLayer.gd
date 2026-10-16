class_name BattleAttackLayer
extends Control
## Draws the one attack visual that is a line: the thin red line of a bot's send at the real player, from the sender's pane
## into the incoming bar (doc 47 B35-INCOMING-004). A view only: it reads the presentation and the layout and owns no state of
## its own. It redraws only while something is in the air (and once more to clear the picture).
##
## Everything the screen used to draw here before the reference was measured against it is gone (doc 51): the gold line of
## the player's own send (the reticle flies instead: BattleTargetReticle), the lines between two bots (SMB35 draws none), the
## yellow tint and outline on a target pane, the red flash of the game window's frame, the enemy riding the head of a line and
## the launch ring. The line is plain: solid, red, thin.

const LINE_COLOR := Color(1.0, 0.1, 0.1, 1.0) ## the reference's reds are r>225, g<50, b<70 (8 bits)
const LINE_WIDTH := 0.5 ## canvas units: 2 device px at 1080p (doc 47: the reference's attacker lines are 1-2 device px)

## Dev measurements: microseconds spent in _draw() and how many draws ran.
static var stat_draw_us := 0
static var stat_draws := 0

var view: BattleAttackPresentation = null
var layout := {}

var _was_drawing := false

func _init(layout_: Dictionary = {}) -> void:
	name = "AttackLayer"
	layout = layout_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = BattleHudLayout.CANVAS

func bind(view_: BattleAttackPresentation, _assets: BattlePreviewAssets = null) -> void:
	view = view_
	queue_redraw()

## The flights of `view` that this layer draws: only a bot's send at the real player. (Pure: tests read what is drawn.)
static func drawn_flights(view_: BattleAttackPresentation) -> Array[BattleAttackFlight]:
	var out: Array[BattleAttackFlight] = []
	if view_ == null:
		return out
	for f in view_.flights:
		if f.target == BattleSession.PLAYER_ID and f.sender != BattleSession.PLAYER_ID:
			out.append(f)
	return out

## Called every frame: redraws while a line is in the air, and once more when the last one is gone.
func sync() -> void:
	var drawing := not drawn_flights(view).is_empty()
	if drawing or _was_drawing:
		queue_redraw()
	_was_drawing = drawing

func _draw() -> void:
	if view == null:
		return
	var t0 := Time.get_ticks_usec()
	for f in drawn_flights(view):
		_draw_line(f, view.clock)
	stat_draw_us += Time.get_ticks_usec() - t0
	stat_draws += 1

## The line from the sender's pane to where its head is now (it leaves fast and settles on the bar), fading once it has landed.
func _draw_line(f: BattleAttackFlight, clock: float) -> void:
	var a := BattleAttackGeometry.launch_point(layout, f.sender, f.target)
	var b := BattleAttackGeometry.landing_point(layout, f.sender, f.target)
	var head := a.lerp(b, f.eased(clock))
	var c := LINE_COLOR
	c.a = f.strength(clock)
	draw_line(a, head, c, LINE_WIDTH)
