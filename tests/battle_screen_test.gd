extends SceneTree
## Composition, routing and window-ownership checks for the Battle screen (doc 38, milestone 1),
## run against the real project: the real Level / LevelTransition / PipeCutscene scenes run inside
## BattleScreen's GameViewport, and Mario is moved with the real input actions. Needs the imported
## project (autoloads + scenes). Run (every frame is one 1/60 s step, so it is deterministic):
##   godot --headless --fixed-fps 60 --path . -s tests/battle_screen_test.gd
## A headless run has no renderer, so VisibleOnScreen*, pixel and screenshot checks live in
## tests/battle_screen_render_test.gd.
##
## Script classes that mention autoloads are only reached through load(), because a `-s` script is
## compiled before the autoloads exist.

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const LEVEL_1_2 := "res://Scenes/Levels/SMB1/World1/1-2.tscn"
const TITLE := "res://Scenes/Levels/TitleScreen.tscn"

var failures := 0
var G
var S
var BS
var HANDLER
var SESSION
var LAYOUT
var scene_changes := 0

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

func frames(n: int) -> void:
	for i in n:
		await process_frame

func wait_until(cond: Callable, max_frames := 900) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await process_frame
	return cond.call()

func player() -> Node2D:
	return get_first_node_in_group("Players") as Node2D

func screen() -> Control:
	return BS.instance

## Battle is up with the real level loaded inside the game window and Mario in it.
func level_running(path := LEVEL_1_1) -> bool:
	return current_scene != null and current_scene.get_script() == BS and not G.transitioning_scene \
		and is_instance_valid(G.current_level) and G.current_level.scene_file_path == path \
		and G.current_level.get_parent() == current_scene.game_viewport and player() != null

## Everything about the window the user's settings own (nothing of it may leak out of Battle).
func window_state() -> Dictionary:
	var v: Dictionary = S.file.video
	return {
		"scale_size": root.content_scale_size, "aspect": root.content_scale_aspect, "mode": root.content_scale_mode,
		"stretch": root.content_scale_stretch, "window_size": root.size, "window_mode": root.mode,
		"video": [v.size, v.scaling, v.visuals, v.hud_size, v.mode],
		"fade_redirected": is_instance_valid(G.get_node("Transition").custom_viewport) and G.get_node("Transition").custom_viewport != root, "hud_offset": G.get_node("GameHUD").offset,
		"freeze_stretch": G.get_node("Transition/Freeze").stretch_mode,
	}

func video() -> Node:
	return S.get_node("Apply/Video") # the same node the settings menu drives

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = root.get_node("Settings")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	LAYOUT = load("res://Scripts/Classes/Battle/BattleHudLayout.gd")
	scene_changed.connect(func(): scene_changes += 1)
	# The game saves its settings file whenever the window changes (Battle changes the canvas), so the test
	# puts the file back byte for byte when it is done.
	var saved_video: Dictionary = S.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR)

	# The user's own window: 320x240, fractional scaling, pixel-perfect. Battle must give exactly this back.
	G.current_game_mode = G.GameMode.NONE
	video().set_value("size", 1)
	video().set_value("scaling", 1)
	video().set_value("visuals", 0)
	video().set_value("hud_size", 0)
	await frames(2)
	var before := window_state()
	check(not BS.is_active() and not BS.owns_window(), "no Battle screen outside Battle")
	check(G.get_game_viewport() == root, "outside Battle the game viewport is the root")

	await test_composition()
	await test_game_window_gameplay()
	await test_global_ui_and_pause()
	await test_root_vs_game_viewport()
	await test_routing_1_1_to_1_2()
	await test_window_ownership_and_quit(before)
	await test_setting_changed_during_battle()
	await test_classic_unaffected()

	for key in saved_video:
		S.file.video[key] = saved_video[key]
	var settings_out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle screen test(s) failed" % failures)
	else:
		print("All Battle screen tests passed")
	quit(1 if failures > 0 else 0)

# ---- composition -------------------------------------------------------------------------------

