extends SceneTree
## Render checks for the Battle screen (doc 38, milestone 1): the real project is drawn by a real
## GL renderer and the display framebuffer is inspected. Covers what a headless run cannot see:
## the wallpaper is behind the Mario window and never inside it, the window shows exactly the
## classic 256-wide view, enemy activation follows the contained viewport, the HUD is over the
## window, and a level fade stays inside the window. Saves the screenshots it inspects.
##
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 \
##     -s tests/battle_screen_render_test.gd -- out=/some/dir [w=1920 h=1080] [pack=<resource pack>]
##
## pack= adds a resource pack at the front of the list for this run only (see tests/tools/make_standin_pack.py).

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const GOOMBA := "res://Scenes/Prefabs/Entities/Enemies/Goomba.tscn"

## Strip A is the incoming bar (doc 47 B35-INCOMING-001): gold on the left third, then orange, then darker orange.
var ZONE_GOLD := Color8(255, 189, 9) # the incoming bar's measured zone colours (doc 54)
var ZONE_ORANGE := Color8(255, 118, 0)

var failures := 0
var args := {}
var G
var S
var BS
var HANDLER
var SESSION
var out := "/tmp/battle_screen_render"
var shot_scale := 4.0

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

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	_run()

func player() -> Node2D:
	return get_first_node_in_group("Players") as Node2D

func level_running() -> bool:
	return current_scene != null and current_scene.get_script() == BS and not G.transitioning_scene \
		and is_instance_valid(G.current_level) and G.current_level.scene_file_path == LEVEL_1_1 \
		and G.current_level.get_parent() == current_scene.game_viewport and player() != null

## Resizes the game window and waits until the display really shows it that size: the game applies its saved
## window size at start-up and an X11 window needs a few frames to follow, so a screenshot taken too early
## would show the display's white background outside a smaller window.
func ensure_window(size: Vector2i) -> void:
	DisplayServer.window_set_position(Vector2i.ZERO)
	root.size = size
	for i in 180:
		await process_frame
		await RenderingServer.frame_post_draw
		var corner := DisplayServer.screen_get_image(0).get_pixel(size.x - 1, size.y - 1)
		if DisplayServer.window_get_size() == size and corner != Color.WHITE and corner.get_luminance() < 0.99:
			break
	await frames(3)

## The display framebuffer of the game window, the way a player sees it.
func grab(name: String) -> Image:
	await RenderingServer.frame_post_draw
	var img := DisplayServer.screen_get_image(0)
	img = img.get_region(Rect2i(DisplayServer.window_get_position(), DisplayServer.window_get_size()))
	shot_scale = img.get_width() / 480.0
	if name != "":
		DirAccess.make_dir_recursive_absolute(out)
		var file := "%s/%s_%dx%d.png" % [out, name, img.get_width(), img.get_height()]
		img.save_png(file)
		print("CAPTURE ", file)
	return img

## Pixel at the centre of a logical canvas pixel.
func px(img: Image, x: float, y: float) -> Color:
	return img.get_pixel(int((x + 0.5) * shot_scale), int((y + 0.5) * shot_scale))

## The device pixel at logical canvas position (x, y), which may be a fraction of a logical pixel (the reference's hairlines).
func dev(img: Image, x: float, y: float) -> Color:
	return img.get_pixel(int(x * shot_scale), int(y * shot_scale))

func near(a: Color, b: Color, tol := 0.04) -> bool:
	return absf(a.r - b.r) <= tol and absf(a.g - b.g) <= tol and absf(a.b - b.b) <= tol

func is_sky(c: Color) -> bool:
	return c.b > 0.8 and c.b > c.r + 0.25 and c.g > c.r # the classic blue sky

