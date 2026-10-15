class_name BattleOpponentTile
extends Control
## One compact tile in the Battle opponent grid. A pure view of a BattleContestant:
## it never owns or changes match state.

const SIZE_PX := Vector2(26, 13)
const ALIVE_BG := Color(0, 0, 0, 0.55)
const KO_BG := Color(0.75, 0.05, 0.05, 0.85)
const BAR_COLOR := Color(0.35, 0.9, 0.35, 1)
const TEXT_ALIVE := Color(1, 1, 1, 1)
const TEXT_KO := Color(1, 0.8, 0.8, 1)

var contestant_id := 0
var ko := false
var bar_fraction := 0.0
var levels_cleared := 0

var _bg := ColorRect.new()
var _bar := ColorRect.new()
var _label := Label.new()

func _init(id := 0, font: Font = null) -> void:
	contestant_id = id
	name = "Tile%02d" % id
	custom_minimum_size = SIZE_PX
	size = SIZE_PX
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.color = ALIVE_BG
	_bg.size = SIZE_PX
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	_bar.color = BAR_COLOR
	_bar.position = Vector2(0, SIZE_PX.y - 2)
	_bar.size = Vector2(0, 2)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar)
	_label.position = Vector2(1, -2)
	_label.size = Vector2(SIZE_PX.x - 1, SIZE_PX.y - 2)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.clip_text = true
	if font != null:
		_label.add_theme_font_override("font", font)
	_label.add_theme_font_size_override("font_size", 8)
	add_child(_label)
	update_from(null)

func update_from(c: BattleContestant) -> void:
	if c != null:
		ko = not c.alive
		levels_cleared = c.levels_cleared
		bar_fraction = clampf(c.progress, 0.0, 1.0)
	_bg.color = KO_BG if ko else ALIVE_BG
	_bar.visible = not ko
	_bar.size.x = SIZE_PX.x * bar_fraction
	if ko:
		_label.text = "%02d X" % contestant_id
		_label.add_theme_color_override("font_color", TEXT_KO)
	else:
		_label.text = "%02d %d" % [contestant_id, levels_cleared]
		_label.add_theme_color_override("font_color", TEXT_ALIVE)
