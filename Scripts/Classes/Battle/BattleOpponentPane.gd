class_name BattleOpponentPane
extends Control
## One opponent window on the Battle canvas (display resolution). It shows its own region of the
## shared BattlePreviewAtlas, scaled down through the 4-tap footprint shader, and draws everything
## that must stay sharp on top of it: the hairline outline, the KO card and the incoming markers. A view only: it
## reads the contestant and its BattlePreviewCell and owns no match state.
##
## The live pane carries no text and no marker (doc 47 B35-PREVIEW-001: no id, no course; B35-ATTACK-002: no incoming pips): the
## contestant number, the "W-L" course text and the queued/active pips are debug labels, shown only when `show_labels` is on
## (SMB1R_BATTLE_LABELS=1, `--battle-labels`, or F3 on the Battle screen).
##
## The KO card (B35-KO-001/002), measured on the reference at 60 fps (doc 54; t=526.333 and t=518.367): when the preview shows the
## contestant's KO (`marked`) the pane plays a pane-local animation of KO_SECONDS, then rests as the card. A white rounded square
## appears at the pane's middle, grows and throws a ring of eight yellow stars, and on the third frame the whole blue card is there
## under a white burst; stars fly outward and leave the pane while cream smoke puffs build up over the card, thicken, and turn into
## rings that fade; a second white rounded square grows at the middle (0.22 s), the card clears and a third white square flashes
## over its plate (0.76 s); a pale rim fades round the plate and the card is at rest (0.95 s). The card is a bright blue ring,
## a dark slate field and a light-blue plate holding "KO" and, in a black-edged teal block with rivets, the contestant's final placement.
## The pane never moves or changes size (no reordering) and the whole animation is drawn at display resolution here: it costs the
## atlas nothing. Time is the screen's: `advance` is not called while the game is paused. The orange card for an opponent the player
## KO'd (B35-KO-003) is not built: it needs the KO credit rules of the timer milestone. (The reference also flies a coin and a grey enemy
## icon across the card from 0.55 s to 0.75 s; they are not drawn.)

const OUTLINE := Color(0.23, 0.2, 0.13, 1) ## the reference's dark line (59,51,33)
const OUTLINE_WIDTH := 0.5
const TEXT_COLOR := Color(1, 1, 1, 1)
const SHADER_PATH := "res://Scenes/Parts/BattlePreviewDownsample.gdshader"
const PIP_ACTIVE := Color(1.0, 0.15, 0.08, 1)
const PIP_QUEUED := Color(1.0, 0.85, 0.3, 1)
const PIP_EDGE := Color(0, 0, 0, 0.8)
const MAX_PIPS := 6

# The card's colours, measured on the settled card (t=527.4).
const CARD_RING := Color8(3, 102, 193)
const CARD_FIELD := Color8(32, 78, 147)
const CARD_PLATE := Color8(22, 137, 211)
const BLOCK_TEAL := Color8(0, 120, 152)
const BLOCK_TEAL_DARK := Color8(0, 86, 108)
const BLOCK_EDGE := Color8(0, 0, 0)
const RIVET := Color(0.78, 0.96, 0.94, 1)
const FLASH := Color(1, 1, 1, 1)
const STAR := Color8(255, 226, 40)
const PUFF := Color(1.0, 0.98, 0.94, 1)
const DESIGN := Vector2(32.75, 41.5) ## the pane size every unit below is measured on
# The card's rectangles in design units: ring, dark field, light plate, and the teal block with its black edge.
const RING_RECT := Rect2(0.5, 0.5, 31.75, 40.5)
const FIELD_RECT := Rect2(3.5, 3.5, 25.75, 35.0)
const PLATE_RECT := Rect2(6.5, 6.5, 19.75, 29.0)
const BLOCK_EDGE_RECT := Rect2(8.75, 17.5, 15.5, 16.0)
const BLOCK_RECT := Rect2(9.75, 18.5, 13.5, 14.0)

# The KO animation timeline, in seconds from the pane's first frame (frame n of the reference's 60 fps is n / 60).
const KO_SECONDS := 0.95
const SQUARE_1 := 1.0 / 60.0 ## the white square alone, then with the stars
const SQUARE_2 := 2.0 / 60.0 ## the card is there from this frame, under the white burst
const BURST_END := 6.0 / 60.0
const STARS_END := 0.35
const PUFFS_START := 4.0 / 60.0
const PUFFS_RINGS := 0.47 ## the smoke thins into rings
const PUFFS_END := 0.58
const FLASH_2_START := 0.217
const FLASH_2_PEAK := 0.283
const FLASH_2_END := 0.35
const FLASH_3_START := 0.764
const FLASH_3_PEAK := 0.83
const FLASH_3_END := 0.85
const GLOW_START := 0.85
const STAR_COUNT := 8
const PUFF_COUNT := 9