func bright(c: Color) -> bool:
	return c.r > 0.92 and c.g > 0.92 and c.b > 0.92

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = root.get_node("Settings")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	load("res://Scripts/Classes/Battle/BattleRound.gd").pre_round_override = 0.0 # the checks move Mario at once
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	out = args.get("out", out)
	var packs: Array = S.file.visuals.resource_packs
	var added_pack: String = args.get("pack", "")
	if added_pack != "":
		packs.insert(0, added_pack) # in memory only; removed again before quitting
	var saved_video: Dictionary = S.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR) # the game saves it on every window change
	var original_window := root.size
	await ensure_window(Vector2i(int(args.get("w", "1920")), int(args.get("h", "1080"))))
	var before_scale := root.content_scale_size

	G.current_game_mode = G.GameMode.NONE
	HANDLER.start_match()
	SESSION.begin(int(args.get("seed", "19"))) # a fixed match, so the previews look the same every run
	var up: bool = await wait_until(func(): return level_running(), 1500)
	check(up, "Battle starts and 1-1 is running")
	await frames(90)
	var scr = BS.instance
	var game: Rect2 = scr.layout.game
	var img: Image = await grab("battle_m1_composition")
	print("window ", DisplayServer.window_get_size(), " scale ", shot_scale, " canvas ", root.content_scale_size)
	check(absf(shot_scale * 480.0 - img.get_width()) < 0.5 and absf(shot_scale * 270.0 - img.get_height()) < 1.0, "the display shows the whole 480x270 canvas (%s at %.3fx)" % [img.get_size(), shot_scale])

	# -- wallpaper behind the window ------------------------------------------------------------
	# (doc 47 B35-LAYOUT-006: wallpaper (255,190,0), frame light (255,217,56), frame dark (255,182,0), outline (59,51,33), within +-8/255)
	var tol8 := 8.0 / 255.0 + 0.004
	check(near(px(img, 0, 135), BS.WALLPAPER, tol8), "the measured gold wallpaper fills the left margin (%s)" % px(img, 0, 135).to_html(false))
	check(near(px(img, 479, 135), BS.WALLPAPER, tol8), "the gold wallpaper fills the right margin")
	check(near(px(img, 106, 135), BS.WALLPAPER, tol8), "the wallpaper shows between the left panes and the frame")
	check(near(px(img, 374, 135), BS.WALLPAPER, tol8), "the wallpaper shows between the frame and the right panes")
	check(near(px(img, 109, 135), BS.FRAME_LIGHT, tol8) and near(px(img, 370, 135), BS.FRAME_LIGHT, tol8), "the frame's light band is drawn outside both sides of the window (%s)" % px(img, 109, 135).to_html(false))
	check(near(px(img, 110.5, 135), BS.FRAME_DARK, 0.02) and near(px(img, 368.5, 135), BS.FRAME_DARK, 0.02), "...and its deeper gold band inside it")
	check(near(dev(img, 111.75, 135), BS.OUTLINE, tol8) and near(dev(img, 368.25, 135), BS.OUTLINE, tol8), "the thin dark outline sits just outside the window (%s)" % dev(img, 111.75, 135).to_html(false))
	# -- the window is exactly the classic 256-wide view, not a wider level under the panels ------------
	check(is_sky(px(img, 112, 100)) and is_sky(px(img, 367, 100)), "the window's first and last columns are the level (sky)")
	check(not is_sky(px(img, 111, 100)) and not is_sky(px(img, 368, 100)), "the level does not continue past the window edge")
	# Around the window means the margins, the gaps and the frame; the opponent panes (x 4..104 and 376..476)
	# legitimately show sky now that every pane is a live 1-1 preview.
	var sky_outside := 0
	for y in [20, 60, 100, 140, 180, 220, 255, 264]:
		for x in [0, 106, 108, 371, 372, 374, 479]:
			if is_sky(px(img, x, y)):
				sky_outside += 1
	check(sky_outside == 0, "no level sky anywhere around the window (%d sampled pixels)" % sky_outside)
	# (WATCH OUT! sits in strip B's middle only while an opponent aims at the player, so its gold is sampled left and right of it)
	check(near(px(img, 240, 242), ZONE_ORANGE, tol8) and near(px(img, 150, 242), ZONE_GOLD, tol8) and near(px(img, 160, 255), BS.STRIP_B_COLOR, tol8) and near(px(img, 362, 255), BS.STRIP_B_COLOR, tol8),
		"the two strips sit under the window: the incoming bar's gold and orange zones, and the status strip's gold")
	var strip_a_dark: Color = px(img, 340, 242)
	check(strip_a_dark.r > 0.8 and strip_a_dark.g < 0.5 and strip_a_dark.b < 0.2, "the bar's right zone is the darker orange (%s)" % strip_a_dark.to_html(false))
	# -- the window shows rows 8..231 of the 256x240 view: nothing of the hidden rows leaks above or below it ----
	check(is_sky(px(img, 240, 8)) and is_sky(px(img, 300, 100)), "the window's first row (view row 8) is the level")
	check(not is_sky(px(img, 240, 7)) and not is_sky(px(img, 240, 232)), "the rows above and below the 224-row window are the frame, not the level")
	# -- HUD over the window -----------------------------------------------------------------------
	# (the right edge is not checked: without translations the sandbox's long locale key can run past it)
	var timer_r: Rect2 = scr.layout.hud.timer
	var coin_r: Rect2 = scr.layout.hud.coins
	var timer_ink := 0
	for y in range(int(timer_r.position.y), int(timer_r.end.y)):
		for x in range(int(timer_r.position.x), int(timer_r.end.x)):
			if not is_sky(px(img, x, y)):
				timer_ink += 1
	var coin_ink := 0
	for y in range(int(coin_r.position.y), int(coin_r.end.y)):
		for x in range(int(coin_r.position.x), int(coin_r.end.x)):
			if not is_sky(px(img, x, y)):
				coin_ink += 1
	var left_of_window := 0
	for y in range(int(game.position.y), int(game.end.y)):
		for x in range(104, 110):
			if bright(px(img, x, y)):
				left_of_window += 1
	check(timer_ink > 120 and coin_ink > 15 and left_of_window == 0, "the Battle HUD (timer, coins) is drawn over the window, not beside it (%d / %d non-sky pixels, %d bright pixels left of it)" % [timer_ink, coin_ink, left_of_window])

	# -- enemy activation follows the 256-wide window ------------------------------------------------
	var cam: Camera2D = scr.game_viewport.get_camera_2d()
	var cx := cam.get_screen_center_position().x
	var near_goomba: Node2D = load(GOOMBA).instantiate()
	var far_goomba: Node2D = load(GOOMBA).instantiate()
	G.current_level.add_child(near_goomba)
	G.current_level.add_child(far_goomba)
	near_goomba.global_position = Vector2(cx + 96, -8)
	far_goomba.global_position = Vector2(cx + 190, -8) # beyond the window, but inside the old 426-wide root view
	var notifier_in := VisibleOnScreenNotifier2D.new()
	var notifier_out := VisibleOnScreenNotifier2D.new()
	G.current_level.add_child(notifier_in)
	G.current_level.add_child(notifier_out)
	notifier_in.global_position = Vector2(cx + 100, -100)
	notifier_out.global_position = Vector2(cx + 190, -100)
	await frames(6)
	check(notifier_in.is_on_screen() and not notifier_out.is_on_screen(), "a notifier +100 px from the camera is on screen, one at +190 px is not (the old root view reached +213)")
	var enabler_near: VisibleOnScreenEnabler2D = near_goomba.get_node("VisibleOnScreenEnabler2D")
	var enabler_far: VisibleOnScreenEnabler2D = far_goomba.get_node("VisibleOnScreenEnabler2D")
	check(enabler_near.is_on_screen() and not enabler_far.is_on_screen(), "Goomba activation is decided by the window: +96 awake, +190 still asleep")
	near_goomba.queue_free()
	far_goomba.queue_free()
	notifier_in.queue_free()
	notifier_out.queue_free()

	# -- Mario at the window's left wall, drawn inside the window ------------------------------------------
	for enemy in get_nodes_in_group("Enemies"):
		enemy.queue_free() # nothing may kill Mario while he walks
	var p := player()
	Input.action_press("move_right_0")
	Input.action_press("run_0")
	await frames(240)
	Input.action_release("move_right_0")
	Input.action_release("run_0")
	Input.action_press("move_left_0")
	await frames(400)
	Input.action_release("move_left_0")
	await frames(10)
	var walled: Image = await grab("battle_m1_mario_at_left_wall")
	var mario_screen_x: float = p.global_position.x - (cam.get_screen_center_position().x - 128.0)
	print("mario at window x ", mario_screen_x)
	check(mario_screen_x >= 0.0 and mario_screen_x <= 16.0, "Mario is pinned at the window's left wall (x %.1f of 256)" % mario_screen_x)
	var covered := 0
	for y in range(int(game.position.y), int(game.end.y)):
		for x in range(104, 112):
			if is_sky(px(walled, x, y)):
				covered += 1
	check(covered == 0, "nothing of the level shows between the left panes and the window frame")

	# -- the fade stays inside the window (a real transition) ---------------------------------------------------
	var block: ColorRect = G.get_node("Transition/TransitionBlock")
	var fade: Image = null
	G.transition_to_scene("res://Scenes/Levels/LevelTransition.tscn")
	var opaque: bool = await wait_until(func(): return G.get_node("Transition").visible and block.modulate.a >= 0.99, 600)
	check(opaque, "the transition reaches a fully opaque fade")
	if opaque:
		fade = await grab("battle_m1_fade_in_window")
		check(px(fade, 240, 100).r < 0.05 and px(fade, 240, 100).g < 0.05 and px(fade, 240, 100).b < 0.05, "the fade blacks out the game window")
		check(px(fade, 112, 8).get_luminance() < 0.05 and px(fade, 367, 231).get_luminance() < 0.05, "...up to the window's corners")
		check(near(px(fade, 0, 135), BS.WALLPAPER, tol8) and near(px(fade, 479, 135), BS.WALLPAPER, tol8), "...and the Battle wallpaper around it is untouched")
		check(near(px(fade, 109, 135), BS.FRAME_LIGHT, tol8), "...as is the frame")
		check(near(px(fade, 240, 242), ZONE_ORANGE, tol8), "...and the strips under the window")
		var panes_ok := true
		for r in scr.layout.slots:
			if px(fade, r.position.x + 16, r.position.y + 20).get_luminance() < 0.05:
				panes_ok = false
		check(panes_ok, "...and every opponent pane")
	await wait_until(func(): return not G.transitioning_scene, 900)
	await frames(30)
	check(current_scene == scr and is_instance_valid(scr), "the Battle screen is still the current scene after the fade")
	if not is_instance_valid(scr):
		printerr("the Battle screen is gone; stopping")
		quit(1)
		return
	var after: Image = await grab("battle_m1_after_fade")
	check(near(px(after, 0, 135), BS.WALLPAPER, tol8), "wallpaper still intact after the fade")

	# -- a round ends: the real player dies, the result card dims the window only, the next round starts ----------------
	var round_before: int = scr.battle_round.round_number
	var back_in_level: bool = await wait_until(func(): return level_running(), 1800) # the fade test above went through LevelTransition
	check(back_in_level, "1-1 is running again after the fade test's transition")
	await frames(30)
	player().die()
	var shown: bool = await wait_until(func(): return scr.showing_result, 1200)
	check(shown, "the real player's death ends the round with the result card")
	await frames(3)
	var result: Image = await grab("battle_m3_round_result")
	check(px(result, 120, 100).get_luminance() < 0.2 and near(px(result, 106, 135), BS.WALLPAPER, tol8), "the result card dims the game window only")
	scr.battle_round.time_in_state = scr.battle_round.RESULTS_MAX_SECONDS
	var again: bool = await wait_until(func(): return level_running() and scr.battle_round.round_number == round_before + 1, 1500)
	check(again and current_scene == scr, "the next round runs in the same Battle screen (never the title)")
	await frames(90)
	await grab("battle_m3_next_round_pre_round")

	# -- the targeting reticle, the selector and the KO card (UI fidelity pass) ------------------------------------------------------
	await frames(40)
	var sess = SESSION.current
	var ret = scr.target_reticle
	var shot: Image = await grab("battle_ui_reticle")
	check(ret.visible and ret.target >= 1, "the reticle is on the player's target pane")
	var tr: Rect2 = scr.layout.slots[ret.target - 1]
	var RETC = load("res://Scripts/Classes/Battle/BattleTargetReticle.gd")
	var GEOC = load("res://Scripts/Classes/Battle/BattleAttackGeometry.gd")
	var corners_red := 0
	var centers: Array[Vector2] = RETC.arm_centers(GEOC.rest_box(tr))
	for k in 4:
		var c1: Color = dev(shot, centers[2 * k].x, centers[2 * k].y)
		var c2: Color = dev(shot, centers[2 * k + 1].x, centers[2 * k + 1].y)
		if c1.r > 0.88 and c1.g < 0.2 and c1.b < 0.28 and c2.r > 0.88 and c2.g < 0.2 and c2.b < 0.28:
			corners_red += 1
	check(corners_red == 4, "red (r>225, g<50, b<70) on both arms of all four corners of the target pane's bracket, inside its pane (%d of 4)" % corners_red)
	var other_red := 0
	for i in scr.layout.slots.size():
		if i + 1 == ret.target:
			continue
		var ocs: Array[Vector2] = RETC.arm_centers(GEOC.rest_box(scr.layout.slots[i]))
		var whole := 0
		for k in 4:
			var d1: Color = dev(shot, ocs[2 * k].x, ocs[2 * k].y)
			var d2: Color = dev(shot, ocs[2 * k + 1].x, ocs[2 * k + 1].y)
			if d1.r > 0.88 and d1.g < 0.2 and d1.b < 0.28 and d2.r > 0.88 and d2.g < 0.2 and d2.b < 0.28:
				whole += 1
		if whole == 4:
			other_red += 1
	check(other_red == 0, "and no other pane has a whole bracket (%d)" % other_red)
	var Mode = load("res://Scripts/Classes/Battle/BattleTargeting.gd").Mode
	scr.select_target_mode(Mode.LOWEST_TIME)
	await frames(12)
	var sel_shot: Image = await grab("battle_ui_selector")
	var pill: Rect2 = scr.selector.pill_rect(Mode.LOWEST_TIME, scr.selector.label_scale_at(scr.selector.age))
	var gold: Color = px(sel_shot, pill.position.x + 2.0, pill.get_center().y)
	check(gold.r > 0.9 and gold.g > 0.7 and gold.b < 0.55, "the chosen pill is filled gold, the cross opaque just after the change (%s)" % gold.to_html(false))
	await frames(150)
	var rest_shot: Image = await grab("")
	var rest_gold: Color = px(rest_shot, pill.position.x + 2.0, pill.get_center().y)
	check(scr.selector.opacity() == scr.selector.REST_ALPHA and (rest_gold.r - rest_gold.b) < (gold.r - gold.b), "...and it has faded back to translucent at rest (%s)" % rest_gold.to_html(false))
	scr.select_target_mode(Mode.RANDOM)
	var victim := 1
	sess.report_ko(victim, sess.KoCause.HAZARD)
	var ko_pane = scr.panes[victim - 1]
	var marked: bool = await wait_until(func(): return ko_pane.marked, 1200)
	check(marked, "the KO'd opponent's pane shows its KO card once the picture catches up")
	await wait_until(func(): return not ko_pane.is_animating(), 240)
	await frames(3)
	var card_shot: Image = await grab("battle_ui_ko_card")
	var vr: Rect2 = scr.layout.slots[victim - 1]
	var blue: Color = px(card_shot, vr.position.x + 3.0, vr.position.y + 16.0)
	check(blue.b > 0.5 and blue.r < 0.3 and blue.g < 0.5, "the KO card is blue: its ring and field (%s)" % blue.to_html(false))
	check(ko_pane.position == vr.position and ko_pane.size == vr.size and ko_pane.placement == sess.contestants[victim].placement and ko_pane.placement > 1, "it never moved and carries the contestant's placement (%d)" % ko_pane.placement)

	# -- leave Battle ----------------------------------------------------------------------------------------------
	HANDLER.quit_battle()
	var left: bool = await wait_until(func(): return current_scene != null and current_scene.scene_file_path.ends_with("TitleScreen.tscn") and not G.transitioning_scene, 1500)
	await frames(20)
	check(left and root.content_scale_size == before_scale, "back on the title with the user's own resolution (%s)" % root.content_scale_size)
	await grab("battle_m1_title_after_quit")

	if added_pack != "":
		packs.erase(added_pack)
	root.size = original_window # the game saves the window size whenever it changes
	await frames(30)
	for key in saved_video:
		S.file.video[key] = saved_video[key]
	var settings_out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle screen render test(s) failed" % failures)
	else:
		print("All Battle screen render tests passed")
	quit(1 if failures > 0 else 0)
