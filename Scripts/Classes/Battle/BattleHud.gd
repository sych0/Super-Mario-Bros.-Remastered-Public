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
const PANEL_COLOR := Color(0.03, 0.03, 0.1, 1)

static var instance: BattleHud = null

var session: BattleSession = null # the session being displayed (kept alive for the result)
var layout := {}
var surfaces: Array[BattlePreviewSurface] = []
var showing_result := false
var result_text := ""
var result_age := 0.0
var _font: Font = null
var _time_label := Label.new()
var _alive_label := Label.new()
var _rank_label := Label.new()
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
	for i in BattleHudLayout.OPPONENTS:
		var surface := BattlePreviewSurface.new(i + 1, _font)
		var rect: Rect2 = layout.slots[i]
		surface.position = rect.position
		surface.size = rect.size
		add_child(surface)
		surfaces.append(surface)
	var left: Rect2 = layout.status_left
	var right: Rect2 = layout.status_right
	_place(_time_label, left.position, left.size)
	_place(_alive_label, right.position, Vector2(right.size.x, right.size.y / 2.0))
	_place(_rank_label, right.position + Vector2(0, right.size.y / 2.0), Vector2(right.size.x, right.size.y / 2.0))
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

func _place(label: Label, pos: Vector2, size: Vector2) -> void:
	label.position = pos
	label.size = size
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	_time_label.text = "TIME\n%03d" % maxi(p.time_left, 0)
	var speed := "" if BattleHandler.sim_speed() == 1 else "\nX%d" % BattleHandler.sim_speed()
	_alive_label.text = "ALIVE\n%d" % session.alive_count + speed
	_rank_label.text = "RANK\n%d/%d" % [session.get_provisional_rank(), BattleSession.CONTESTANT_COUNT]

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