static var _shader: Shader = null
## Debug labels (the contestant number and the course text over the picture). Off in play.
static var show_labels := false

var contestant_id := 0
var ko := false
var marked := false ## the KO card is showing (or animating in)
var placement := 0 ## the contestant's final placement, once it has one
var ko_age := 1.0e9 ## seconds since the KO animation began; >= KO_SECONDS when it has settled
var incoming := Vector2i.ZERO ## enemies sent at this opponent: x queued, y active (a view of the session's queue, see BattleAttackPresentation)
var cell: BattlePreviewCell = null
var region_px := Rect2i() ## this pane's cell in the atlas, in texels
var picture := TextureRect.new() ## the downsampled atlas region
var overlay := Control.new() ## outline, card, labels and markers at display resolution
var font: Font = null

var _signature := -1
var _primed := false ## the first refresh has happened (a pane that is already marked then is settled, not animating)

func _init(id := 0, font_: Font = null) -> void:
	contestant_id = id
	font = font_
	name = "Pane%02d" % id
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	picture.name = "Picture"
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_SCALE
	picture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR # the shader's taps are bilinear
	picture.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(picture)
	overlay.name = "Overlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)

## Points the pane at `cell_px` of `atlas_texture` (a region of the one shared atlas, never a copy).
func bind(atlas_texture: Texture2D, cell_px: Rect2i, cell_: BattlePreviewCell) -> void:
	cell = cell_
	region_px = cell_px
	var tex := AtlasTexture.new()
	tex.atlas = atlas_texture
	tex.region = Rect2(cell_px)
	picture.texture = tex
	if _shader == null:
		_shader = load(SHADER_PATH)
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("region", uv_region(cell_px, atlas_texture.get_size()))
	picture.material = mat

## The cell's UV rect in the atlas, inset by half a texel so a tap can never read the padding.
static func uv_region(cell_px: Rect2i, atlas_size: Vector2) -> Vector4:
	var half := Vector2(0.5, 0.5) / atlas_size
	var pos := Vector2(cell_px.position) / atlas_size + half
	var sz := Vector2(cell_px.size) / atlas_size - half * 2.0
	return Vector4(pos.x, pos.y, sz.x, sz.y)

func world_level_text() -> String:
	return cell.world_level_text() if cell != null else BattleCourse.text(0)

## Follows the session at once; the KO marking itself follows the picture (see BattlePreviewCell.marked).
func refresh(c: BattleContestant) -> void:
	ko = not c.alive
	var was_marked := marked
	marked = cell.marked() if cell != null else ko
	placement = c.placement
	if marked and not was_marked:
		ko_age = KO_SECONDS if not _primed else 0.0 # already marked when first seen: settled; a KO happening now: animate
	elif not marked:
		ko_age = 1.0e9
	_primed = true
	var sig := int(ko) | (int(marked) << 1) | ((cell.course_index() if cell != null else 0) << 2) | (int(show_labels) << 10) | (placement << 11)
	if sig != _signature:
		_signature = sig
		overlay.queue_redraw()

## Whether the queued/active pips are drawn: SMB35 shows no incoming marker on a pane (doc 47 B35-ATTACK-002, B35-UI-002), so only
## the debug labels mode shows them, and never on a KO card.
func draws_pips() -> bool:
	return show_labels and not marked

## Whether the KO animation is still playing.
func is_animating() -> bool:
	return marked and ko_age < KO_SECONDS

## Ends a KO animation that is still playing: the card is at rest (the round is over, the field is held).
func settle() -> void:
	if is_animating():
		ko_age = KO_SECONDS
		overlay.queue_redraw()

## The contestant is out in the session but its picture has not shown the KO yet, and the round is over so it never will (the previews
## run behind the session and the field is held): the pane shows its card at rest, without the animation. In the reference every other
## pane is a settled card by the time the player's win appears (t=1070, 2 s before the white flash of the results).
func settle_as_card(c: BattleContestant) -> void:
	if marked:
		settle()
		return
	ko = true
	marked = true
	placement = c.placement
	ko_age = KO_SECONDS
	overlay.queue_redraw()