func test_composition() -> void:
	print("-- composition")
	# Start from the real title screen as the current scene, and use what its Battle entry calls.
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	var on_title: bool = await wait_until(func(): return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene, 600)
	check(on_title, "the title screen is the current scene")
	var title := current_scene
	title.start_battle()
	var up: bool = await wait_until(func(): return level_running(), 1500)
	check(up, "Battle starts from the title and 1-1 is running")
	check(not is_instance_valid(title) or title.is_queued_for_deletion(), "the title screen was replaced by the Battle screen")
	await frames(60)
	var scr = screen()
	check(scr != null and current_scene == scr, "current scene is the BattleScreen")
	check(scr.get_class() == "Control" and scr.size == Vector2(480, 270), "BattleScreen is a 480x270 Control (%s)" % scr.size)
	check(root.content_scale_size == Vector2i(480, 270), "root content scale is the 480x270 Battle canvas (%s)" % root.content_scale_size)
	check(root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP, "canvas keeps its 16:9 aspect")
	check(root.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS, "canvas renders at display resolution (CANVAS_ITEMS)")
	check(root.content_scale_stretch == Window.CONTENT_SCALE_STRETCH_FRACTIONAL, "canvas follows the user's scaling setting (fractional)")
	check(BS.owns_window() and BS.is_active(), "BattleScreen owns the window")
	check(G.current_level.get_parent() == scr.game_viewport, "1-1 runs inside GameViewport")
	check(scr.game_viewport.get_parent() == scr.game_container and scr.game_container.get_parent() == scr, "GameViewport is shown by the centre window container")
	check(scr.game_viewport.size == Vector2i(256, 240), "GameViewport is exactly 256x240 (%s)" % scr.game_viewport.size)
	check(scr.game_viewport.get_visible_rect().size == Vector2(256, 240), "GameViewport's visible rect is 256x240")
	check(G.current_level.get_viewport() == scr.game_viewport, "the level's viewport is GameViewport")
	check(G.current_level.get_viewport().get_visible_rect().size == Vector2(256, 240), "the level sees a 256x240 viewport, not 480x270")
	check(player().get_viewport() == scr.game_viewport and player().get_viewport_rect().size == Vector2(256, 240), "Mario sees a 256x240 viewport")
	check(scr.game_container.position == Vector2(112, 3) and scr.game_container.size == Vector2(256, 240), "window sits at (112, 3) at 1:1 (%s %s)" % [scr.game_container.position, scr.game_container.size])
	check(scr.game_container.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "window is upscaled with nearest filtering")
	check(root.get_camera_2d() == null, "no current Camera2D in the Battle root viewport")
	check(scr.game_viewport.get_camera_2d() != null, "the game camera is current in GameViewport")
	check(scr.game_viewport.process_mode == Node.PROCESS_MODE_PAUSABLE and scr.process_mode == Node.PROCESS_MODE_ALWAYS, "GameViewport is pausable, BattleScreen is not")
	# The wallpaper is the bottom layer and the window is drawn above it (never the other way round).
	var order := {}
	for i in scr.get_child_count():
		order[scr.get_child(i).name] = i
	check(order.has("Wallpaper") and order.has("GameWindow") and order.Wallpaper < order.Frame and order.Frame < order.GameWindow, "wallpaper and frame are drawn behind the game window")
	var wallpaper: ColorRect = scr.get_node("Wallpaper")
	check(wallpaper.get_rect() == Rect2(0, 0, 480, 270) and wallpaper.color == BS.WALLPAPER, "wallpaper is the gold background of the whole canvas")
	check(scr.surfaces.size() == 34, "34 opponent panes")
	var screen_rect := Rect2(Vector2.ZERO, Vector2(480, 270))
	var game_rect: Rect2 = scr.layout.game
	var clear := true
	for pane in scr.surfaces:
		var r := Rect2(pane.position, pane.size)
		if r.intersects(game_rect) or not screen_rect.encloses(r) or not pane.visible or pane.get_parent() != scr:
			clear = false
	check(clear, "every pane is on the canvas and outside the game window")
	check(G.current_level.has_node("BattleHandler"), "the Battle handler runs inside the level in the window")
	# Classic camera walls, from the classic 256 viewport (the old 426-wide root put them at +-213).
	var joint: Node2D = player().camera_center_joint
	check(joint.get_node("LeftWall").position.x == -128.0 and joint.get_node("RightWall").position.x == 128.0, "camera walls are at +-128, as in Classic (%s / %s)" % [joint.get_node("LeftWall").position.x, joint.get_node("RightWall").position.x])
	# Status text still binds to the session.
	var session = SESSION.current
	check(scr._alive_label.text == str(session.alive_count) and scr._time_label.text.begins_with("TIME "), "status is bound to the session (%s | %s)" % [scr._alive_label.text, scr._time_label.text])
	# The audio listener of the root world follows the game camera (AudioManager's sounds live in the root).
	var cam: Camera2D = scr.game_viewport.get_camera_2d()
	check(scr.audio_listener != null and scr.audio_listener.global_position.is_equal_approx(cam.get_screen_center_position()), "root audio listener sits at the game camera (%s vs %s)" % [scr.audio_listener.global_position, cam.get_screen_center_position()])
	check(scr.game_viewport.audio_listener_enable_2d, "GameViewport has its own 2D audio listener")
	check(session != null and G.current_game_mode == G.GameMode.BATTLE, "Battle mode with a live session")

