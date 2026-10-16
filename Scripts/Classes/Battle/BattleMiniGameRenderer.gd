class_name BattleMiniGameRenderer
extends BattlePreviewRenderer
## Draws a BattlePreviewFrame: sky, parallax hills, a window onto the baked level strip, the
## flag, enemies and Mario, then the level-end fade. Everything is a handful of textured
## quads (the strip is one region draw), so 34 of these stay cheap.
##
## It draws at the classic camera's own scale (1:1 texels, 240 px tall, anchored on the ground)
## into a BattlePreviewAtlas cell, so Mario, enemies and terrain are normal gameplay-size art.
## The shrinking into a small pane is done afterwards by the pane, not here.

const ZOOM := 1.0
const ACTOR_SCALE := 1.0
const VIEW_BOTTOM := 32.0 ## world y of the bottom edge of the view (ground top is y = 0)
const HILL_PARALLAX := 0.5
const HILL_REPEAT := 512.0
const INVADER_SCALE := 1.7 ## incoming enemies are drawn larger than the level's own (they must read at pane size)
const INVADER_HALO := Color(1.0, 0.1, 0.05, 0.4)
const INVADER_MARKER := Color(1.0, 0.15, 0.1, 1.0)

## World width shown across a logical width (the track needs it to place its camera).
static func world_width(logical_w: float) -> float:
	return logical_w / ZOOM

func draw(canvas: CanvasItem, _contestant: BattleContestant, size: Vector2, f: BattlePreviewFrame = null) -> void:
	if f == null or not f.valid or f.assets == null:
		return
	var a := f.assets
	var z := ZOOM
	var vw := size.x / z
	var cam := roundf(clampf(f.camera_x - (vw - f.view_w) * BattlePreviewTrack.CAMERA_FOCUS, f.cam_min, maxf(f.cam_min, f.cam_max - vw))) # whole texels, like the classic camera
	canvas.draw_rect(Rect2(Vector2.ZERO, size), a.sky_color)
	# hills
	if a.hills != null:
		var hh := float(a.hills.get_height())
		var hy := (a.hills_y - VIEW_BOTTOM) * z + size.y
		var k := floori(cam * HILL_PARALLAX / HILL_REPEAT)
		while true:
			var sx := (k * HILL_REPEAT - cam * HILL_PARALLAX) * z
			if sx >= size.x:
				break
			canvas.draw_texture_rect(a.hills, Rect2(sx, hy, HILL_REPEAT * z, hh * z), false)
			k += 1
	# level strip: terrain, pipes, blocks, deco, pole, castle
	var view_top := VIEW_BOTTOM - size.y / z
	var src_y := maxf(view_top - a.strip_origin.y, 0.0)
	var src_end := minf(VIEW_BOTTOM - a.strip_origin.y, a.strip_size.y)
	var src_x := clampf(cam - a.strip_origin.x, 0.0, maxf(a.strip_size.x - vw, 0.0))
	canvas.draw_texture_rect_region(a.strip,
		Rect2(0.0, (a.strip_origin.y + src_y - VIEW_BOTTOM) * z + size.y, vw * z, (src_end - src_y) * z),
		Rect2(src_x, src_y, vw, src_end - src_y))
	# flag cloth sliding down the pole
	if f.flag_visible and a.flag_cloth != null and f.sketch != null:
		_sprite(canvas, a.flag_cloth, f.sketch.goal_x - 7.0, f.flag_y, false, cam, size, z)
	for actor in f.actors:
		_sprite(canvas, actor[0], actor[1], actor[2], actor[3], cam, size, z * ACTOR_SCALE)
	if f.mario_visible and f.mario_sprite != null:
		_sprite(canvas, f.mario_sprite, f.mario_x, f.mario_y, false, cam, size, z * ACTOR_SCALE)
	for inv in f.invaders:
		_invader(canvas, inv, cam, size, z)
	if f.fade > 0.0:
		canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, f.fade))

## An enemy sent by an attack: its own art, larger than a level's enemies so it still reads when the
## picture is shrunk into a pane, on a red halo with a marker above it. It blinks out when its attack
## resolves. (Cosmetic only: see BattlePreviewTrack.)
func _invader(canvas: CanvasItem, inv: Dictionary, cam: float, size: Vector2, z: float) -> void:
	var vanish: float = inv.vanish
	if vanish > 0.0 and int(vanish * 24.0) % 2 == 1:
		return # the blink
	var spr: BattlePreviewSprite = inv.sprite
	var s := z * INVADER_SCALE
	var feet := Vector2((inv.x - cam) * ZOOM, (inv.y - VIEW_BOTTOM) * ZOOM + size.y).round()
	var body := Rect2(feet + spr.offset * s, spr.size * s)
	var c := body.get_center()
	canvas.draw_circle(c, maxf(body.size.x, body.size.y) * 0.75, INVADER_HALO)
	canvas.draw_texture_rect(spr.texture, body, false)
	var tip := Vector2(c.x, body.position.y - 3.0)
	canvas.draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-7.0, -10.0), tip + Vector2(7.0, -10.0)]), INVADER_MARKER)

func _sprite(canvas: CanvasItem, spr: BattlePreviewSprite, wx: float, wy: float, flip: bool, cam: float, size: Vector2, scale_: float) -> void:
	var feet := Vector2((wx - cam) * ZOOM, (wy - VIEW_BOTTOM) * ZOOM + size.y).round()
	var r := Rect2(feet + spr.offset * scale_, spr.size * scale_)
	if flip:
		r = Rect2(r.position.x + r.size.x, r.position.y, -r.size.x, r.size.y)
	canvas.draw_texture_rect(spr.texture, r, false)
