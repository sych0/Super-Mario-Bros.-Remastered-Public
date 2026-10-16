class_name BattleScreen
extends Control
## The Battle screen (doc 38). While Battle is active this is the SceneTree's current scene and
## owns the root window: a 480x270 canvas with the Battle wallpaper, frame, opponent panes and
## badges, plus the real player's classic game running unchanged inside a 256x240 SubViewport
## (`GameViewport`) shown as the centre window. Classic code therefore sees a 256x240 viewport
## (camera walls, enemy activation, drop shadows...) exactly as in Classic modes; the Battle
## canvas only surrounds it. A view of the current BattleSession plus the host of the game
## scene and of the round lifecycle (BattleRound): READY, play, results, next round.
##
## Game scenes never go through change_scene_to_file while Battle runs: Global.transition_to_scene
## hands them to `load_game_scene`, which swaps the scene inside GameViewport and keeps this
## screen alive. A round ending (death, time out, a win) never leaves this screen: the next
## round reloads World 1-1 into the same GameViewport. Only Quit leaves Battle, as an ordinary
## transition to the title, which frees this screen and, with it, the game scene.
##
## The enemy send / receive loop is made visible here and only here (doc 44): `attack_view` reads the
## session's attack events into lines (`attack_layer`), markers on the opponent panes, the real player's
## incoming strip (`incoming_strip`, strip A) and, through the preview driver's tracks, incoming enemies
## in the opponents' pictures. It never writes to the session; nothing of it reaches the game window.

const TITLE_SCENE := "res://Scenes/Levels/TitleScreen.tscn"
const FONT_PATH := "res://Resources/ThemedResources/FontMain.tres"
const WALLPAPER := Color(0.97, 0.70, 0.14, 1) # reference's gold background
const FRAME_EDGE := Color(0.93, 0.55, 0.08, 1)
const FRAME_FILL := Color(0.99, 0.82, 0.33, 1)
const STRIP_A_COLOR := Color(0.98, 0.62, 0.12, 1)
const STRIP_B_COLOR := Color(0.99, 0.80, 0.30, 1)
const BADGE_FILL := Color(0.99, 0.97, 0.9, 1)
const BADGE_EDGE := Color(0.4, 0.22, 0.1, 1)
const BADGE_TEXT := Color(0.25, 0.14, 0.06, 1)
const OVERLAY_LAYER := 90
const FREEZE_DELAY_FRAMES := 3 ## frames a fresh level runs before the pre-round freezes it (camera and Mario settle)
const MAX_PRESENTATION_STEP := 0.1 ## a long frame (a hitch, a stalled window) advances the attack lines by at most this
## PROVISIONAL (doc 47 question Q5, the controller mapping of the targeting selector, is open; this is not the
## shipping control scheme and has no gamepad binding): the four keys of an IJKL cross select the player's
## targeting mode, laid out like SMB35's selector cross (up Lowest Time, left Random, right Most Coins, down
## Attackers). They are read here, never through the game's InputMap, so no setting or other mode is touched.
const PROVISIONAL_MODE_KEYS := {
	KEY_I: BattleTargeting.Mode.LOWEST_TIME,
	KEY_J: BattleTargeting.Mode.RANDOM,
	KEY_L: BattleTargeting.Mode.MOST_COINS,
	KEY_K: BattleTargeting.Mode.ATTACKERS,
}
const MODE_NOTE_SECONDS := 2.5 ## how long "NOT AVAILABLE YET" replaces the mode readout

## Emitted once a game scene (LevelTransition, a level, ...) has been added to GameViewport.
signal game_scene_changed(scene: Node)

static var instance: BattleScreen = null
## Dev/test switch: false keeps every window on the placeholder (previews off).
static var live_previews := true
## Where "the player confirmed" comes from. Empty = the real input (jump or accept); tests replace it.
static var confirm_source := Callable()