func test_game_window_gameplay() -> void:
	print("-- gameplay inside the game window")
	var scr = screen()
	var p := player()
	var cam: Camera2D = scr.game_viewport.get_camera_2d()
	var left_edge := func() -> float: return cam.get_screen_center_position().x - 128.0
	# Right wall: lock the camera at the level start, as a locked-camera section does, and run into
	# the wall over the clear stretch. The classic wall is 128 px from the camera centre; the old
	# 426-wide root put it at 213.
	var player_script = p.get_script()
	var saved_limit = player_script.camera_right_limit
	player_script.camera_right_limit = 0
	Input.action_press("move_right_0")
	Input.action_press("run_0")
	await frames(300)
	Input.action_release("move_right_0")
	Input.action_release("run_0")
	var wall_rel: float = p.global_position.x - left_edge.call()
	check(wall_rel > 200.0 and wall_rel <= 256.0, "Mario runs into the window's right wall (screen x %s of 256)" % wall_rel)
	check(scr.layout.game.position.x + wall_rel <= scr.layout.right.position.x, "Mario never reaches the right opponent panel (canvas x %s <= %s)" % [scr.layout.game.position.x + wall_rel, scr.layout.right.position.x])
	player_script.camera_right_limit = saved_limit # a real camera lock lets go while Mario is mid-screen
	p.global_position.x = cam.get_screen_center_position().x - 64.0
	await frames(10)
	# Run right so the camera scrolls, then push against the camera's left wall for a long time.
	Input.action_press("move_right_0")
	Input.action_press("run_0")
	await frames(240)
	Input.action_release("move_right_0")
	Input.action_release("run_0")
	var right_rel: float = p.global_position.x - left_edge.call()
	check(cam.get_screen_center_position().x > 100.0, "the camera scrolled while Mario ran right (%s)" % cam.get_screen_center_position().x)
	check(right_rel <= 256.0, "Mario stays inside the 256-wide window on the right (%s of 256)" % right_rel)
	Input.action_press("move_left_0")
	await frames(400)
	Input.action_release("move_left_0")
	var rel: float = p.global_position.x - left_edge.call()
	check(rel >= 0.0, "Mario cannot go left of the window (screen x %s)" % rel)
	check(rel <= 16.0, "Mario really is pinned at the window's left wall (screen x %s)" % rel)
	var canvas_x: float = scr.layout.game.position.x + rel
	check(canvas_x >= scr.layout.left.end.x, "Mario never reaches the left opponent panel (canvas x %s >= %s)" % [canvas_x, scr.layout.left.end.x])
	check(canvas_x + 16.0 <= scr.layout.right.position.x, "nor the right panel")

# ---- HUD, fades, pause -------------------------------------------------------------------------

