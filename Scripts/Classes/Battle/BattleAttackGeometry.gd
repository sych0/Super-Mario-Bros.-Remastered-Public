class_name BattleAttackGeometry
extends RefCounted
## Pure geometry for the attack lines (no scene tree): where a flight leaves its sender and where it
## lands, on the 480x270 Battle canvas, from the layout BattleHudLayout.compute() describes. The
## contestants' ids are the only input; nothing here knows about the session or the line's timing.
##
## A bot's end of a line is the middle of its opponent pane. The real player's end of a line TO an
## opponent is the game window: it leaves from just inside the window's edge on that opponent's side,
## so the player's send visibly leaves the central window without covering the playfield (the
## reference's reticle flight, B35-TARGET-003, is milestone M-T2). A line FROM an opponent to the
## player is the reference's thin red attacker line (B35-INCOMING-004): it ends in the incoming bar
## under the window, at the bar's end on the sender's side, which is where the enemy it brings will
## queue up.

const WINDOW_INSET := 56.0 ## how far inside the game window's edge a line to / from the player starts or ends
const WINDOW_MARGIN_TOP := 30.0 ## kept off the window's top and bottom edges (HUD above, ground below)
const WINDOW_MARGIN_BOTTOM := 60.0
const BAR_INSET := 6.0 ## how far inside the incoming bar's end a red attacker line ends

## The rectangle `id` occupies on the canvas: the game window for the real player, its pane for a bot.
static func rect_of(layout: Dictionary, id: int) -> Rect2:
	if id == BattleSession.PLAYER_ID:
		return layout.game
	return layout.slots[id - 1]

static func center_of(layout: Dictionary, id: int) -> Vector2:
	return rect_of(layout, id).get_center()

## Where a line from `from_id` to `to_id` starts.
static func launch_point(layout: Dictionary, from_id: int, to_id: int) -> Vector2:
	if from_id == BattleSession.PLAYER_ID:
		return _window_point(layout, center_of(layout, to_id))
	return center_of(layout, from_id)

## Where a line from `from_id` to `to_id` ends.
static func landing_point(layout: Dictionary, from_id: int, to_id: int) -> Vector2:
	if to_id == BattleSession.PLAYER_ID:
		return bar_point(layout, center_of(layout, from_id))
	return center_of(layout, to_id)

## Where a line from the pane at `toward` ends in the incoming bar: just inside the bar's end on that side, at its middle.
static func bar_point(layout: Dictionary, toward: Vector2) -> Vector2:
	var bar: Rect2 = layout.strip_a
	var x := bar.position.x + BAR_INSET if toward.x < bar.get_center().x else bar.end.x - BAR_INSET
	return Vector2(x, bar.get_center().y)

## A point just inside the game window's edge on the side of `toward`, at about its height.
static func _window_point(layout: Dictionary, toward: Vector2) -> Vector2:
	var g: Rect2 = layout.game
	var x := g.position.x + WINDOW_INSET if toward.x < g.get_center().x else g.end.x - WINDOW_INSET
	var y := clampf(toward.y, g.position.y + WINDOW_MARGIN_TOP, g.end.y - WINDOW_MARGIN_BOTTOM)
	return Vector2(x, y)

## The part of the segment a -> b that lies inside `rect`, as the interval [x, y] of its parameter
## (0 at a, 1 at b), or an empty interval (x > y) if it never enters. Liang-Barsky clipping.
static func inside_span(a: Vector2, b: Vector2, rect: Rect2) -> Vector2:
	var t0 := 0.0
	var t1 := 1.0
	var d := b - a
	for k in 4:
		var p := 0.0
		var q := 0.0
		match k:
			0:
				p = -d.x
				q = a.x - rect.position.x
			1:
				p = d.x
				q = rect.end.x - a.x
			2:
				p = -d.y
				q = a.y - rect.position.y
			3:
				p = d.y
				q = rect.end.y - a.y
		if is_zero_approx(p):
			if q < 0.0:
				return Vector2(1.0, 0.0)
		else:
			var t := q / p
			if p < 0.0:
				t0 = maxf(t0, t)
			else:
				t1 = minf(t1, t)
	return Vector2(t0, t1)