## Advances the KO animation (the screen's clock; not called while the game is paused).
func advance(delta: float) -> void:
	if delta > 0.0 and is_animating():
		ko_age = minf(ko_age + delta, KO_SECONDS)
		overlay.queue_redraw()

## How many enemies are queued (x) and active (y) against this opponent. Drawn as small markers in the
## pane's corner at display resolution, so they stay readable even when the preview is not live.
func set_incoming(counts: Vector2i) -> void:
	if counts != incoming:
		incoming = counts
		overlay.queue_redraw()

# ---- the KO timeline (pure) -------------------------------------------------------------------------------------------

## Whether the blue card is on the pane at `age_` (from the third frame; the first two show the picture and the white square).
static func card_visible_at(age_: float) -> bool:
	return age_ >= SQUARE_2

## The side of the white rounded square of the first two frames, in design units (0 once the card is there): 11 on the first frame, 14.5 on the second.
static func square_side_at(age_: float) -> float:
	if age_ < 0.0 or age_ >= SQUARE_2:
		return 0.0
	return 11.0 if age_ < SQUARE_1 else 14.5

## The white burst over the card as it appears: opaque on its first frame, clear by BURST_END; its radius in design units.
static func burst_at(age_: float) -> Dictionary:
	if age_ < SQUARE_2 or age_ >= BURST_END:
		return {"alpha": 0.0, "radius": 0.0}
	return {"alpha": 1.0 - (age_ - SQUARE_2) / (BURST_END - SQUARE_2), "radius": 12.0 + 30.0 * (age_ - SQUARE_2)}

## The ring of eight stars: how far from the middle (design units), how big, how opaque. Alpha 0 outside SQUARE_1..STARS_END.
static func stars_at(age_: float) -> Dictionary:
	if age_ < SQUARE_1 or age_ >= STARS_END:
		return {"alpha": 0.0, "radius": 0.0, "size": 0.0}
	var q := (age_ - SQUARE_1) / (STARS_END - SQUARE_1)
	return {"alpha": 1.0 - q * q, "radius": 9.0 + 95.0 * (age_ - SQUARE_1), "size": 4.6 - 2.0 * q}

## The smoke: `grow` 0..1 while the puffs swell (PUFFS_START..), `ring` 0..1 while they thin into rings, `alpha` overall; all 0 outside.
static func puffs_at(age_: float) -> Dictionary:
	if age_ < PUFFS_START or age_ >= PUFFS_END:
		return {"grow": 0.0, "ring": 0.0, "alpha": 0.0}
	var grow := clampf((age_ - PUFFS_START) / 0.2, 0.0, 1.0)
	var ring := clampf((age_ - PUFFS_RINGS) / (PUFFS_END - PUFFS_RINGS), 0.0, 1.0)
	return {"grow": grow, "ring": ring, "alpha": 0.95 * (1.0 - ring * ring)}

## The second white rounded square at the middle (grows 12 x 12 -> 18 x 26 over 4 frames, then fades to nothing, tinted a pale green as it goes):
## {w, h, alpha}.
static func flash_2_at(age_: float) -> Dictionary:
	if age_ < FLASH_2_START or age_ >= FLASH_2_END:
		return {"w": 0.0, "h": 0.0, "alpha": 0.0}
	var k := clampf((age_ - FLASH_2_START) / (FLASH_2_PEAK - FLASH_2_START), 0.0, 1.0)
	var alpha := 1.0 if age_ < FLASH_2_PEAK else 1.0 - (age_ - FLASH_2_PEAK) / (FLASH_2_END - FLASH_2_PEAK)
	return {"w": lerpf(12.0, 18.0, k), "h": lerpf(12.0, 26.0, k), "alpha": alpha}

## The third, over the plate (grows 8 x 8 -> 17 x 24 and fades to a pale cyan): {w, h, alpha}.
static func flash_3_at(age_: float) -> Dictionary:
	if age_ < FLASH_3_START or age_ >= FLASH_3_END:
		return {"w": 0.0, "h": 0.0, "alpha": 0.0}
	var k := clampf((age_ - FLASH_3_START) / (FLASH_3_PEAK - FLASH_3_START), 0.0, 1.0)
	var alpha := 1.0 if age_ < FLASH_3_PEAK else 1.0 - (age_ - FLASH_3_PEAK) / (FLASH_3_END - FLASH_3_PEAK)
	return {"w": lerpf(8.0, 17.0, k), "h": lerpf(8.0, 24.0, k), "alpha": alpha}

