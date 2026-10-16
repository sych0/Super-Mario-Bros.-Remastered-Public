class_name BattleHud
extends Control
## The Battle HUD inside the game window (doc 47 B35-LAYOUT-002), replacing the classic HUD row, which Battle hides
## (GameHUD): the coin counter and the item box top-left, the targeting selector top-middle, the clock and the
## large timer top-right. Positions come from BattleHudLayout; values from BattleScreen, which reads them from the
## session and the classic game and calls `set_values`. A view only: it owns no match state.
##
## What is real and what is a placeholder:
##   coin counter  the classic game's own count (`Global.coins`: Battle's coin economy is a later milestone, doc 47 Q4).
##   timer         the player's Battle clock (`BattleContestant.time_left`), whole seconds, no leading zeros.
##   item box      RESERVED: drawn dim and translucent, as the reference draws it with fewer than 20 coins (B35-COIN-002),
##                 with the roulette's fixed cost of 20. Nothing is selectable or spinning: the roulette is not built.
##   selector      BattleTargetSelector (a child).
## Text is the project's bitmap font only (BattleHudText).

const TEXT_WHITE := Color(1, 1, 1, 1)
const OUTLINE := Color(0.23, 0.2, 0.13, 1) ## the reference's dark outline (59,51,33)
const SILVER := Color(0.88, 0.9, 0.95, 1)
const SILVER_SHADE := Color(0.62, 0.66, 0.74, 1)
const COIN_GOLD := Color(1.0, 0.72, 0.1, 1)
const COIN_LIGHT := Color(1.0, 0.92, 0.5, 1)
const ITEM_DIM := 0.42 ## the whole item box, while it cannot be used
const COIN_SCALE := 1.0
const TIMER_SCALE := 2.0
const OUTLINE_PX := 0.5

var layout := {}
var font: Font = null
var selector: BattleTargetSelector = null
var coins := 0
var time_left := 0
var speed := 1 ## the dev sim-speed multiplier; shown beside the timer only when it is not 1

func _init(layout_: Dictionary = {}, font_: Font = null) -> void:
	name = "Hud"
	layout = layout_
	font = font_
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	position = Vector2.ZERO
	size = BattleHudLayout.CANVAS
	selector = BattleTargetSelector.new(layout.hud.selector, font)
	add_child(selector)

## Sets what the HUD shows; redraws only when something changed.
func set_values(coins_: int, time_left_: int, speed_: int) -> void:
	if coins_ == coins and time_left_ == time_left and speed_ == speed:
		return
	coins = coins_
	time_left = time_left_
	speed = speed_
	queue_redraw()

## The timer's text: whole seconds, never negative, no leading zeros.
static func timer_text(seconds: int) -> String:
	return str(maxi(seconds, 0))

func _draw() -> void:
	if layout.is_empty():
		return
	_draw_item_box(layout.hud.item_box)
	_draw_coins(layout.hud.coins)
	_draw_timer(layout.hud.timer)

# ---- coin counter --------------------------------------------------------------------------------------------

func _draw_coins(r: Rect2) -> void:
	var c := Vector2(r.position.x + 2.5, r.position.y + r.size.y / 2.0)
	_coin(c, 3.6)
	BattleHudText.draw(self, font, str(coins), Vector2(r.position.x + 8.0, c.y - BattleHudText.ink_height(COIN_SCALE) / 2.0),
		COIN_SCALE, TEXT_WHITE, OUTLINE, OUTLINE_PX)

## A coin: a tall gold ellipse with a dark rim and a pale slot.
func _coin(c: Vector2, h: float, alpha := 1.0) -> void:
	var pts := PackedVector2Array()
	for i in 20:
		var a := TAU * i / 20.0
		pts.append(c + Vector2(cos(a) * h * 0.62, sin(a) * h))
	draw_colored_polygon(_grown(pts, c, 0.55), Color(OUTLINE.r, OUTLINE.g, OUTLINE.b, alpha))
	draw_colored_polygon(pts, Color(COIN_GOLD.r, COIN_GOLD.g, COIN_GOLD.b, alpha))
	draw_rect(Rect2(c + Vector2(-0.45, -h * 0.55), Vector2(0.9, h * 1.1)), Color(COIN_LIGHT.r, COIN_LIGHT.g, COIN_LIGHT.b, alpha))

static func _grown(pts: PackedVector2Array, c: Vector2, by: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		out.append(p + (p - c).normalized() * by)
	return out

# ---- timer ---------------------------------------------------------------------------------------------------

func _draw_timer(r: Rect2) -> void:
	var clock_c := Vector2(r.position.x + 7.0, r.position.y + r.size.y / 2.0)
	_clock(clock_c, 6.4)
	var text := timer_text(time_left)
	var w := BattleHudText.ink_width(text, TIMER_SCALE)
	var top_left := Vector2(r.end.x - w, clock_c.y - BattleHudText.ink_height(TIMER_SCALE) / 2.0)
	# silver numerals with a dark outline; a darker copy one pixel below gives them their chrome edge
	BattleHudText.draw(self, font, text, top_left + Vector2(0, 0.5), TIMER_SCALE, SILVER_SHADE, OUTLINE, 0.75)
	BattleHudText.draw(self, font, text, top_left, TIMER_SCALE, SILVER)
	if speed != 1:
		BattleHudText.draw(self, font, "X%d" % speed, Vector2(r.end.x - 15.0, r.end.y + 1.0), 0.75, Color(1.0, 0.9, 0.3), OUTLINE, OUTLINE_PX)

## A round grey clock with a dark outline and two hands.
func _clock(c: Vector2, radius: float) -> void:
	draw_circle(c, radius + 0.6, OUTLINE)
	draw_circle(c, radius, SILVER_SHADE)
	draw_circle(c, radius - 1.2, Color(0.93, 0.94, 0.97, 1))
	draw_line(c, c + Vector2(0, -radius * 0.62), OUTLINE, 0.9)
	draw_line(c, c + Vector2(radius * 0.45, radius * 0.18), OUTLINE, 0.9)

# ---- item box (reserved) -------------------------------------------------------------------------------------

func _draw_item_box(r: Rect2) -> void:
	var a := ITEM_DIM
	BattleHudShapes.box(self, r, Color(0.1, 0.08, 0.06, 0.8 * a), Color(1, 1, 1, 0.6 * a), 5.0)
	# the "?" block
	var block := Rect2(r.position + Vector2(8, 6), Vector2(r.size.x - 16, r.size.x - 16))
	draw_rect(block, Color(COIN_GOLD.r, COIN_GOLD.g, COIN_GOLD.b, a))
	draw_rect(block, Color(OUTLINE.r, OUTLINE.g, OUTLINE.b, a), false, 0.75)
	BattleHudText.draw_in(self, font, "?", block, 2.0, Color(OUTLINE.r, OUTLINE.g, OUTLINE.b, a))
	# the cost pill: the roulette's fixed price
	var pill := Rect2(r.position + Vector2(5, r.size.y - 12), Vector2(r.size.x - 10, 8))
	draw_rect(pill, Color(0, 0, 0, 0.55 * a))
	_coin(pill.position + Vector2(4.5, pill.size.y / 2.0), 2.8, a)
	BattleHudText.draw(self, font, "20", pill.position + Vector2(10.0, (pill.size.y - BattleHudText.ink_height(0.75)) / 2.0),
		0.75, Color(1, 1, 1, a))
