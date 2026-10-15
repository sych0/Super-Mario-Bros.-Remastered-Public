class_name BattleHud
extends CanvasLayer
## Battle-only screen composition: the game's native 16:9 viewport with the real player's
## classic 256x240 gameplay area untouched in the centre, and the 34 opponent preview
## surfaces plus status in the two side panels (see BattleHudLayout). A pure view of the
## current BattleSession; lives under the scene-tree root so it survives level transitions,
## and frees itself (restoring the user's resolution) as soon as Battle is no longer active.

const FONT_PATH := "res://Resources/ThemedResources/FontMain.tres"
## Global.RESOLUTIONS[2] = 426x240, the game's existing native 16:9 option.
const RESOLUTION_INDEX := 2
const PANEL_COLOR := Color(0.97, 0.70, 0.14, 1) # reference's gold background
const PANEL_EDGE := Color(0.93, 0.55, 0.08, 1)
const BADGE_FILL := Color(0.99, 0.97, 0.9, 1)
const BADGE_EDGE := Color(0.4, 0.22, 0.1, 1)
const BADGE_TEXT := Color(0.25, 0.14, 0.06, 1)

static var instance: BattleHud = null

var session: BattleSession = null # the session being displayed (kept alive for the result)
var layout := {}
var surfaces: Array[BattlePreviewSurface] = []
var showing_result := false
var result_text := ""
var result_age := 0.0
var _font: Font = null
var _time_label := Label.new()
var _rank_label := Label.new()
var _alive_label := Label.new() # alive count in the right badge, over "/35"
var _course_label := Label.new() # "W-L" in the left badge
var _total_label := Label.new()
var _overlay := ColorRect.new()
var _overlay_label := Label.new()

## Creates the HUD once. Safe to call every level load; never duplicates.
static func ensure(tree: SceneTree) -> BattleHud:
	if is_instance_valid(instance):
		return instance
	var hud := BattleHud.new()
	instance = hud
	tree.root.add_child.call_deferred(hud)
	return hud

static func is_active() -> bool:
	return is_instance_valid(instance) and not instance.is_queued_for_deletion()

## Resolution index the level should use: the forced 16:9 one while Battle is up.
static func resolution_index(user_index: int) -> int:
	return RESOLUTION_INDEX if is_active() else user_index

func _init() -> void:
	name = "BattleHud"
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS

func _ready() -> void:
	if ResourceLoader.exists(FONT_PATH):
		_font = load(FONT_PATH)
	get_tree().root.content_scale_size = Global.RESOLUTIONS[RESOLUTION_INDEX]
	get_tree().root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	_build(BattleHudLayout.compute(Global.RESOLUTIONS[RESOLUTION_INDEX]))
	session = BattleSession.current

func _exit_tree() -> void:
	if instance == self:
		instance = null
	# Hand the window back to the user's own resolution setting (same rule as Level).
	var tree := get_tree()
	if tree != null and Settings.file != null:
		var idx: int = Settings.file.video.size
		tree.root.content_scale_size = Global.RESOLUTIONS[idx]
		tree.root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND if idx == Global.RESOLUTIONS.size() - 1 else Window.CONTENT_SCALE_ASPECT_KEEP

func _build(layout_: Dictionary) -> void:
	layout = layout_
	for side in ["left", "right"]:
		var panel := ColorRect.new()
		panel.color = PANEL_COLOR
		panel.position = layout[side].position
		panel.size = layout[side].size
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(panel)
		# Darker stripe on the edge next to the gameplay area, like the reference's frame.
		var edge := ColorRect.new()
		edge.color = PANEL_EDGE
		edge.size = Vector2(2, panel.size.y)
		edge.position = Vector2(panel.size.x - 2 if side == "left" else 0, 0)
		edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(edge)
	for i in BattleHudLayout.OPPONENTS:
		var surface := BattlePreviewSurface.new(i + 1, _font)
		var rect: Rect2 = layout.slots[i]
		surface.position = rect.position
		surface.size = rect.size
		add_child(surface)
		surfaces.append(surface)
	_place(_time_label, layout.status_left, 1.0)
	_place(_rank_label, layout.status_right, 1.0)
	_time_label.add_theme_color_override("font_color", BADGE_TEXT)
	_rank_label.add_theme_color_override("font_color", BADGE_TEXT)
	var badge_l: Rect2 = layout.badge_left
	var badge_r: Rect2 = layout.badge_right
	_add_badge(badge_l)
	_add_badge(badge_r)
	# Course "W-L" sits low in the left badge (the reference's "COURSE" caption does not fit 26 px).
	_place(_course_label, Rect2(badge_l.position + Vector2(2, badge_l.size.y - 14), Vector2(badge_l.size.x, 12)), 0.85)
	# Small Mario head icon above the alive count.
	var icon := ColorRect.new()
	icon.color = Color(0.85, 0.15, 0.1)
	icon.position = badge_r.position + Vector2(badge_r.size.x / 2.0 - 4, 3)
	icon.size = Vector2(8, 8)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(icon)
	# Alive count over a fixed "/35" (the reference's "35/35", stacked to fit the narrow badge).
	_place(_alive_label, Rect2(badge_r.position + Vector2(2, badge_r.size.y - 27), Vector2(badge_r.size.x, 12)), 0.85)
	_place(_total_label, Rect2(badge_r.position + Vector2(2, badge_r.size.y - 14), Vector2(badge_r.size.x, 12)), 0.85)
	_total_label.text = "/%d" % BattleSession.CONTESTANT_COUNT
	for l in [_course_label, _alive_label, _total_label]:
		l.add_theme_color_override("font_color", BADGE_TEXT)
	var center: Rect2 = layout.center
	_overlay.color = Color(0, 0, 0, 0.88)
	_overlay.position = center.position
	_overlay.size = center.size
	_overlay.visible = false
	add_child(_overlay)
	_overlay_label.position = Vector2(24, 40)
	_overlay_label.size = Vector2(center.size.x - 48, 160)
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style(_overlay_label)
	_overlay.add_child(_overlay_label)

