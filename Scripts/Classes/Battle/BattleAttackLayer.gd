class_name BattleAttackLayer
extends Control
## Draws the one attack visual that is a line: the thin red line of each opponent that is AIMING at the real player, from the middle
## of its pane to the WATCH OUT! pill's near edge (doc 47 B35-INCOMING-004, measured on the reference at 60 fps in doc 54). The line
## GROWS: its head moves from the pane towards the pill in 15 frames at constant speed, and the line then stays until the opponent stops
## aiming at the player (a re-target) or is knocked out, which removes it that frame. A view only: it reads the presentation and the
## layout and owns no state of its own.
##
## Everything the screen used to draw here before the reference was measured against it is gone (doc 51): the gold line of
## the player's own send (the reticle flies instead: BattleTargetReticle), the lines between two bots (SMB35 draws none), the
## yellow tint and outline on a target pane, the red flash of the game window's frame, the enemy riding the head of a line and
## the launch ring, and the line that every bot send used to make: a line is an opponent that AIMS at the player. It is plain: solid, red, thin.

const LINE_COLOR := Color(1.0, 0.07, 0.07, 1.0) ## the reference's reds are r > 225, g < 50 (8 bits)
const LINE_WIDTH := 0.65 ## canvas units: 2.5 device px at 1080p (measured: 2.4-2.7)

## Dev measurements: microseconds spent in _draw() and how many draws ran.
static var stat_draw_us := 0
static var stat_draws := 0

var view: BattleAttackPresentation = null
var layout := {}

var _signature := -1

func _init(layout_: Dictionary = {}) -> void:
	name = "AttackLayer"
	layout = layout_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = BattleHudLayout.CANVAS

func bind(view_: BattleAttackPresentation, _assets: BattlePreviewAssets = null) -> void:
	view = view_
	_signature = -2
	queue_redraw()

## The lines of `view` this layer draws: one per opponent aiming at the real player. (Pure: tests read what is drawn.)
static func drawn_lines(view_: BattleAttackPresentation) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if view_ == null:
		return out
	return view_.lines()

## Where the head of a line from `sender` is, `progress` of the way to the pill. Pure.
static func head_of(layout_: Dictionary, sender: int, progress: float) -> Vector2:
	var a := BattleAttackGeometry.launch_point(layout_, sender, BattleSession.PLAYER_ID)
	var b := BattleAttackGeometry.landing_point(layout_, sender, BattleSession.PLAYER_ID)
	return a.lerp(b, clampf(progress, 0.0, 1.0))

## Called every frame: redraws while a line is growing, and when the set of lines changes (one more, one fewer, none left).
func sync() -> void:
	var sig := 0
	var growing := false
	for l in drawn_lines(view):
		sig = sig * 131 + int(l.sender) + 1
		growing = growing or float(l.progress) < 1.0
	if growing:
		sig = -3 - Engine.get_process_frames()
	if sig != _signature:
		_signature = sig
		queue_redraw()

func _draw() -> void:
	if view == null:
		return
	var t0 := Time.get_ticks_usec()
	for l in drawn_lines(view):
		var a := BattleAttackGeometry.launch_point(layout, int(l.sender), BattleSession.PLAYER_ID)
		draw_line(a, head_of(layout, int(l.sender), float(l.progress)), LINE_COLOR, LINE_WIDTH)
	stat_draw_us += Time.get_ticks_usec() - t0
	stat_draws += 1
