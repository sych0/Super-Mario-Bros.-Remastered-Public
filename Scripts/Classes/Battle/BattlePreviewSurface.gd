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
var renderer: BattlePreviewRenderer = BattlePlaceholderRenderer.new()
var font: Font = null

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

func world_level_text() -> String:
	return "%d-%d" % [1 + levels_cleared / LEVELS_PER_WORLD, 1 + levels_cleared % LEVELS_PER_WORLD]

func _draw() -> void:
	if _contestant == null:
		return
	var s := size.y / LOGICAL_HEIGHT
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))
	renderer.draw(self, _contestant, size / s)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if ko:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.55, 0, 0, 0.7))
		draw_line(Vector2.ZERO, size, Color.WHITE, 1.5)
		draw_line(Vector2(size.x, 0), Vector2(0, size.y), Color.WHITE, 1.5)
	draw_rect(Rect2(Vector2.ZERO, size), FRAME_KO if ko else FRAME_ALIVE, false, 1.0)
	if font != null:
		_text("%02d" % contestant_id, Vector2(1, 1), 0.6)
		if not ko:
			_text(world_level_text(), Vector2(1, size.y - 6), 0.6)

# The bitmap font draws its glyph box ~15px above the baseline we give it (at scale 1).
func _text(text: String, top_left: Vector2, text_scale: float) -> void:
	draw_set_transform(top_left, 0.0, Vector2(text_scale, text_scale))
	draw_string(font, Vector2(0, 15), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, TEXT_COLOR)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