func _add_badge(rect: Rect2) -> void:
	var edge := ColorRect.new()
	edge.color = BADGE_EDGE
	edge.position = rect.position
	edge.size = rect.size
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(edge)
	var fill := ColorRect.new()
	fill.color = BADGE_FILL
	fill.position = Vector2(1, 1)
	fill.size = rect.size - Vector2(2, 2)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	edge.add_child(fill)

func _place(label: Label, rect: Rect2, text_scale: float) -> void:
	label.position = rect.position
	label.size = rect.size / text_scale
	label.scale = Vector2(text_scale, text_scale)
	_style(label)
	add_child(label)

func _style(label: Label) -> void:
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", 8)

func _process(delta: float) -> void:
	if showing_result:
		result_age += delta
		return
	# Battle over (left to title, quit, etc.): disappear completely.
	if BattleSession.current == null or Global.current_game_mode != Global.GameMode.BATTLE:
		queue_free()
		return
	session = BattleSession.current
	refresh()

## Re-reads the session into the surfaces and labels.
func refresh() -> void:
	if session == null:
		return
	for i in surfaces.size():
		surfaces[i].refresh(session.contestants[i + 1])
	var p := session.get_player()
	var speed := "" if BattleHandler.sim_speed() == 1 else " X%d" % BattleHandler.sim_speed()
	_time_label.text = "TIME\n%03d%s" % [maxi(p.time_left, 0), speed]
	_rank_label.text = "RANK\n%d/%d" % [session.get_provisional_rank(), BattleSession.CONTESTANT_COUNT]
	_alive_label.text = "%d" % session.alive_count
	_course_label.text = "%d-%d" % [session.world, session.level]

## Shows the end-of-match overlay for `final_session`. `others_alive` is how many opponents
## were still in when the player went out.
func show_result(final_session: BattleSession, others_alive: int) -> void:
	session = final_session
	showing_result = true
	result_age = 0.0
	refresh()
	var p := final_session.get_player()
	var lines: Array[String] = ["BATTLE OVER", ""]
	if final_session.winner_id == BattleSession.PLAYER_ID:
		lines.append("YOU WON!")
	else:
		lines.append("YOU PLACED %d / %d" % [p.placement, BattleSession.CONTESTANT_COUNT])
	lines.append("OUT BY: " + BattleSession.KoCause.keys()[p.ko_cause])
	lines.append("OPPONENTS LEFT WHEN OUT: %d" % others_alive)
	lines.append("LEVELS CLEARED: %d" % p.levels_cleared)
	lines.append("")
	if final_session.winner_id == BattleSession.PLAYER_ID:
		lines.append("WINNER: YOU")
	else:
		lines.append("WINNER: #%02d" % final_session.winner_id)
	lines.append("MATCH FINISHED")
	lines.append("")
	lines.append("PRESS JUMP TO CONTINUE")
	result_text = "\n".join(lines)
	_overlay_label.text = result_text
	_overlay.visible = true

func result_dismissed() -> bool:
	return showing_result and (result_age >= BattleHandler.RESULT_MAX_SECONDS or (
		result_age >= BattleHandler.RESULT_MIN_SECONDS and Global.player_action_just_pressed("jump", 0)))
