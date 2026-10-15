class_name BattleHud
extends CanvasLayer
## Battle-only view of the current BattleSession: status line, 34-tile opponent grid and the
## result overlay. Holds no match state of its own. Lives under the scene-tree root so it
## survives level transitions, and frees itself as soon as Battle is no longer active.

const FONT_PATH := "res://Resources/ThemedResources/FontMain.tres"
const TILES_PER_COLUMN := 17
const GRID_TOP := 18.0
const SCREEN_W := 256.0

static var instance: BattleHud = null

var session: BattleSession = null # the session being displayed (kept alive for the result)
var tiles: Array[BattleOpponentTile] = []
var showing_result := false
var result_text := ""
var result_age := 0.0
var _font: Font = null
var _status := Label.new()
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
	return is_instance_valid(instance)

func _init() -> void:
	name = "BattleHud"
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS

func _ready() -> void:
	if ResourceLoader.exists(FONT_PATH):
		_font = load(FONT_PATH)
	_build()
	session = BattleSession.current

func _exit_tree() -> void:
	if instance == self:
		instance = null

func _build() -> void:
	for i in 34:
		var tile := BattleOpponentTile.new(i + 1, _font)
		var column := i / TILES_PER_COLUMN
		var row := i % TILES_PER_COLUMN
		var x := 0.0 if column == 0 else SCREEN_W - BattleOpponentTile.SIZE_PX.x
		tile.position = Vector2(x, GRID_TOP + row * BattleOpponentTile.SIZE_PX.y)
		add_child(tile)
		tiles.append(tile)
	_status.position = Vector2(28, 226)
	_status.size = Vector2(200, 12)
	_style(_status, 8)
	_status.add_theme_color_override("font_shadow_color", Color.BLACK)
	_status.add_theme_constant_override("shadow_offset_x", 1)
	_status.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_status)
	_overlay.color = Color(0, 0, 0, 0.88)
	_overlay.size = Vector2(SCREEN_W, 240)
	_overlay.visible = false
	add_child(_overlay)
	_overlay_label.position = Vector2(24, 40)
	_overlay_label.size = Vector2(208, 160)
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style(_overlay_label, 8)
	_overlay.add_child(_overlay_label)

func _style(label: Label, font_size: int) -> void:
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", font_size)

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

## Re-reads the session into the labels and tiles.
func refresh() -> void:
	if session == null:
		return
	for i in tiles.size():
		tiles[i].update_from(session.contestants[i + 1])
	var p := session.get_player()
	var suffix := ""
	if BattleHandler.sim_speed() > 1:
		suffix = " x%d" % BattleHandler.sim_speed()
	_status.text = "T%03d ALIVE %d RANK %d/%d%s" % [
		maxi(p.time_left, 0), session.alive_count, session.get_provisional_rank(),
		BattleSession.CONTESTANT_COUNT, suffix]

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
	_status.visible = false

func result_dismissed() -> bool:
	return showing_result and (result_age >= BattleHandler.RESULT_MAX_SECONDS or (
		result_age >= BattleHandler.RESULT_MIN_SECONDS and Global.player_action_just_pressed("jump", 0)))
