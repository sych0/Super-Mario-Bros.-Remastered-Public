class_name BattleBadge
extends Control
## One of the two cards that hang from the top edge into the inner-top slot of each side panel (doc 47
## B35-LAYOUT-005): COURSE on the left (a small "COURSE" caption over a large "W-L") and ALIVE on the right (a small
## Mario over "N/T": opponents and player still in, over the number of contestants). A white rounded card with a dark
## brown border. A view only; BattleScreen sets `value` from the session every frame.
##
## The Mario is the preview art's own small Mario (the loaded resource pack's) when the previews have it, and a
## small drawn stand-in otherwise, so the badge never depends on the previews being live.

enum Kind {COURSE, ALIVE}

const CARD := Color(0.99, 0.98, 0.94, 1)
const BORDER := Color(0.35, 0.2, 0.1, 1)
const TEXT := Color(0.25, 0.14, 0.06, 1)
const CAPTION := Color(0.55, 0.42, 0.3, 1)
const CAPTION_TEXT := "COURSE"
const CAPTION_SCALE := 0.55
const VALUE_SCALE := 1.0
const ALIVE_SCALE := 0.75
const SMALL := 0 ## BattlePreviewAssets power index of small Mario

var kind: int = Kind.COURSE
var font: Font = null
var value := ""
var assets: BattlePreviewAssets = null

func _init(kind_ := Kind.COURSE, font_: Font = null) -> void:
	kind = kind_
	font = font_
	name = "BadgeCourse" if kind == Kind.COURSE else "BadgeAlive"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func set_value(text: String) -> void:
	if text != value:
		value = text
		queue_redraw()

func set_assets(assets_: BattlePreviewAssets) -> void:
	if assets_ != assets:
		assets = assets_
		queue_redraw()

func _draw() -> void:
	var card := Rect2(Vector2.ZERO, size)
	BattleHudShapes.box(self, card, CARD, BORDER, 3.0, 0.75)
	if kind == Kind.COURSE:
		var inner := card.grow(-2.0)
		var s := BattleHudText.fit_scale(CAPTION_TEXT, inner.size.x, CAPTION_SCALE)
		BattleHudText.draw_in(self, font, CAPTION_TEXT, Rect2(inner.position + Vector2(0, 2.5), Vector2(inner.size.x, 5.0)), s, CAPTION, Vector2(0.5, 0.0))
		var v := BattleHudText.fit_scale(value, inner.size.x, VALUE_SCALE)
		BattleHudText.draw_in(self, font, value, Rect2(inner.position + Vector2(0, 11.0), Vector2(inner.size.x, 12.0)), v, TEXT)
		return
	_mario(Vector2(size.x / 2.0, 22.0))
	var inner_w := size.x - 4.0
	var v2 := BattleHudText.fit_scale(value, inner_w, ALIVE_SCALE)
	BattleHudText.draw_in(self, font, value, Rect2(Vector2(2.0, 28.0), Vector2(inner_w, 12.0)), v2, TEXT)

## Small Mario standing with his feet at `feet`.
func _mario(feet: Vector2) -> void:
	var spr: BattlePreviewSprite = assets.mario_frame_at(SMALL, "Idle", 0) if assets != null else null
	if spr != null:
		draw_texture_rect(spr.texture, Rect2(feet + spr.offset, spr.size), false)
		return
	# a drawn stand-in: cap, face, overalls
	draw_rect(Rect2(feet + Vector2(-5, -15), Vector2(10, 3)), Color(0.85, 0.15, 0.1))
	draw_rect(Rect2(feet + Vector2(-4, -12), Vector2(8, 4)), Color(0.98, 0.76, 0.52))
	draw_rect(Rect2(feet + Vector2(-5, -8), Vector2(10, 5)), Color(0.85, 0.15, 0.1))
	draw_rect(Rect2(feet + Vector2(-4, -4), Vector2(8, 4)), Color(0.2, 0.3, 0.85))
