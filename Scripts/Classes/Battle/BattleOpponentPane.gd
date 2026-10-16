class_name BattleOpponentPane
extends Control
## One opponent window on the Battle canvas (display resolution). It shows its own region of the
## shared BattlePreviewAtlas, scaled down through the 4-tap footprint shader, and draws everything
## that must stay sharp on top of it: the hairline outline, the KO card and the incoming markers. A view only: it
## reads the contestant and its BattlePreviewCell and owns no match state.
##
## The live pane carries no text (doc 47 B35-PREVIEW-001: no id, no course): the contestant number and the "W-L" course
## text are debug labels, shown only when `show_labels` is on (SMB1R_BATTLE_LABELS=1, `--battle-labels`, or F3 on the
## Battle screen).
##
## The KO card (B35-KO-001/002): when the preview shows the contestant's KO (`marked`) the pane plays a pane-local
## animation of KO_SECONDS, then rests as the card: a white flash, the blue card popping in from the middle with
## an overshoot, a starburst and smoke puffs, a second flash, and the settle. The card has "KO" at the top and the
## contestant's final placement in a teal block with rivets. The pane never moves or changes size (no reordering) and the
## whole animation is drawn at display resolution here: it costs the atlas nothing. Time is the screen's: `advance` is
## not called while the game is paused. The orange card for an opponent the player KO'd (B35-KO-003) is not built: it needs
## the KO credit rules of the timer milestone.

const OUTLINE := Color(0.23, 0.2, 0.13, 1) ## the reference's dark line (59,51,33)
const OUTLINE_WIDTH := 0.5
const TEXT_COLOR := Color(1, 1, 1, 1)
const SHADER_PATH := "res://Scenes/Parts/BattlePreviewDownsample.gdshader"
const PIP_ACTIVE := Color(1.0, 0.15, 0.08, 1)
const PIP_QUEUED := Color(1.0, 0.85, 0.3, 1)
const PIP_EDGE := Color(0, 0, 0, 0.8)
const MAX_PIPS := 6

const CARD_BLUE := Color(0.18, 0.38, 0.84, 1)
const CARD_BLUE_DARK := Color(0.07, 0.15, 0.46, 1)
const CARD_BLUE_LIGHT := Color(0.5, 0.68, 0.98, 1)
const BLOCK_TEAL := Color(0.08, 0.6, 0.58, 1)
const BLOCK_TEAL_DARK := Color(0.03, 0.34, 0.34, 1)
const RIVET := Color(0.78, 0.96, 0.94, 1)
const FLASH := Color(1, 1, 1, 1)

# The KO animation timeline, in seconds from the pane's first flash (doc 47 B35-KO-002: about 0.8 s end to end).
const KO_SECONDS := 0.8
const FLASH_1_END := 0.07
const POP_START := 0.07
const POP_END := 0.5
const PUFFS_START := 0.1
const PUFFS_END := 0.6
const FLASH_2_START := 0.6
const FLASH_2_END := 0.67
const PUFF_COUNT := 6

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

## Whether the KO animation is still playing.
func is_animating() -> bool:
	return marked and ko_age < KO_SECONDS

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

## The white flash over the pane `age_` seconds into the KO: the first flash 1 -> 0 over FLASH_1_END, the second later.
static func flash_at(age_: float) -> float:
	if age_ < 0.0:
		return 0.0
	if age_ < FLASH_1_END:
		return 1.0 - 0.7 * age_ / FLASH_1_END
	if age_ >= FLASH_2_START and age_ < FLASH_2_END:
		return 0.8 * (1.0 - (age_ - FLASH_2_START) / (FLASH_2_END - FLASH_2_START))
	return 0.0

## The card's scale: 0 before it pops, an overshoot past 1 while it pops (an ease-out-back), then 1.
static func card_scale_at(age_: float) -> float:
	if age_ < POP_START:
		return 0.0
	if age_ >= POP_END:
		return 1.0
	var t := (age_ - POP_START) / (POP_END - POP_START)
	var c1 := 2.2
	var u := t - 1.0
	var back := 1.0 + (c1 + 1.0) * u * u * u + c1 * u * u
	return maxf(back, 0.0)

