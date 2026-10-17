class_name BattlePreviewCell
extends Control
## One opponent's picture inside the shared BattlePreviewAtlas: always exactly
## BattlePreviewAtlas.CELL_PX (187x240), drawn at the classic camera's 1:1 gameplay scale by a
## swappable BattlePreviewRenderer. Only the picture lives here. Frame, id, level text and the KO
## marking are the pane's job and are drawn at display resolution, never baked into this image.
## A view of a BattleContestant: it owns no match state and has no scene tree of its own.

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
## An opponent that plays a real game (doc 56): the picture is its own game's screen (a crop of its viewport, as the
## reference's panes are), and it owns no frame or track.
var bot: BattleBotWorld = null
var _bot_fade := -1.0

## Dev measurements: microseconds spent inside renderers' draw() and how many draws ran.
static var stat_live_us := 0
static var stat_live_draws := 0
static var stat_placeholder_us := 0
static var stat_placeholder_draws := 0

var _contestant: BattleContestant = null
var _signature := -1

func _init(id := 0) -> void:
	contestant_id = id
	name = "Cell%02d" % id
	size = Vector2(BattlePreviewAtlas.CELL_PX)
	custom_minimum_size = size
	clip_contents = true # nothing may spill into the padding or the neighbouring cell
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST # 1:1 art stays crisp; the pane downsamples
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## Rebinds to `c` (view only) and redraws only when something visible changed.
func refresh(c: BattleContestant) -> void:
	_contestant = c
	ko = not c.alive
	levels_cleared = c.levels_cleared
	progress = c.progress
	# Integer signature (no string building: this runs for 34 cells every frame).
	var sig := (int(ko) | (c.power << 1) | (levels_cleared << 3) | (int(progress * 64.0) << 16))
	if sig != _signature:
		_signature = sig
		queue_redraw()

## Holds this picture as it is (the round is over): the cell keeps a private copy of the contestant it was last drawn for, so a
## later redraw, whatever the session does meanwhile (the results fast-forward the match), still draws this same picture. The live
## frame is whatever the track last wrote; with the driver stopped nothing writes it again.
func freeze() -> void:
	if _contestant != null:
		_contestant = _contestant.copy()

## Attaches (or, with null, detaches) a live preview.
func set_live(live_renderer_: BattlePreviewRenderer, frame_: BattlePreviewFrame) -> void:
	live_renderer = live_renderer_
	frame = frame_
	queue_redraw()

func is_live() -> bool:
	return live_renderer != null and frame != null and frame.valid

## Shows the real game of `bot_` (null: back to the previews).
func set_bot(bot_: BattleBotWorld) -> void:
	bot = bot_
	_bot_fade = -1.0
	queue_redraw()

func is_bot() -> bool:
	return bot != null and is_instance_valid(bot)

## The picture's own KO marking: shown once a live death animation has finished (the placeholder
## has no animation, so it shows it at once). The session's KO state is never delayed.
func marked() -> bool:
	if is_bot():
		return ko and bot.ko_shown
	return ko and (not is_live() or frame.ko_overlay)

## The course the picture shows (it trails the session while a live run is playing).
func course_index() -> int:
	if is_bot():
		return bot.course
	return frame.displayed_course if is_live() else levels_cleared

## A real game's picture changes by itself (its viewport texture); only its fade needs a redraw here.
func _process(_delta: float) -> void:
	if is_bot() and bot.fade != _bot_fade:
		_bot_fade = bot.fade
		queue_redraw()

func world_level_text() -> String:
	return BattleCourse.text(course_index())

func _draw() -> void:
	if _contestant == null:
		return
	var t0 := Time.get_ticks_usec()
	if is_bot():
		var tex := bot.pane_texture()
		if tex != null:
			draw_texture_rect_region(tex, Rect2(Vector2.ZERO, size), BattleBotWorld.PANE_CROP)
		if bot.fade > 0.0:
			draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, bot.fade))
		stat_live_us += Time.get_ticks_usec() - t0
		stat_live_draws += 1
	elif is_live():
		live_renderer.draw(self, _contestant, size, frame)
		stat_live_us += Time.get_ticks_usec() - t0
		stat_live_draws += 1
	else:
		renderer.draw(self, _contestant, size)
		stat_placeholder_us += Time.get_ticks_usec() - t0
		stat_placeholder_draws += 1