var session: BattleSession = null # the session being displayed (kept alive for the result)
var layout := {}
var game_container: SubViewportContainer = null ## the centre window on the canvas
var game_viewport: SubViewport = null ## the classic 256x240 game
var game_scene: Node = null ## whatever currently runs inside GameViewport
var atlas: BattlePreviewAtlas = null ## the one shared render target holding all 34 preview cells
var cells: Array[BattlePreviewCell] = [] ## 187x240 pictures, in the atlas (index = contestant id - 1)
var panes: Array[BattleOpponentPane] = [] ## 32x41 windows on the canvas, each showing its own atlas region
var driver: BattlePreviewDriver = null ## drives the live previews (all 34 on World 1-1)
var attack_view: BattleAttackPresentation = null ## the visible side of this session's attack loop (a reader of its events; null when attacks are off)
var attack_layer: BattleAttackLayer = null ## the lines and target marks over the canvas
var incoming_strip: BattleIncomingStrip = null ## the real player's incoming enemies, in strip A
var target_reticle: BattleTargetReticle = null ## the red bracket on the real player's current target pane
var debug_view: TextureRect = null ## dev only: opponent #1's atlas cell at native size over the window
var audio_listener: AudioListener2D = null
var battle_round := BattleRound.new() ## the round lifecycle; the same object for every round of this Battle
var game_frozen := false ## the game window is frozen for the pre-round (or a win)
var result_text := ""
var round_others_alive := 0 ## opponents still in when the round ended
var _font: Font = null
var _time_label := Label.new()
var _rank_label := Label.new()
var _alive_label := Label.new() # alive count in the right badge, over "/35"
var _course_label := Label.new() # "W-L" in the left badge
var _total_label := Label.new()
var _overlay_layer := CanvasLayer.new()
var _overlay := ColorRect.new()
var _overlay_label := Label.new()
var _banner := Label.new() ## "READY" / "GO!" over the window
var _saved_window := {}
var _window_owned := false
var _applied_visuals := -1
var _freeze_stretch := TextureRect.STRETCH_SCALE
var _warned_root_camera := false
var _attack_session: BattleSession = null ## the session the attack presentation was last set up for
var _target_label := Label.new() ## PROVISIONAL readout of the player's targeting mode, in strip B
var _mode_note := "" ## a short message that replaces the readout (a mode that is not available)
var _mode_note_until := 0 ## Time.get_ticks_msec() until which it shows

# ---- static API used by the rest of the game -------------------------------------------------

## True while a Battle screen is the current scene.
static func is_active() -> bool:
	return is_instance_valid(instance) and instance.is_inside_tree() and not instance.is_queued_for_deletion()

## True while the Battle screen owns the root window's canvas settings. Level resolution code
## must leave them alone then.
static func owns_window() -> bool:
	return is_active() and instance._window_owned

## The classic game's viewport during Battle, otherwise null.
static func get_game_viewport() -> SubViewport:
	return instance.game_viewport if is_active() else null

## Where the game window sits on the canvas.
static func game_rect() -> Rect2:
	return BattleHudLayout.GAME_RECT

## True when `scene_path` is a game scene that belongs inside the Battle screen: Battle is the
## game mode, a session exists, and the scene is not the title (which ends Battle).
static func routes(scene_path) -> bool:
	return scene_path is String and scene_path != TITLE_SCENE \
		and Global.current_game_mode == Global.GameMode.BATTLE and BattleSession.current != null