## The pale rim round the plate as the card comes to rest: opaque-ish at GLOW_START, gone at KO_SECONDS.
static func glow_at(age_: float) -> float:
	if age_ < GLOW_START or age_ >= KO_SECONDS:
		return 0.0
	return 0.55 * (1.0 - (age_ - GLOW_START) / (KO_SECONDS - GLOW_START))

# ---- drawing ------------------------------------------------------------------------------------------------------------

func _draw_overlay() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if marked:
		_draw_card(r, ko_age)
	else:
		overlay.draw_rect(r.grow(-OUTLINE_WIDTH / 2.0), OUTLINE, false, OUTLINE_WIDTH)
	if show_labels and font != null:
		BattleHudText.draw(overlay, font, "%02d" % contestant_id, Vector2(1.5, 1.5), 0.6, TEXT_COLOR, OUTLINE, 0.5)
		if not marked:
			BattleHudText.draw(overlay, font, world_level_text(), Vector2(1.5, size.y - 6.0), 0.6, TEXT_COLOR, OUTLINE, 0.5)
	if draws_pips():
		_draw_pips()

## The KO card at `age_` seconds into its animation: the card from the third frame on, with the white squares, burst, stars and smoke
## over it (and, in the first two frames, over the picture).
func _draw_card(r: Rect2, age_: float) -> void:
	var u := r.size.x / DESIGN.x
	var c := r.get_center()
	if card_visible_at(age_):
		_card_face(r)
	var side := square_side_at(age_)
	if side > 0.0:
		_white_box(c, Vector2(side, side) * u, 1.0, u)
	var burst := burst_at(age_)
	if float(burst.alpha) > 0.0:
		overlay.draw_circle(c, float(burst.radius) * u, Color(1, 1, 1, float(burst.alpha)))
	var stars := stars_at(age_)
	if float(stars.alpha) > 0.0:
		for k in STAR_COUNT:
			var a := TAU * k / STAR_COUNT + 0.39 + float(contestant_id % 5) * 0.11
			_star(c + Vector2(cos(a), sin(a)) * float(stars.radius) * u, float(stars.size) * u, Color(STAR.r, STAR.g, STAR.b, float(stars.alpha)))
	var puffs := puffs_at(age_)
	if float(puffs.alpha) > 0.0:
		_puffs(c, u, puffs)
	var f2 := flash_2_at(age_)
	if float(f2.alpha) > 0.0:
		var tint := Color(1, 1, 1).lerp(Color(0.9, 1.0, 0.93), 1.0 - float(f2.alpha))
		_white_box(c, Vector2(float(f2.w), float(f2.h)) * u, float(f2.alpha), u, tint)
	var f3 := flash_3_at(age_)
	if float(f3.alpha) > 0.0:
		var tint3 := Color(1, 1, 1).lerp(Color(0.85, 1.0, 1.0), 1.0 - float(f3.alpha))
		_white_box(r.position + (PLATE_RECT.position + PLATE_RECT.size / 2.0) * u, Vector2(float(f3.w), float(f3.h)) * u, float(f3.alpha), u, tint3)
	var glow := glow_at(age_)
	if glow > 0.0:
		var plate := Rect2(r.position + PLATE_RECT.position * u, PLATE_RECT.size * u)
		BattleHudShapes.box(overlay, plate.grow(0.6 * u), Color(0, 0, 0, 0), Color(0.8, 1.0, 1.0, glow), 1.5 * u, 0.5 * u)

## A white rounded rectangle of `box_size` centred at `center`.
func _white_box(center: Vector2, box_size: Vector2, alpha: float, u: float, tint := Color(1, 1, 1)) -> void:
	var col := Color(tint.r, tint.g, tint.b, alpha)
	BattleHudShapes.box(overlay, Rect2(center - box_size / 2.0, box_size), col, col, 2.5 * u, 0.5 * u)

