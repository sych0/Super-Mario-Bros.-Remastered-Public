class_name BattleAttackGeometry
extends RefCounted
## Pure geometry for the attack visuals (no scene tree): where they start and end on the 480x270 Battle canvas, from the
## layout BattleHudLayout.compute() describes. The contestants' ids are the only input; nothing here knows about the
## session or the timing.
##
##   the real player's send (the reticle flight, doc 47 B35-TARGET-003)
##       starts at the middle of the game window and ends on the recipient's pane (`send_start`, `send_rect`): the
##       reticle's bracket, at the pane's own size, slides between them.
##   a bot's send at the real player (the thin red line, B35-INCOMING-004)
##       starts at the middle of the sender's pane and ends inside the incoming bar, at the bar's end on the sender's
##       side (`launch_point`, `landing_point`, `bar_point`).
## A bot's send at another bot has no geometry: it is not drawn (B35-ATTACK-002).

const BAR_INSET := 6.0 ## how far inside the incoming bar's end a red attacker line ends

## The rectangle `id` occupies on the canvas: the game window for the real player, its pane for a bot.
static func rect_of(layout: Dictionary, id: int) -> Rect2:
	if id == BattleSession.PLAYER_ID:
		return layout.game
	return layout.slots[id - 1]

static func center_of(layout: Dictionary, id: int) -> Vector2:
	return rect_of(layout, id).get_center()

## Where the reticle appears when the real player sends: the middle of the game window (doc 47: 8 of the 10 sampled sends
## show it at the exact window centre; the other two are consistent with mid-flight positions, so no per-enemy origin is used).
static func send_start(layout: Dictionary) -> Vector2:
	return (layout.game as Rect2).get_center()

## The reticle's rectangle `progress` (0..1, already eased) of the way from the window's middle to opponent `target`'s pane. It
## has the pane's own size, or BattleSendStyle.START_SCALE times it at the start (not measured: 1).
static func send_rect(layout: Dictionary, target: int, progress: float) -> Rect2:
	var pane: Rect2 = layout.slots[target - 1]
	var p := clampf(progress, 0.0, 1.0)
	var start_size := pane.size * BattleSendStyle.START_SCALE
	var from := send_start(layout) - start_size / 2.0
	var size := start_size.lerp(pane.size, p)
	var to_center := pane.get_center()
	var center := (from + start_size / 2.0).lerp(to_center, p)
	return Rect2(center - size / 2.0, size)

## Where a red line from `from_id` to `to_id` (the real player) starts: the middle of the sender's pane.
static func launch_point(layout: Dictionary, from_id: int, _to_id: int) -> Vector2:
	return center_of(layout, from_id)

## Where a red line from `from_id` to `to_id` ends: in the incoming bar, when `to_id` is the real player.
static func landing_point(layout: Dictionary, from_id: int, to_id: int) -> Vector2:
	if to_id == BattleSession.PLAYER_ID:
		return bar_point(layout, center_of(layout, from_id))
	return center_of(layout, to_id)

## Where a line from the pane at `toward` ends in the incoming bar: just inside the bar's end on that side, at its middle.
static func bar_point(layout: Dictionary, toward: Vector2) -> Vector2:
	var bar: Rect2 = layout.strip_a
	var x := bar.position.x + BAR_INSET if toward.x < bar.get_center().x else bar.end.x - BAR_INSET
	return Vector2(x, bar.get_center().y)
