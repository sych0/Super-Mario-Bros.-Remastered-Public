class_name BattlePreviewSurface
extends Control
## One opponent window. A view of a BattleContestant: it draws the contestant through a
## swappable BattlePreviewRenderer in logical space (240 px tall, as wide as the slot's aspect
## allows, so the cell is a narrow full-height crop of the level like the reference), then adds
## frame, id, level and KO marking in slot space. It owns no match state and has no scene tree
## of its own, so 34 of them cost 34 lightweight draw calls, not 34 games.

const LOGICAL_HEIGHT := 240.0
const FRAME_ALIVE := Color(0.95, 0.6, 0.1, 1)
const FRAME_KO := Color(1, 0.1, 0.1, 1)
const TEXT_COLOR := Color(1, 1, 1, 1)
const LEVELS_PER_WORLD := 4

var contestant_id := 0
var ko := false
var levels_cleared := 0
var progress := 0.0
var renderer: BattlePreviewRenderer = BattlePlaceholderRenderer.new() ## the fallback
## Optional live renderer + the frame a BattlePreviewTrack keeps updating. Used only while the
## frame is valid; any time it isn't (unsupported level, run over) the placeholder draws.
var live_renderer: BattlePreviewRenderer = null
var frame: BattlePreviewFrame = null
var font: Font = null

## Dev measurements: microseconds spent inside renderers' draw() and how many draws ran.
static var stat_live_us := 0
static var stat_live_draws := 0
static var stat_placeholder_us := 0
static var stat_placeholder_draws := 0

var _contestant: BattleContestant = null
var _signature := ""

func _init(id := 0, font_: Font = null) -> void:
	contestant_id = id
	font = font_
	name = "Preview%02d" % id
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## Rebinds to `c` (view only) and redraws only when something visible changed.
func refresh(c: BattleContestant) -> void:
	_contestant = c
	ko = not c.alive
	levels_cleared = c.levels_cleared
	progress = c.progress
	var sig := "%s|%d|%d|%d" % [ko, levels_cleared, int(progress * 64.0), c.power]
	if sig != _signature:
		_signature = sig
		queue_redraw()

## Attaches (or, with null, detaches) a live preview. Mipmapped filtering is set on this
## surface only, because the live renderer draws heavily minified textures.
func set_live(live_renderer_: BattlePreviewRenderer, frame_: BattlePreviewFrame) -> void:
	live_renderer = live_renderer_
	frame = frame_
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS if live_renderer_ != null else CanvasItem.TEXTURE_FILTER_PARENT_NODE
	queue_redraw()

func is_live() -> bool:
	return live_renderer != null and frame != null and frame.valid

func world_level_text() -> String:
	if is_live():
		return BattleCourse.text(frame.displayed_course) # the picture's level, which trails the session
	return BattleCourse.text(levels_cleared)

func _draw() -> void:
	if _contestant == null:
		return
	var s := size.y / LOGICAL_HEIGHT
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))
	var live := is_live()
	var t0 := Time.get_ticks_usec()
	if live:
		live_renderer.draw(self, _contestant, size / s, frame)
		stat_live_us += Time.get_ticks_usec() - t0
		stat_live_draws += 1
	else:
		renderer.draw(self, _contestant, size / s)
		stat_placeholder_us += Time.get_ticks_usec() - t0
		stat_placeholder_draws += 1
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# The frame border follows the session at once; the picture's KO marking waits for the
	# death animation to finish.
	var marked := ko and (not live or frame.ko_overlay)
	if marked:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.55, 0, 0, 0.7))
		draw_line(Vector2.ZERO, size, Color.WHITE, 1.5)
		draw_line(Vector2(size.x, 0), Vector2(0, size.y), Color.WHITE, 1.5)
	draw_rect(Rect2(Vector2.ZERO, size), FRAME_KO if ko else FRAME_ALIVE, false, 1.0)
	if font != null:
		_text("%02d" % contestant_id, Vector2(1, 1), 0.6)
		if not marked:
			_text(world_level_text(), Vector2(1, size.y - 6), 0.6)

# The bitmap font draws its glyph box ~15px above the baseline we give it (at scale 1).
func _text(text: String, top_left: Vector2, text_scale: float) -> void:
	draw_set_transform(top_left, 0.0, Vector2(text_scale, text_scale))
	draw_string(font, Vector2(0, 15), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, TEXT_COLOR)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