## A five-pointed star of outer radius `radius` centred at `center`.
func _star(center: Vector2, radius: float, color: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI / 2.0 + PI * i / 5.0
		var rr := radius if i % 2 == 0 else radius * 0.42
		pts.append(center + Vector2(cos(a), sin(a)) * rr)
	overlay.draw_colored_polygon(pts, color)

## The card itself: a bright blue ring, a dark slate field, a light plate with "KO" on its top and the placement in a black-edged teal
## block with a rivet in each corner (all rectangles measured on the reference, in design units scaled to this pane).
func _card_face(r: Rect2) -> void:
	var u := r.size.x / DESIGN.x
	var o := r.position
	BattleHudShapes.box(overlay, _scaled(RING_RECT, o, u), CARD_RING, CARD_RING, 2.5 * u, 0.5 * u)
	BattleHudShapes.box(overlay, _scaled(FIELD_RECT, o, u), CARD_FIELD, CARD_FIELD, 1.5 * u, 0.5 * u)
	var plate := _scaled(PLATE_RECT, o, u)
	BattleHudShapes.box(overlay, plate, CARD_PLATE, CARD_PLATE, 1.5 * u, 0.5 * u)
	var block := _scaled(BLOCK_RECT, o, u)
	BattleHudShapes.box(overlay, _scaled(BLOCK_EDGE_RECT, o, u), BLOCK_EDGE, BLOCK_EDGE, 1.0 * u, 0.5 * u)
	overlay.draw_rect(block, BLOCK_TEAL)
	var rv := 0.55 * u
	var inset := rv * 2.2
	for fx in [0.0, 1.0]:
		for fy in [0.0, 1.0]:
			overlay.draw_circle(block.position + Vector2(inset + fx * (block.size.x - inset * 2.0), inset + fy * (block.size.y - inset * 2.0)), rv, BLOCK_TEAL_DARK)
	if font == null:
		return
	var ko_box := Rect2(plate.position + Vector2(0, 1.0 * u), Vector2(plate.size.x, 9.0 * u))
	var ko_s := BattleHudText.fit_scale("KO", plate.size.x - 3.0 * u, 1.6 * u)
	BattleHudText.draw_in(overlay, font, "KO", ko_box, ko_s, Color(1, 1, 1, 1), Vector2(0.5, 0.5), CARD_FIELD, maxf(0.5, 0.6 * u))
	if placement > 0:
		var text := str(placement)
		var ps := BattleHudText.fit_scale(text, block.size.x - 4.0 * u, 1.5 * u)
		BattleHudText.draw_in(overlay, font, text, block, ps, Color(1, 1, 1, 1), Vector2(0.5, 0.5), BLOCK_EDGE, maxf(0.5, 0.5 * u))

static func _scaled(rect: Rect2, origin: Vector2, u: float) -> Rect2:
	return Rect2(origin + rect.position * u, rect.size * u)

## The smoke over the card: cream circles in a cloud that swells (`grow`), then thin into hollow rings (`ring`) that fade (`alpha`).
func _puffs(center: Vector2, u: float, p: Dictionary) -> void:
	var rot := float(contestant_id % 7) * 0.31
	for k in PUFF_COUNT:
		var a := TAU * k / PUFF_COUNT + rot
		var ring_k := float(k % 3) * 2.2 # three puffs in the middle, the rest around it
		var dist := (3.0 + ring_k * 2.4 + 4.0 * float(p.grow)) * u
		var rad := (2.2 + 3.6 * float(p.grow)) * u * (1.0 + 0.12 * float(k % 3))
		var col := Color(PUFF.r, PUFF.g, PUFF.b, float(p.alpha))
		var at := center + Vector2(cos(a), sin(a)) * dist
		if float(p.ring) > 0.0:
			overlay.draw_arc(at, rad * 0.8, 0.0, TAU, 14, col, maxf(0.5, rad * 0.45 * (1.0 - float(p.ring))))
		else:
			overlay.draw_circle(at, rad, col)

## One marker per enemy sent at this opponent, from the right edge: lit red for an ACTIVE one, an
## outline for a QUEUED one that has not arrived yet.
func _draw_pips() -> void:
	var active := mini(incoming.y, MAX_PIPS)
	var queued := mini(incoming.x, MAX_PIPS - active)
	var x := size.x - 5.0
	for i in active + queued:
		var r := Rect2(x - i * 4.0, 2.0, 3.0, 3.0)
		overlay.draw_rect(r.grow(1.0), PIP_EDGE)
		if i < active:
			overlay.draw_rect(r, PIP_ACTIVE)
		else:
			overlay.draw_rect(r, PIP_QUEUED, false, 1.0)
