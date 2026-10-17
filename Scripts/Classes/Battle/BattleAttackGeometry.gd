class_name BattleAttackGeometry
extends RefCounted
## Pure geometry for the attack visuals (no scene tree): where they start and end on the 480x270 Battle canvas, from the
## layout BattleHudLayout.compute() describes. The contestants' ids are the only input; nothing here knows about the
## session or the timing. Every number is measured on the reference video at 60 fps (doc 54).
##
##   the real player's send (the reticle flight, doc 47 B35-TARGET-003)
##       starts at the middle of the game window (240.0, 120.0 in all 55 sends measured) and ends at the centre of the
##       recipient's pane (`send_start`, `send_rect`): the bracket, at the pane's own size, moves along a straight line at
##       constant speed.
##   a bot's send at the real player (the thin red line, B35-INCOMING-004)
##       starts at the middle of the sender's pane and ends on the WATCH OUT! pill's outer edge, on the sender's side of the
##       window: the pill's left edge for a sender in the left panel, its right edge for one in the right panel
##       (`launch_point`, `landing_point`, `pill_point`). The line's far end moves along it at constant speed: the line GROWS.
## A bot's send at another bot has no geometry: it is not drawn (B35-ATTACK-002).

## How far below the pill's top edge the lines end (measured: y = 253.75 on a pill that starts at 248.75).
const PILL_LINE_DROP := 5.0

## The rectangle `id` occupies on the canvas: the game window for the real player, its pane for a bot.
static func rect_of(layout: Dictionary, id: int) -> Rect2:
	if id == BattleSession.PLAYER_ID:
		return layout.game
	return layout.slots[id - 1]

static func center_of(layout: Dictionary, id: int) -> Vector2:
	return rect_of(layout, id).get_center()

## Where the reticle appears when the real player sends: the middle of the game window.
static func send_start(layout: Dictionary) -> Vector2:
	return (layout.game as Rect2).get_center()

## A bracket's outer box on `pane`: BattleSendStyle.REST_INSET inside the pane's own rectangle (30.5 x 39.0 for a pane of 32.75 x 41.5).
static func rest_box(pane: Rect2) -> Rect2:
	return pane.grow_individual(-BattleSendStyle.REST_INSET.x, -BattleSendStyle.REST_INSET.y, -BattleSendStyle.REST_INSET.x, -BattleSendStyle.REST_INSET.y)

## The same, swollen by the idle pulse: `amount` 0 is the rest box, 1 the peak box (31.75 x 41.0).
static func pulse_box(pane: Rect2, amount: float) -> Rect2:
	var inset := BattleSendStyle.REST_INSET.lerp(BattleSendStyle.PEAK_INSET, clampf(amount, 0.0, 1.0))
	return pane.grow_individual(-inset.x, -inset.y, -inset.x, -inset.y)

## The reticle's outer box `progress` (0..1) of the way from the window's middle to opponent `target`'s pane: a straight line at
## constant speed (the caller does not ease), the box going from the flight's first-frame size (32.0 x 41.0) to the rest size.
static func send_rect(layout: Dictionary, target: int, progress: float) -> Rect2:
	var pane: Rect2 = layout.slots[target - 1]
	var p := clampf(progress, 0.0, 1.0)
	var start_size := pane.size - BattleSendStyle.START_INSET * 2.0
	var size := start_size.lerp(rest_box(pane).size, p)
	var center := send_start(layout).lerp(pane.get_center(), p)
	return Rect2(center - size / 2.0, size)

## Where a red line from `from_id` to `to_id` starts: the middle of the sender's pane.
static func launch_point(layout: Dictionary, from_id: int, _to_id: int) -> Vector2:
	return center_of(layout, from_id)

## Where a red line from `from_id` to `to_id` ends: on the WATCH OUT! pill, when `to_id` is the real player.
static func landing_point(layout: Dictionary, from_id: int, to_id: int) -> Vector2:
	if to_id == BattleSession.PLAYER_ID:
		return pill_point(layout, center_of(layout, from_id))
	return center_of(layout, to_id)

## Where a line from the pane at `toward` ends on the pill: its left outer edge for a pane left of the window's middle, its right outer
## edge otherwise, a little below the pill's top (the reference's lines all meet the pill there).
static func pill_point(layout: Dictionary, toward: Vector2) -> Vector2:
	var pill: Rect2 = layout.pill
	var x := pill.position.x if toward.x < (layout.game as Rect2).get_center().x else pill.end.x
	return Vector2(x, pill.position.y + PILL_LINE_DROP)