func test_global_ui_and_pause() -> void:
	print("-- global UI, fades, pause")
	var scr = screen()
	var hud: CanvasLayer = G.get_node("GameHUD")
	var main: Control = hud.get_node("Main")
	var rect := Rect2(main.global_position + hud.offset, main.size)
	check(hud.offset == Vector2(0, 3), "GameHUD layer is moved down onto the window (%s)" % hud.offset)
	check(main.visible and scr.layout.game.encloses(rect), "GameHUD sits over the game window: %s inside %s" % [rect, scr.layout.game])
	check(is_equal_approx(rect.get_center().x, scr.layout.game.get_center().x), "GameHUD is centred on the window")
	check(hud.get_node("Main").anchor_left == 0.5 and hud.get_node("Main").anchor_right == 0.5, "HUD uses the centred (CENTER_TOP) layout in Battle")
	var transition: CanvasLayer = G.get_node("Transition")
	check(transition.custom_viewport == scr.game_viewport, "level fades are redirected into GameViewport")
	check(G.get_node("Transition/Freeze").stretch_mode == TextureRect.STRETCH_KEEP, "the frozen frame is shown 1:1 in the window")
	# Pause: the game freezes, the screen keeps running.
	var session = SESSION.current
	var p := player()
	var pos_before := p.global_position
	var ticks_before: int = session.tick_count
	var alpha_before: float = HANDLER.presentation_alpha
	paused = true
	Input.action_press("move_right_0")
	var result_age_before: float = scr.result_age
	await frames(60)
	Input.action_release("move_right_0")
	check(not scr.game_viewport.can_process() and scr.can_process(), "paused: the game window stops, the Battle screen does not")
	check(p.global_position == pos_before, "paused: Mario does not move")
	check(session.tick_count == ticks_before and HANDLER.presentation_alpha == alpha_before, "paused: the Battle clock and previews freeze")
	paused = false
	await frames(30)
	check(session.tick_count >= ticks_before, "unpaused: the Battle clock runs again")
	# The real pause entry (what the Pause button calls) opens the Battle pause menu and pauses.
	hud.activate_pause_menu()
	await frames(2)
	check(paused and hud.get_node("BattlePause").visible, "the real pause menu opens over the Battle screen and pauses")
	hud.get_node("BattlePause").close()
	await frames(5)
	check(not paused, "closing the pause menu resumes")

# ---- root-versus-game-viewport call sites --------------------------------------------------------

func test_root_vs_game_viewport() -> void:
	print("-- root vs game viewport")
	var scr = screen()
	var cam: Camera2D = scr.game_viewport.get_camera_2d()
	check(G.get_game_viewport() == scr.game_viewport, "Global.get_game_viewport() is GameViewport during Battle")
	# 1-up sound at 100 coins: used to dereference the root's missing camera.
	var lives_before: int = G.lives
	G.coins = 99
	G.coins = 100
	await frames(2)
	check(G.coins == 0 and G.lives == lives_before + 1, "reaching 100 coins during Battle gives the 1-up (lives %d -> %d)" % [lives_before, G.lives])
	var am: Node = root.get_node("AudioManager")
	check(am.active_sfxs.has("1_up"), "the 1-up sound is playing")
	var sfx_pos = am.active_sfxs["1_up"].global_position
	check(sfx_pos.is_equal_approx(cam.get_screen_center_position()), "1-up is heard at the game camera (%s vs %s)" % [sfx_pos, cam.get_screen_center_position()])
	am.play_global_sfx("coin")
	await frames(2)
	check(am.active_sfxs.has("coin") and am.active_sfxs["coin"].global_position.is_equal_approx(cam.get_screen_center_position()), "AudioManager.play_global_sfx works in Battle (it used to return silently)")
	# Screen shake moves the game camera.
	var shaker: Node = G.screen_shaker
	shaker.shake_screen(1.0, 0.5)
	var moved := false
	for i in 20:
		await physics_frame
		moved = moved or cam.offset.y != 0.0
	check(moved, "ScreenShaker shakes the game camera in Battle")
	await frames(40)
	# Drop shadows follow the game camera's world (they read the root's, which has no camera, before).
	S.file.video.drop_shadows = 1
	var shadows: Array = G.current_level.find_children("*", "Node2D", true, false).filter(func(n): return n.get_script() != null and n.get_script().resource_path.ends_with("DropShadowRenderer.gd"))
	check(shadows.size() > 0, "1-1 has a drop shadow renderer")
	await frames(10)
	if shadows.size() > 0:
		var sub: SubViewport = shadows[0].get_node("SubViewportContainer/SubViewport")
		check(sub.world_2d == cam.get_world_2d(), "drop shadows render the game camera's world")

# ---- routing: a real 1-1 -> 1-2 -------------------------------------------------------------------

