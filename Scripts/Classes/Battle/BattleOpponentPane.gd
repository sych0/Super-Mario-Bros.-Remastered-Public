class_name BattleOpponentPane
extends Control
## One opponent window on the Battle canvas (display resolution). It shows its own region of the
## shared BattlePreviewAtlas, scaled down through the 4-tap footprint shader, and draws everything
## that must stay sharp on top of it: the frame, the contestant number, the level text and the KO
## marking. A view only: it reads the contestant and its BattlePreviewCell and owns no match state.

const FRAME_ALIVE := Color(0.95, 0.6, 0.1, 1)
const FRAME_KO := Color(1, 0.1, 0.1, 1)
const TEXT_COLOR := Color(1, 1, 1, 1)
const SHADER_PATH := "res://Scenes/Parts/BattlePreviewDownsample.gdshader"
const PIP_ACTIVE := Color(1.0, 0.15, 0.08, 1)
const PIP_QUEUED := Color(1.0, 0.85, 0.3, 1)
const PIP_EDGE := Color(0, 0, 0, 0.8)
const MAX_PIPS := 6

static var _shader: Shader = null

var contestant_id := 0
var ko := false
var marked := false ## the KO wash + cross is showing
var incoming := Vector2i.ZERO ## enemies sent at this opponent: x queued, y active (a view of the session's queue, see BattleAttackPresentation)
var cell: BattlePreviewCell = null
var region_px := Rect2i() ## this pane's cell in the atlas, in texels
var picture := TextureRect.new() ## the downsampled atlas region
var overlay := Control.new() ## frame, id, level text and KO marking at display resolution
var font: Font = null

var _signature := -1

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
	marked = cell.marked() if cell != null else ko
	var sig := int(ko) | (int(marked) << 1) | ((cell.course_index() if cell != null else 0) << 2)
	if sig != _signature:
		_signature = sig
		overlay.queue_redraw()

## How many enemies are queued (x) and active (y) against this opponent. Drawn as small markers in the
## pane's corner at display resolution, so they stay readable even when the preview is not live.
func set_incoming(counts: Vector2i) -> void:
	if counts != incoming:
		incoming = counts
		overlay.queue_redraw()

func _draw_overlay() -> void:
	if marked:
		overlay.draw_rect(Rect2(Vector2.ZERO, size), Color(0.55, 0, 0, 0.7))
		overlay.draw_line(Vector2.ZERO, size, Color.WHITE, 1.5)
		overlay.draw_line(Vector2(size.x, 0), Vector2(0, size.y), Color.WHITE, 1.5)
	overlay.draw_rect(Rect2(Vector2.ZERO, size), FRAME_KO if ko else FRAME_ALIVE, false, 1.0)
	if font != null:
		_text("%02d" % contestant_id, Vector2(1, 1), 0.6)
		if not marked:
			_text(world_level_text(), Vector2(1, size.y - 6), 0.6)
	if not marked:
		_draw_pips()

# The bitmap font draws its glyph box ~15px above the baseline we give it (at scale 1).
func _text(text: String, top_left: Vector2, text_scale: float) -> void:
	overlay.draw_set_transform(top_left, 0.0, Vector2(text_scale, text_scale))
	overlay.draw_string(font, Vector2(0, 15), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, TEXT_COLOR)
	overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

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