## Puts `scene_path` into GameViewport. The first call (from the title) creates the Battle
## screen as the current scene; every later call keeps it and only swaps the game scene.
static func load_game_scene(scene_path: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if not is_active():
		tree.change_scene_to_node(BattleScreen.new())
		await tree.scene_changed
	await instance.replace_game_scene(scene_path)

## Called by Global.transition_to_scene when it leaves Battle, before the fade starts, so that
## fade covers the whole screen instead of only the game window.
static func release_transition() -> void:
	if is_active():
		instance._release_transition()

# ---- lifecycle ---------------------------------------------------------------------------------

## True while the result card is up.
var showing_result: bool:
	get: return battle_round.state == BattleRound.State.RESULTS

func _init() -> void:
	name = "BattleScreen"
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2.ZERO
	size = BattleHudLayout.CANVAS
	battle_round.state_changed.connect(_on_round_state_changed)
	battle_round.begin_round() # round 1: LOADING until the first level is in the window

func _enter_tree() -> void:
	instance = self
	_capture_window()
	_apply_canvas()
	_window_owned = true

func _ready() -> void:
	if ResourceLoader.exists(FONT_PATH):
		_font = load(FONT_PATH)
	_build(BattleHudLayout.compute())
	session = BattleSession.current
	_capture_global_ui()

func _exit_tree() -> void:
	if instance == self:
		instance = null
	if game_frozen:
		Global.can_time_tick = true # never leave the Battle clock stopped behind us
	_release_global_ui()
	_restore_window()
	_window_owned = false
	# Level-sized preview art is only needed while Battle is up.
	BattlePreviewAssets.clear_cache()
	BattleLevelSketch.clear_cache()
	BattleEnemyFactory.clear_cache()

# ---- window ownership (doc 38, 5.2) ----------------------------------------------------------

func _video_setting(key: String, fallback := 0) -> int:
	if Settings.file == null:
		return fallback
	return int(Settings.file.video.get(key, fallback))

func _stretch_for(scaling: int) -> int:
	return Window.CONTENT_SCALE_STRETCH_INTEGER if scaling == 0 else Window.CONTENT_SCALE_STRETCH_FRACTIONAL

## Remembers the user's window state so quitting Battle can hand it back exactly.
func _capture_window() -> void:
	var window := get_tree().root
	_saved_window = {
		"size": window.content_scale_size, "aspect": window.content_scale_aspect,
		"mode": window.content_scale_mode, "stretch": window.content_scale_stretch,
		"setting_size": _video_setting("size"), "setting_scaling": _video_setting("scaling"),
		"setting_visuals": _video_setting("visuals"),
	}

## The 480x270 Battle canvas: scaling setting picks integer / fractional, visuals picks pixel snapping.
func _apply_canvas() -> void:
	var window := get_tree().root
	window.content_scale_size = Vector2i(BattleHudLayout.CANVAS)
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_stretch = _stretch_for(_video_setting("scaling")) as Window.ContentScaleStretch
	_applied_visuals = _video_setting("visuals")
	RenderingServer.viewport_set_snap_2d_transforms_to_pixel(window.get_viewport_rid(), _applied_visuals == 0)

## Hands the window back. If the user changed the size / scaling / visuals settings from the Battle
## pause menu, the new values apply by the same rules as WindowChanger and Level.reset_resolution.
func _restore_window() -> void:
	var tree := get_tree()
	if tree == null or _saved_window.is_empty():
		return
	var window := tree.root
	var changed: bool = _video_setting("size") != _saved_window.setting_size \
		or _video_setting("scaling") != _saved_window.setting_scaling \
		or _video_setting("visuals") != _saved_window.setting_visuals
	if changed:
		var idx := _video_setting("size")
		window.content_scale_size = Vector2i(Global.RESOLUTIONS[idx])
		window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND if idx == Global.RESOLUTIONS.size() - 1 else Window.CONTENT_SCALE_ASPECT_KEEP
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT if _video_setting("visuals") == 0 else Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		window.content_scale_stretch = _stretch_for(_video_setting("scaling")) as Window.ContentScaleStretch
	else:
		window.content_scale_size = _saved_window.size
		window.content_scale_aspect = _saved_window.aspect
		window.content_scale_mode = _saved_window.mode
		window.content_scale_stretch = _saved_window.stretch
	RenderingServer.viewport_set_snap_2d_transforms_to_pixel(window.get_viewport_rid(), _video_setting("visuals") == 0)

## Something (e.g. the pause menu's settings) moved the root away from the Battle canvas.
func _keep_window() -> void:
	var window := get_tree().root
	if window.content_scale_size != Vector2i(BattleHudLayout.CANVAS) \
			or window.content_scale_aspect != Window.CONTENT_SCALE_ASPECT_KEEP \
			or window.content_scale_mode != Window.CONTENT_SCALE_MODE_CANVAS_ITEMS \
			or window.content_scale_stretch != _stretch_for(_video_setting("scaling")) \
			or _applied_visuals != _video_setting("visuals"):
		_apply_canvas()

# ---- global UI that lives outside the scene (doc 38, 5.3) --------------------------------------

func _capture_global_ui() -> void:
	var hud := Global.get_node_or_null("GameHUD") as CanvasLayer
	if hud != null:
		hud.offset = Vector2(0, game_rect().position.y) # CENTER_TOP then lands on the window
	var transition := Global.get_node_or_null("Transition") as CanvasLayer
	if transition != null:
		# The fade covers the game window only, not the whole Battle canvas.
		transition.custom_viewport = game_viewport
		var freeze := transition.get_node("Freeze") as TextureRect
		_freeze_stretch = freeze.stretch_mode
		freeze.stretch_mode = TextureRect.STRETCH_KEEP # the frozen picture is 256x240, shown 1:1

## Sends the fade back to the root. (Godot 4.6 rejects `custom_viewport = null` with an error and
## keeps the old value, so the root window itself is the way to say "the default viewport".)
func _release_transition() -> void:
	var transition := Global.get_node_or_null("Transition") as CanvasLayer
	if transition != null and transition.custom_viewport == game_viewport:
		transition.custom_viewport = get_tree().root
		(transition.get_node("Freeze") as TextureRect).stretch_mode = _freeze_stretch as TextureRect.StretchMode

func _release_global_ui() -> void:
	_release_transition()
	var hud := Global.get_node_or_null("GameHUD") as CanvasLayer
	if hud != null:
		hud.offset = Vector2.ZERO

# ---- scene routing -----------------------------------------------------------------------------

## Replaces whatever runs inside GameViewport. The old scene leaves the tree first, like
## change_scene does, so its exit handlers run before the new scene's enter handlers.
func replace_game_scene(scene_path: String) -> void:
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_error("BattleScreen: cannot load game scene " + scene_path)
		return
	if is_instance_valid(game_scene):
		game_viewport.remove_child(game_scene)
		game_scene.queue_free()
	game_scene = packed.instantiate()
	game_viewport.add_child(game_scene)
	game_scene_changed.emit(game_scene)
	if battle_round.state == BattleRound.State.LOADING and game_scene is Level:
		_arm_pre_round(game_scene) # a round's first level (not LevelTransition, not 1-1 -> 1-2)

## The pre-round starts a few frames after World 1-1 is in the window, so its camera and Mario have
## settled on the level's start instead of the first frame's defaults.
func _arm_pre_round(scene: Node) -> void:
	for i in FREEZE_DELAY_FRAMES:
		await get_tree().process_frame
	if is_instance_valid(scene) and scene == game_scene and battle_round.state == BattleRound.State.LOADING:
		battle_round.level_ready()

# ---- building ----------------------------------------------------------------------------------

func _build(l: Dictionary) -> void:
	layout = l
	_rect(self, Rect2(Vector2.ZERO, l.canvas), WALLPAPER).name = "Wallpaper"
	var frame := _rect(self, l.frame, FRAME_EDGE)
	frame.name = "Frame"
	_rect(frame, Rect2(Vector2(2, 2), frame.size - Vector2(4, 4)), FRAME_FILL)
	_rect(self, l.strip_a, STRIP_A_COLOR).name = "StripA"
	_rect(self, l.strip_b, STRIP_B_COLOR).name = "StripB"
	var strip_rect: Rect2 = l.strip_a
	incoming_strip = BattleIncomingStrip.new(_font)
	incoming_strip.position = strip_rect.position
	incoming_strip.size = strip_rect.size
	add_child(incoming_strip) # the real player's incoming enemies, drawn over strip A
	_build_game_window(l.game)
	_build_previews(l)
	_place(_time_label, l.status_left, 0.75)
	_place(_rank_label, l.status_right, 0.75)
	_time_label.add_theme_color_override("font_color", BADGE_TEXT)
	_rank_label.add_theme_color_override("font_color", BADGE_TEXT)
	var badge_l: Rect2 = l.badge_left
	var badge_r: Rect2 = l.badge_right
	_add_badge(badge_l, "BadgeCourse")
	_add_badge(badge_r, "BadgeAlive")
	# Course "W-L" sits low in the left badge (the reference's "COURSE" caption does not fit 32 px).
	_place(_course_label, Rect2(badge_l.position + Vector2(2, badge_l.size.y - 14), Vector2(badge_l.size.x, 12)), 0.85)
	# Small Mario head icon above the alive count.
	_rect(self, Rect2(badge_r.position + Vector2(badge_r.size.x / 2.0 - 4, 3), Vector2(8, 8)), Color(0.85, 0.15, 0.1))
	# Alive count over a fixed "/35" (the reference's "35/35", stacked to fit the narrow badge).
	_place(_alive_label, Rect2(badge_r.position + Vector2(2, badge_r.size.y - 27), Vector2(badge_r.size.x, 12)), 0.85)
	_place(_total_label, Rect2(badge_r.position + Vector2(2, badge_r.size.y - 14), Vector2(badge_r.size.x, 12)), 0.85)
	_total_label.text = "/%d" % BattleSession.CONTESTANT_COUNT
	for label in [_course_label, _alive_label, _total_label]:
		label.add_theme_color_override("font_color", BADGE_TEXT)
	# The target reticle sits over the panes and under the attack lines.
	target_reticle = BattleTargetReticle.new(l)
	add_child(target_reticle)
	# PROVISIONAL readout of the targeting mode and its keys, in strip B (plain gold until coins and items).
	_place(_target_label, l.strip_b, 0.6)
	_target_label.add_theme_color_override("font_color", BADGE_TEXT)
	_target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_label.name = "TargetModeReadout"
	# The attack lines fly over everything on the canvas (the results and banner sit on a higher layer).
	attack_layer = BattleAttackLayer.new(l)
	add_child(attack_layer)
	# Results sit on a high layer so they cover the game window and its HUD.
	_overlay_layer.name = "Overlays"
	_overlay_layer.layer = OVERLAY_LAYER
	add_child(_overlay_layer)
	var game: Rect2 = l.game
	_overlay.color = Color(0, 0, 0, 0.88)
	_overlay.position = game.position
	_overlay.size = game.size
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	_overlay_layer.add_child(_overlay)
	_overlay_label.position = Vector2(24, 40)
	_overlay_label.size = Vector2(game.size.x - 48, 160)
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style(_overlay_label)
	_overlay.add_child(_overlay_label)
	# READY / GO! sits in the middle of the game window.
	_banner.name = "Banner"
	_banner.position = game.position + Vector2(0, game.size.y / 2.0 - 16.0)
	_banner.size = Vector2(game.size.x / 2.0, 16.0)
	_banner.scale = Vector2(2, 2)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.visible = false
	_style(_banner)
	_banner.add_theme_color_override("font_color", Color.WHITE)
	_banner.add_theme_color_override("font_shadow_color", Color.BLACK)
	_banner.add_theme_constant_override("shadow_offset_x", 1)
	_banner.add_theme_constant_override("shadow_offset_y", 1)
	_overlay_layer.add_child(_banner)

## The classic game: a 256x240 SubViewport shown 1:1 (logical) with nearest filtering. Nothing
## in here ever sees the canvas size, so classic camera / physics / enemy code is unchanged.
func _build_game_window(game: Rect2) -> void:
	game_container = SubViewportContainer.new()
	game_container.name = "GameWindow"
	game_container.position = game.position
	game_container.size = game.size
	game_container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	game_viewport = SubViewport.new()
	game_viewport.name = "GameViewport"
	game_viewport.size = Vector2i(BattleHudLayout.GAME_SIZE)
	game_viewport.audio_listener_enable_2d = true
	game_viewport.snap_2d_transforms_to_pixel = true # the game window is always pixel-perfect
	game_viewport.process_mode = Node.PROCESS_MODE_PAUSABLE # this screen is ALWAYS; the game still pauses
	game_container.add_child(game_viewport)
	add_child(game_container)
	# The root's own 2D sounds (AudioManager's players live in the root world, at level
	# coordinates) are heard from the game camera, not from the middle of the canvas.
	audio_listener = AudioListener2D.new()
	audio_listener.name = "AudioListener"
	add_child(audio_listener)
	audio_listener.make_current()

## The previews (doc 38, section 6): one atlas SubViewport holding 34 full-resolution cells, and 34
## canvas panes that each show their own region of it, smoothly downsampled.
func _build_previews(l: Dictionary) -> void:
	atlas = BattlePreviewAtlas.new()
	add_child(atlas)
	var atlas_texture := atlas.get_texture()
	for i in BattleHudLayout.OPPONENTS:
		var cell := BattlePreviewCell.new(i + 1)
		var region := BattlePreviewAtlas.cell_rect(i)
		cell.position = Vector2(region.position)
		atlas.add_child(cell)
		cells.append(cell)
		var pane := BattleOpponentPane.new(i + 1, _font)
		var rect: Rect2 = l.slots[i]
		pane.position = rect.position
		pane.size = rect.size
		pane.bind(atlas_texture, region, cell)
		add_child(pane)
		panes.append(pane)

func _rect(parent: Node, r: Rect2, color: Color) -> ColorRect:
	var node := ColorRect.new()
	node.position = r.position
	node.size = r.size
	node.color = color
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(node)
	return node

func _add_badge(r: Rect2, badge_name: String) -> void:
	var edge := _rect(self, r, BADGE_EDGE)
	edge.name = badge_name
	_rect(edge, Rect2(Vector2(1, 1), r.size - Vector2(2, 2)), BADGE_FILL)

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

# ---- per frame ---------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_keep_window()
	_follow_game_camera()
	if OS.is_debug_build() and not _warned_root_camera and get_viewport().get_camera_2d() != null:
		_warned_root_camera = true
		push_warning("BattleScreen: a Camera2D became current in the root viewport; the game camera belongs in GameViewport")
	battle_round.paused = Global.game_paused # the pause menu holds the pre-round and the results
	battle_round.update(delta, _confirm_pressed() if battle_round.state == BattleRound.State.RESULTS else false)
	_banner.text = battle_round.banner_text()
	_banner.visible = _banner.text != ""
	if BattleSession.current == null:
		return # between Quit and the scene change to the title
	session = BattleSession.current
	# Last one standing: the Battle clock only runs inside a level, but the win is seen from here.
	if battle_round.state == BattleRound.State.PLAYING and session.finished and session.get_player().alive:
		round_over(BattleRound.End.WIN)
	_ensure_driver()
	_ensure_attack_view()
	if attack_view != null:
		# Presentation time runs only while the game does (doc 45 section 14): the pause menu, a death or
		# power-up freeze (tree paused), the pre-round and a win hold (window frozen) hold the lines too.
		attack_view.update(0.0 if presentation_held() else minf(delta, MAX_PRESENTATION_STEP))
	refresh()
	if driver != null:
		for id in driver.update(BattleHandler.presentation_alpha):
			cells[id - 1].queue_redraw()

func _confirm_pressed() -> bool:
	if confirm_source.is_valid():
		return confirm_source.call()
	return Global.multibind_action_just_pressed("ui_accept") or Global.player_action_just_pressed("jump", 0)

func _follow_game_camera() -> void:
	var camera := game_viewport.get_camera_2d()
	if camera != null:
		audio_listener.global_position = camera.get_screen_center_position()

## Creates the preview driver for the current session (once). All 34 opponents get a track and
## draw live while they are on World 1-1; a cell falls back to the placeholder on its own whenever
## its frame is not valid (another course, or the run is over). If the level or its art can't be
## built, nothing live is shown and every cell keeps the placeholder.
func _ensure_driver() -> void:
	if session == null or not live_previews or (driver != null and driver.session == session):
		return
	driver = null
	for cell in cells:
		cell.set_live(null, null) # nothing of a previous session's pictures may linger
	var ids: Array = range(1, BattleHudLayout.OPPONENTS + 1)
	driver = BattlePreviewDriver.create(session, ids, float(BattlePreviewAtlas.CELL_PX.x))
	if driver == null:
		return
	for id in driver.tracks:
		cells[id - 1].set_live(BattleMiniGameRenderer.new(), driver.tracks[id].frame)
	if BattlePreviewDriver.debug_full_view() and debug_view == null:
		# The same atlas region the pane samples, at its native size: no second render.
		var region := BattlePreviewAtlas.cell_rect(0)
		var tex := AtlasTexture.new()
		tex.atlas = atlas.get_texture()
		tex.region = Rect2(region)
		debug_view = TextureRect.new()
		debug_view.name = "DebugCell1"
		debug_view.texture = tex
		debug_view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		debug_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var game: Rect2 = layout.game
		debug_view.size = Vector2(region.size)
		debug_view.position = game.position + Vector2(floorf((game.size.x - debug_view.size.x) / 2.0), 0)
		_overlay_layer.add_child(debug_view)

## Makes (once per session) the presentation that turns the session's attack events into lines, markers
## and the incoming strip. It only reads the session. With the attack loop off there is nothing to show
## and no presentation exists (Classic never gets here at all: this screen is Battle's).
func _ensure_attack_view() -> void:
	if session == null or session == _attack_session:
		return
	_attack_session = session
	_clear_attack_view()
	if session.attacks.enabled:
		attack_view = BattleAttackPresentation.new(session)
		_bind_attack_view()

func _bind_attack_view() -> void:
	var art: BattlePreviewAssets = driver.assets if driver != null else null
	attack_layer.bind(attack_view, art)
	incoming_strip.bind(attack_view, art)

## Everything the attack presentation put on screen goes: lines, marks, pane markers, strip icons.
func _clear_attack_view() -> void:
	attack_view = null
	target_reticle.set_target(0)
	_target_label.text = ""
	attack_layer.bind(null, null)
	incoming_strip.bind(null, null)
	for pane in panes:
		pane.set_incoming(Vector2i.ZERO)

## Re-reads the session into the cells, panes and labels.
func refresh() -> void:
	if session == null:
		return
	for i in cells.size():
		cells[i].refresh(session.contestants[i + 1])
		panes[i].refresh(session.contestants[i + 1])
		if attack_view != null:
			panes[i].set_incoming(attack_view.counts(i + 1))
	if attack_view != null:
		var art: BattlePreviewAssets = driver.assets if driver != null else null
		attack_layer.assets = art
		incoming_strip.assets = art
	attack_layer.sync()
	incoming_strip.sync()
	target_reticle.set_target(_reticle_target())
	_refresh_target_readout()
	var p := session.get_player()
	var speed := "" if BattleHandler.sim_speed() == 1 else " X%d" % BattleHandler.sim_speed()
	_time_label.text = "TIME %03d%s" % [maxi(p.time_left, 0), speed]
	_rank_label.text = "RANK %d/%d" % [session.get_provisional_rank(), BattleSession.CONTESTANT_COUNT]
	_alive_label.text = "%d" % session.alive_count
	_course_label.text = "%d-%d" % [session.world, session.level]

# ---- round lifecycle (doc 38, section 7) -----------------------------------------------------------

# ---- the player's target: reticle, mode selection (doc 47 M-T1) -------------------------------------

## The opponent the reticle is on right now (1..34), or 0 for none: only while the round is being set up
## or played, two or more are in, the player is in, and never on a pane that already shows its KO card.
func _reticle_target() -> int:
	if attack_view == null or session == null:
		return 0
	var state := battle_round.state
	if state != BattleRound.State.PRE_ROUND and state != BattleRound.State.PLAYING:
		return 0
	if session.alive_count < 2 or not session.get_player().alive:
		return 0
	var t := attack_view.player_target
	if t < 1 or t > BattleHudLayout.OPPONENTS or not session.contestants[t].alive or panes[t - 1].ko:
		return 0
	return t

## PROVISIONAL: the current mode and its keys, in strip B. A note (a mode that is not available) replaces it
## for a moment. Written only when the text changes.
func _refresh_target_readout() -> void:
	var text := ""
	if attack_view != null and session != null:
		if _mode_note != "" and Time.get_ticks_msec() < _mode_note_until:
			text = _mode_note
		else:
			_mode_note = ""
			text = "TARGET: %s   [I J K L: MODE, PROVISIONAL]" % BattleTargeting.mode_name(session.player_target_mode).replace("_", " ")
	if text != _target_label.text:
		_target_label.text = text

## Selects the real player's targeting mode (BattleTargeting.Mode). Only while the round is set up or being
## played and the game is not paused. Returns whether the session accepted it; a mode that is not available
## (Most Coins, until coin data exists) leaves the mode alone and says so in the readout.
func select_target_mode(mode: int) -> bool:
	var session_now := BattleSession.current
	if session_now == null or get_tree().paused or Global.game_paused:
		return false
	var state := battle_round.state
	if state != BattleRound.State.PRE_ROUND and state != BattleRound.State.PLAYING:
		return false
	if session_now.set_player_target_mode(mode):
		_mode_note = ""
		return true
	if not session_now.target_mode_available(mode):
		_mode_note = "%s: NOT AVAILABLE YET" % BattleTargeting.mode_name(mode).replace("_", " ")
		_mode_note_until = Time.get_ticks_msec() + int(MODE_NOTE_SECONDS * 1000.0)
	return false

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and PROVISIONAL_MODE_KEYS.has((event as InputEventKey).physical_keycode):
		select_target_mode(PROVISIONAL_MODE_KEYS[(event as InputEventKey).physical_keycode])

## Whether the attack presentation clock is held: exactly when the Battle clock is (the tree is paused
## or the game window is frozen), since BattleHandler, which drives that clock, is pausable inside it.
func presentation_held() -> bool:
	return get_tree().paused or game_frozen

## The round has ended (called by BattleHandler.on_player_died for a death or a time out, and by
## _process for a win). Ignored unless the round is being played, so it can only happen once.
func round_over(cause: int) -> void:
	battle_round.end_round(cause)

## The player's death animation and music are over: the results may come up.
func death_finished() -> void:
	battle_round.death_finished()

## Everything that follows from a round state change: freezing and releasing the game window, the
## results card, the next round. All of it is presentation or a call into the one shared start path.
func _on_round_state_changed(from: int, to: int) -> void:
	match to:
		BattleRound.State.PRE_ROUND:
			_set_game_frozen(true)
		BattleRound.State.PLAYING:
			_set_game_frozen(false)
		BattleRound.State.ROUND_OVER:
			_begin_round_over()
		BattleRound.State.RESULTS:
			_show_results()
		BattleRound.State.LOADING:
			if from == BattleRound.State.RESULTS:
				_start_next_round()

## Freezes (or releases) the game window: gameplay stops, and so does the Battle clock, which is
## driven by BattleHandler inside the level. The real game's HUD timer stops with it.
func _set_game_frozen(frozen: bool) -> void:
	game_frozen = frozen
	game_viewport.process_mode = Node.PROCESS_MODE_DISABLED if frozen else Node.PROCESS_MODE_PAUSABLE
	Global.can_time_tick = not frozen

func _begin_round_over() -> void:
	var s := BattleSession.current
	if s != null:
		round_others_alive = s.alive_count - (1 if s.get_player().alive else 0)
	if battle_round.end_cause == BattleRound.End.WIN:
		_set_game_frozen(true) # nothing plays out after a win: hold the picture

## Finishes the match behind the results: the rest of the placements are decided now (the bots play
## it out), so the results show a complete ranking. The player's own placement was fixed at their KO.
func _show_results() -> void:
	var s := BattleSession.current
	if s == null:
		return
	s.resolve_to_end()
	print(s.describe_result())
	AudioManager.stop_all_music()
	Global.death_load = false
	show_result(s, round_others_alive)

## The results were dismissed: a fresh round through the shared start path (a new session and seed,
## World 1-1 loaded into this same game window). The title is never involved.
func _start_next_round() -> void:
	_hide_result()
	_set_game_frozen(false)
	for cell in cells:
		cell.set_live(null, null) # the new session gets its own tracks
	driver = null
	_clear_attack_view() # no line, marker or strip icon of the finished round survives
	BattleHandler.start_match()

## Builds and shows the result card for `final_session`. `others_alive` is how many opponents
## were still in when the round ended. A view only: the state machine decides when it shows.
func show_result(final_session: BattleSession, others_alive: int) -> void:
	session = final_session
	refresh()
	var p := final_session.get_player()
	var lines: Array[String] = ["ROUND %d OVER" % battle_round.round_number, ""]
	if final_session.winner_id == BattleSession.PLAYER_ID:
		lines.append("YOU WON!")
	else:
		lines.append("YOU PLACED %d / %d" % [p.placement, BattleSession.CONTESTANT_COUNT])
		lines.append("OUT BY: " + BattleSession.KoCause.keys()[p.ko_cause])
	lines.append("OPPONENTS LEFT: %d" % others_alive)
	lines.append("LEVELS CLEARED: %d" % p.levels_cleared)
	lines.append("")
	if final_session.winner_id == BattleSession.PLAYER_ID:
		lines.append("WINNER: YOU")
	else:
		lines.append("WINNER: #%02d" % final_session.winner_id)
	lines.append("")
	lines.append("PRESS JUMP FOR NEXT ROUND")
	result_text = "\n".join(lines)
	_overlay_label.text = result_text
	_overlay.visible = true

func _hide_result() -> void:
	_overlay.visible = false
	result_text = ""
