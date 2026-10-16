class_name BattleEnemyIcon
extends RefCounted
## The small picture of a Battle enemy kind that the attack lines and the incoming strip carry. It
## uses the preview art (the game's own Goomba / Koopa sprites, so resource packs apply) when the
## previews have it, and flat shapes otherwise, so an attack is always readable.

const PREVIEW_KINDS := {
	BattleEnemyType.Kind.GOOMBA: "goomba",
	BattleEnemyType.Kind.KOOPA: "koopa_green",
}
const BODY := {
	BattleEnemyType.Kind.GOOMBA: Color(0.78, 0.36, 0.1, 1),
	BattleEnemyType.Kind.KOOPA: Color(0.1, 0.65, 0.15, 1),
}
const OUTLINE := Color(0.1, 0.04, 0.02, 1)

## The BattlePreviewAssets key of a Battle kind ("" if it has no art).
static func preview_kind(kind: int) -> String:
	return PREVIEW_KINDS.get(kind, "")

static func body_color(kind: int) -> Color:
	return BODY.get(kind, Color(0.8, 0.8, 0.8, 1))

## Draws `kind` standing with its feet at `feet`, `scale_` times the art's own size (but never taller than
## `max_height` px, if given: a Koopa is taller than a Goomba).
static func draw(canvas: CanvasItem, kind: int, feet: Vector2, scale_: float, assets: BattlePreviewAssets = null, t := 0.0, alpha := 1.0, max_height := 0.0) -> void:
	var spr: BattlePreviewSprite = null
	if assets != null:
		spr = assets.enemy_frame(preview_kind(kind), t)
	if spr != null:
		if max_height > 0.0:
			scale_ = minf(scale_, max_height / maxf(spr.size.y, 1.0))
		var r := Rect2(feet + spr.offset * scale_, spr.size * scale_)
		canvas.draw_texture_rect(spr.texture, r, false, Color(1, 1, 1, alpha))
		return
	var c := body_color(kind)
	c.a = alpha
	var w := 14.0 * scale_
	var h := 12.0 * scale_ if kind == BattleEnemyType.Kind.GOOMBA else 16.0 * scale_
	if max_height > 0.0 and h > max_height:
		w *= max_height / h
		h = max_height
	var body := Rect2(feet + Vector2(-w / 2.0, -h), Vector2(w, h))
	canvas.draw_rect(body.grow(1.0), Color(OUTLINE.r, OUTLINE.g, OUTLINE.b, alpha))
	canvas.draw_rect(body, c)