func test_routing_1_1_to_1_2() -> void:
	print("-- routing 1-1 -> 1-2 (real flagpole, castle, level transition, pipe cutscene)")
	var scr = screen()
	var session = SESSION.current
	var seen: Array[String] = []
	var screens: Array = []
	var transition_done := [0]
	scr.game_scene_changed.connect(func(n: Node): seen.append(n.scene_file_path))
	G.transition_finished.connect(func(): transition_done[0] += 1)
	var changes_before := scene_changes
	var pole: Node2D = null
	for n in G.current_level.find_children("*", "Node2D", true, false):
		if n.get_script() != null and n.get_script().resource_path.ends_with("EndFlagpole.gd"):
			pole = n
	check(pole != null, "1-1 has its flagpole")
	# Drop Mario onto the flagpole base; the real FlagPole -> LevelExit -> EndCastle sequence does the rest.
	var p := player()
	p.global_position = Vector2(pole.global_position.x - 4, -110)
	Input.action_press("move_right_0")
	Input.action_press("run_0")
	var done: bool = await wait_until(func():
		if current_scene != null:
			screens.append(current_scene)
		return level_running(LEVEL_1_2), 3000)
	Input.action_release("move_right_0")
	Input.action_release("run_0")
	check(done, "1-2 is running after clearing 1-1")
	check(current_scene == scr and BS.instance == scr and screens.all(func(s): return s == scr), "the same BattleScreen stayed the current scene throughout")
	check(scene_changes == changes_before, "the SceneTree never changed scene during the transition")
	check(G.current_level.get_parent() == scr.game_viewport and G.current_level.get_viewport().get_visible_rect().size == Vector2(256, 240), "1-2 runs in the 256x240 GameViewport")
	check(seen.has("res://Scenes/Levels/LevelTransition.tscn") and seen.has(LEVEL_1_2), "LevelTransition and 1-2 were loaded into the game window (%s)" % str(seen))
	check(transition_done[0] >= 1, "Global emitted transition_finished")
	check(G.world_num == 1 and G.level_num == 2, "Global reports world 1-2")
	check(session == SESSION.current and session.get_player().levels_cleared >= 1, "the player's clear was reported to the same session")
	check(root.content_scale_size == Vector2i(480, 270) and root.get_camera_2d() == null, "loading levels did not touch the Battle canvas or the root camera")
	check(G.get_node("Transition").custom_viewport == scr.game_viewport, "fades are still confined to the window")
	check(G.get_node("Transition").visible == false and not G.transitioning_scene, "the fade has finished")
	check(scr.get_node("Wallpaper").get_index() < scr.game_container.get_index(), "wallpaper is still behind the window")
	await frames(30)

# ---- window ownership, settings drift, quit --------------------------------------------------------

func test_window_ownership_and_quit(before: Dictionary) -> void:
	print("-- window ownership and Quit")
	var scr = screen()
	# A level reload keeps the window (the Level code used to reset the root on every load / exit).
	var level = G.current_level
	level.apply_resolution_enforcement()
	level.reset_resolution()
	check(root.content_scale_size == Vector2i(480, 270) and root.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS, "Level resolution code does not overwrite the Battle canvas")
	# The settings menu (reachable from the Battle pause menu) changes the root; Battle takes it back at once.
	video().set_value("size", 2)
	check(root.content_scale_size == Vector2i(426, 240), "(a setting change drifts the root: %s)" % root.content_scale_size)
	await frames(2)
	check(root.content_scale_size == Vector2i(480, 270) and root.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS, "Battle re-applies its canvas after a size change")
	video().set_value("visuals", 1)
	await frames(2)
	check(root.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS and root.content_scale_size == Vector2i(480, 270), "Battle re-applies its canvas after a visuals change")
	video().set_value("visuals", 0)
	video().set_value("scaling", 0)
	await frames(2)
	check(root.content_scale_stretch == Window.CONTENT_SCALE_STRETCH_INTEGER, "the scaling setting picks integer stretch in Battle")
	# Put the user's settings back the way they were, then Quit like the pause menu does.
	video().set_value("size", 1)
	video().set_value("scaling", 1)
	await frames(2)
	HANDLER.quit_battle()
	paused = true # the pause menu pauses while it waits for the level to go
	var overlay: bool = await wait_until(func(): return scr.showing_result, 60)
	check(overlay, "Quit shows the match result over the window")
	check(scr._overlay.get_parent().layer == BS.OVERLAY_LAYER and scr._overlay.get_rect() == scr.layout.game, "the result covers the game window on the overlay layer")
	scr.result_age = HANDLER.RESULT_MAX_SECONDS
	var left: bool = await wait_until(func(): return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene, 1500)
	check(left, "Quit leaves Battle for the title")
	await frames(10)
	check(not BS.is_active() and BS.instance == null and not is_instance_valid(scr), "the BattleScreen is gone")
	check(SESSION.current == null and G.current_game_mode != G.GameMode.BATTLE, "no session and no Battle mode after Quit")
	var after := window_state()
	for key in before:
		check(after[key] == before[key], "Quit restores %s exactly (%s)" % [key, str(after[key])])