## 0..1 across the puffs and the starburst (-1 outside them).
static func puff_progress_at(age_: float) -> float:
	if age_ < PUFFS_START or age_ >= PUFFS_END:
		return -1.0
	return (age_ - PUFFS_START) / (PUFFS_END - PUFFS_START)

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
	if not marked:
		_draw_pips()

## The KO card at `age_` seconds into its animation: flashes over, the card (scaled from the middle) under them, puffs
## and the starburst over the card.
func _draw_card(r: Rect2, age_: float) -> void:
	var s := card_scale_at(age_)
	if s > 0.0:
		var c := Rect2(r.get_center() - r.size * s / 2.0, r.size * s)
		_card_face(c, s)
	var p := puff_progress_at(age_)
	if p >= 0.0:
		_puffs(r.get_center(), p)
	var f := flash_at(age_)
	if f > 0.0:
		overlay.draw_rect(r, Color(1, 1, 1, f))

## The card itself in `c` (a rect; `s` is its scale, which text follows).
func _card_face(c: Rect2, s: float) -> void:
	var u := c.size.x / 32.75 # one design unit: the card is drawn for a 32.75 wide pane
	overlay.draw_rect(c, CARD_BLUE_DARK)
	overlay.draw_rect(c.grow(-0.5 * u), CARD_BLUE_LIGHT)
	overlay.draw_rect(c.grow(-1.25 * u), CARD_BLUE)
	if font == null or s < 0.55:
		return
	var inner := c.grow(-1.25 * u)
	# "KO", bold white with a dark edge, at the top
	var ko_s := BattleHudText.fit_scale("KO", inner.size.x - 4.0 * u, 1.6 * u)
	var ko_box := Rect2(inner.position + Vector2(0, 3.0 * u), Vector2(inner.size.x, BattleHudText.ink_height(ko_s)))
	BattleHudText.draw_in(overlay, font, "KO", ko_box, ko_s, Color(1, 1, 1, 1), Vector2(0.5, 0.5), CARD_BLUE_DARK, maxf(0.5, 0.6 * u))
	# the placement, in a teal block with a rivet in each corner
	var block := Rect2(inner.position + Vector2(inner.size.x * 0.12, inner.size.y * 0.5), Vector2(inner.size.x * 0.76, inner.size.y * 0.4))
	overlay.draw_rect(block.grow(0.5 * u), BLOCK_TEAL_DARK)
	overlay.draw_rect(block, BLOCK_TEAL)
	var rv := 0.7 * u
	var inset := rv * 1.6
	for fx in [0.0, 1.0]:
		for fy in [0.0, 1.0]:
			overlay.draw_circle(block.position + Vector2(inset + fx * (block.size.x - inset * 2.0), inset + fy * (block.size.y - inset * 2.0)), rv, RIVET)
	if placement > 0:
		var text := str(placement)
		var ps := BattleHudText.fit_scale(text, block.size.x - 5.0 * u, 1.4 * u)
		BattleHudText.draw_in(overlay, font, text, block, ps, Color(1, 1, 1, 1), Vector2(0.5, 0.5), BLOCK_TEAL_DARK, maxf(0.5, 0.5 * u))

## The starburst and the smoke: `p` is 0..1 across them.
func _puffs(center: Vector2, p: float) -> void:
	var fade := 1.0 - p
	# starburst: eight rays that grow and fade over the first half
	if p < 0.6:
		var q := p / 0.6
		for k in 8:
			var a := TAU * k / 8.0 + 0.2
			var dir := Vector2(cos(a), sin(a))
			var from := center + dir * (3.0 + 4.0 * q)
			var to := center + dir * (6.0 + 15.0 * q)
			overlay.draw_line(from, to, Color(1, 1, 0.75, (1.0 - q) * 0.95), 1.25)
	# smoke: soft white puffs drift outward
	for k in PUFF_COUNT:
		var a := TAU * k / PUFF_COUNT + float(contestant_id % 7) * 0.31
		var dist := 4.0 + 13.0 * (1.0 - fade * fade)
		overlay.draw_circle(center + Vector2(cos(a), sin(a)) * dist, 2.0 + 3.2 * p, Color(1, 1, 1, 0.8 * fade))

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
