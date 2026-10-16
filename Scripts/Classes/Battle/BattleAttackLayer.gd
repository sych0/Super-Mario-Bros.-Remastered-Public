class_name BattleAttackLayer
extends Control
## Draws the attack lines over the Battle canvas: every BattleAttackFlight of a
## BattleAttackPresentation as a line from where it left its sender to where it is now, with the
## attack's enemy riding its head, and a marking on whichever pane (or the game window) it is aimed at
## for as long as the line is there. A view only: it reads the presentation and the layout and owns no
## state of its own, so the same layer shows the real player's sends, the bots' sends and the attacks
## on the real player alike (a line to the player lands inside the game window and flashes its frame).
##
## It redraws only while something is in the air (and once more to clear the picture).

const TARGET_COLOR := Color(1.0, 0.95, 0.35, 1) ## a pane an attack is aimed at
const PLAYER_HIT_COLOR := Color(1.0, 0.18, 0.1, 1) ## the game window, when an attack is aimed at the real player
const FROM_PLAYER := Color(1.0, 0.93, 0.3, 1) ## the real player's sends: the loudest
const TO_PLAYER := Color(1.0, 0.25, 0.15, 1)
const BOT_TO_BOT := Color(1.0, 1.0, 1.0, 0.7) ## the bots' traffic: thin and quiet
const SHADOW := Color(0, 0, 0, 0.5)
const LINE_TAIL := 0.65 ## how strong a line is at its start, against 1 at its head

## Dev measurements: microseconds spent in _draw() and how many draws ran.
static var stat_draw_us := 0
static var stat_draws := 0

var view: BattleAttackPresentation = null
var layout := {}
var assets: BattlePreviewAssets = null ## the previews' art, if any (the head falls back to a flat shape without it)

var _was_drawing := false

func _init(layout_: Dictionary = {}) -> void:
	name = "AttackLayer"
	layout = layout_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = BattleHudLayout.CANVAS

func bind(view_: BattleAttackPresentation, assets_: BattlePreviewAssets) -> void:
	view = view_
	assets = assets_
	queue_redraw()

## Called every frame: redraws while a line is in the air, and once more when the last one is gone.
func sync() -> void:
	var drawing := view != null and not view.flights.is_empty()
	if drawing or _was_drawing:
		queue_redraw()
	_was_drawing = drawing

func _draw() -> void:
	if view == null:
		return
	var t0 := Time.get_ticks_usec()
	var clock := view.clock
	for id in view.marked_ids():
		_draw_target(id, view.target_strength(id), clock)
	for f in view.flights:
		_draw_flight(f, clock)
	stat_draw_us += Time.get_ticks_usec() - t0
	stat_draws += 1

## The mark on a target: the pane (or the game window's frame, in red, for the real player).
func _draw_target(id: int, strength: float, clock: float) -> void:
	var pulse := 0.65 + 0.35 * sin(clock * 26.0)
	var rect := BattleAttackGeometry.rect_of(layout, id)
	if id == BattleSession.PLAYER_ID:
		var c := PLAYER_HIT_COLOR
		c.a = strength * pulse
		draw_rect(rect.grow(2.0), c, false, 3.0)
		return
	var fill := TARGET_COLOR
	fill.a = 0.22 * strength
	draw_rect(rect, fill)
	var edge := TARGET_COLOR
	edge.a = strength * pulse
	draw_rect(rect.grow(1.0), edge, false, 2.0)

func _draw_flight(f: BattleAttackFlight, clock: float) -> void:
	var s := f.strength(clock)
	var a := BattleAttackGeometry.launch_point(layout, f.sender, f.target)
	var b := BattleAttackGeometry.landing_point(layout, f.sender, f.target)
	var e := f.eased(clock)
	var head := a.lerp(b, e)
	var color := BOT_TO_BOT
	var width := 1.0
	var icon := 0.5
	var through_window := false # the bots' traffic crosses the player's playfield only faintly
	if f.sender == BattleSession.PLAYER_ID:
		color = FROM_PLAYER
		width = 2.0
		icon = 0.95
	elif f.target == BattleSession.PLAYER_ID:
		color = TO_PLAYER
		width = 1.6
		icon = 0.8
	else:
		through_window = true
	# The line from the sender to the head, in up to three pieces: outside the game window at full
	# strength, inside it (bots' lines only) at a quarter.
	var span := Vector2(2.0, 2.0)
	if through_window:
		span = BattleAttackGeometry.inside_span(a, b, layout.game)
	var cuts := [0.0]
	if span.x <= span.y:
		cuts.append(span.x)
		cuts.append(span.y)
	cuts.append(e)
	cuts.sort()
	for i in cuts.size() - 1:
		var t0: float = clampf(cuts[i], 0.0, e)
		var t1: float = clampf(cuts[i + 1], 0.0, e)
		if t1 - t0 < 0.0001:
			continue
		var mid := (t0 + t1) * 0.5
		var inside := span.x <= mid and mid <= span.y
		_draw_piece(a.lerp(b, t0), a.lerp(b, t1), t0, t1, color, width, s * (0.25 if inside else 1.0))
	# the launch ring
	var age := f.age(clock)
	if age < 0.25 and age >= 0.0:
		var ring := color
		ring.a = (1.0 - age / 0.25) * s
		draw_arc(a, 3.0 + 9.0 * age / 0.25, 0.0, TAU, 16, ring, 1.5)
	# the enemy riding the head
	var head_alpha := s * (0.3 if through_window and span.x <= e and e <= span.y else 1.0)
	BattleEnemyIcon.draw(self, f.kind, head + Vector2(0, 7.0 * icon), icon, assets, clock * 6.0, head_alpha)

## One piece of a line, from `p0` (parameter `t0` of the whole line) to `p1` (`t1`): it grows from a
## faint tail to a bright head, so the direction reads at a glance.
func _draw_piece(p0: Vector2, p1: Vector2, t0: float, t1: float, color: Color, width: float, strength: float) -> void:
	var c0 := color
	var c1 := color
	c0.a = color.a * lerpf(LINE_TAIL, 1.0, t0) * strength
	c1.a = color.a * lerpf(LINE_TAIL, 1.0, t1) * strength
	var shadow := SHADOW
	shadow.a *= strength
	draw_line(p0, p1, shadow, width + 2.0)
	draw_polyline_colors(PackedVector2Array([p0, p1]), PackedColorArray([c0, c1]), width)
	if width >= 2.0: # the real player's own sends get a bright core
		draw_line(p0, p1, Color(1, 1, 1, 0.75 * strength), 1.0)