## A size picked in the Battle pause menu is re-applied over the canvas at once and takes effect
## when Battle ends (by the same rules as WindowChanger and Level.reset_resolution).
func test_setting_changed_during_battle() -> void:
	print("-- a setting changed during Battle")
	current_scene.start_battle() # still on the title after Quit
	var up: bool = await wait_until(func(): return level_running(), 1500)
	check(up, "second Battle starts")
	video().set_value("size", 2)
	video().set_value("scaling", 0)
	await frames(3)
	check(root.content_scale_size == Vector2i(480, 270) and root.content_scale_stretch == Window.CONTENT_SCALE_STRETCH_INTEGER, "the canvas stays 480x270 while a new size is chosen")
	HANDLER.quit_battle()
	await wait_until(func(): return screen().showing_result, 60)
	screen().result_age = HANDLER.RESULT_MAX_SECONDS
	var left: bool = await wait_until(func(): return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene, 1500)
	await frames(10)
	check(left and root.content_scale_size == Vector2i(426, 240) and root.content_scale_mode == Window.CONTENT_SCALE_MODE_VIEWPORT and root.content_scale_stretch == Window.CONTENT_SCALE_STRETCH_INTEGER, "after Battle the new setting applies (%s)" % root.content_scale_size)
	video().set_value("size", 1)
	video().set_value("scaling", 1)

# ---- Classic -------------------------------------------------------------------------------------

func test_classic_unaffected() -> void:
	print("-- Classic modes")
	G.current_campaign = "SMB1"
	G.current_game_mode = G.GameMode.CAMPAIGN
	G.clear_saved_values()
	G.world_num = 1
	G.level_num = 1
	G.reset_values()
	var LV = load("res://Scripts/Classes/LevelClass.gd")
	LV.first_load = true
	G.transition_to_scene(LEVEL_1_1)
	var up: bool = await wait_until(func(): return current_scene != null and current_scene.scene_file_path == LEVEL_1_1 and not G.transitioning_scene and player() != null, 900)
	check(up, "Classic 1-1 loads as the current scene")
	await frames(30)
	check(not BS.is_active() and BS.get_game_viewport() == null, "Classic has no Battle screen")
	check(G.get_game_viewport() == root and G.current_level.get_viewport() == root, "Classic gameplay is in the root viewport, as before")
	check(root.get_camera_2d() == player().camera, "Classic's camera is current in the root viewport")
	check(root.content_scale_size == Vector2i(320, 240) and root.content_scale_mode == Window.CONTENT_SCALE_MODE_VIEWPORT, "Classic keeps the user's resolution (%s)" % root.content_scale_size)
	check(player().camera_center_joint.get_node("RightWall").position.x == 160.0, "Classic camera walls follow the classic viewport (320 wide: +-160)")
	check(not window_state().fade_redirected, "Classic fades cover the root")
	check(G.get_node("GameHUD").offset == Vector2.ZERO, "Classic HUD has no Battle offset")
	check(not G.current_level.has_node("BattleHandler") and SESSION.current == null, "Classic has no Battle handler or session")
	# A Classic transition still replaces the scene the normal way.
	var changes := scene_changes
	LV.first_load = true
	G.transition_to_scene(TITLE)
	var back: bool = await wait_until(func(): return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene, 900)
	check(back and scene_changes == changes + 1, "Classic transitions still go through change_scene (%d scene change)" % (scene_changes - changes))
	# Existing resolutions are untouched (4:3, 5:4-ish, 16:9, expand).
	for idx in 4:
		video().set_value("size", idx)
		G.current_game_mode = G.GameMode.CAMPAIGN
		LV.first_load = true
		G.transition_to_scene(LEVEL_1_1)
		await wait_until(func(): return current_scene != null and current_scene.scene_file_path == LEVEL_1_1 and not G.transitioning_scene, 900)
		await frames(20)
		var want_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND if idx == 3 else Window.CONTENT_SCALE_ASPECT_KEEP
		check(Vector2(root.content_scale_size) == G.RESOLUTIONS[idx] and root.content_scale_aspect == want_aspect and not BS.is_active(), "Classic resolution option %d unchanged (%s)" % [idx, root.content_scale_size])
		G.transition_to_scene(TITLE)
		await wait_until(func(): return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene, 900)
