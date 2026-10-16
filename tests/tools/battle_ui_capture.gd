extends SceneTree
## Development tool for the SMB35 UI fidelity pass (doc 50): renders the real Battle screen in the situations the
## pass changed and saves PNGs of the display framebuffer, so the screen can be compared by eye with the reference
## video (which is never read by this tool or stored anywhere in the repository). Needs a display and a GL renderer:
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 \
##     -s tests/tools/battle_ui_capture.gd -- out=/some/dir [seed=19] [pack=SandboxStandIn] [shots=1,2,3,4,5,6,7,8]
##   1 match start: HERE WE GO..., READY, 3, 2, 1, GO! (real time)     2 the whole screen in play
##   3 the targeting selector: at rest, just changed, settling, Most Coins refused, the reticle punch
##   4 the incoming bar: queued icons travelling, waiting at the boundary, in the level, WATCH OUT! and the eye counter
##   5 KO cards: the animation at six moments, then settled; the alive badge          6 the whole screen late in a match
##   7 the labels debug mode (F3)           8 the window crop: the hidden rows beside the window, with and without the HUD
## The session clock is driven by hand (the handler is switched off), so every picture is of a known Battle second;
## only presentation animations follow the wall clock.

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(_session, _sender, _draw) -> int:
	return target
"""

var args := {}
var G
var BS
var Session
var Handler
var Round
var screen
var session
var FixedPolicy
var out := "/tmp/battle_ui"
var shot_scale := 4.0

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	_run()

func frames(n: int) -> void:
	for i in n:
		await process_frame

## Every send goes to `id` (0 = the real player) from now on.
func fixed_target(id: int) -> void:
	var p = FixedPolicy.new()
	p.target = id
	session.attacks.targeting = p

func advance(n: int) -> void:
	for i in n:
		session.step()
		screen.driver.update(0.0)
		screen.driver.update(0.5)
	Handler.presentation_alpha = 0.5
	for cell in screen.cells:
		if cell.is_live():
			cell.queue_redraw()

func grab(name: String, crop := Rect2(), magnify := 1) -> void:
	await frames(2)
	await RenderingServer.frame_post_draw
	var img := DisplayServer.screen_get_image(0)
	img = img.get_region(Rect2i(DisplayServer.window_get_position(), DisplayServer.window_get_size()))
	shot_scale = img.get_width() / 480.0
	if crop.size != Vector2.ZERO:
		img = img.get_region(Rect2i(Vector2i(crop.position * shot_scale), Vector2i(crop.size * shot_scale)))
	if magnify > 1:
		img.resize(img.get_width() * magnify, img.get_height() * magnify, Image.INTERPOLATE_NEAREST)
	var file := "%s/%s.png" % [out, name]
	img.save_png(file)
	print("CAPTURE ", file, " ", img.get_size())

func alive_between(lo: int, hi: int, skip := 0) -> int:
	var n := 0
	for id in range(lo, hi + 1):
		if session.contestants[id].alive:
			if n == skip:
				return id
			n += 1
	return -1

## Resizes the game window and waits until the display really shows it that size (see battle_screen_render_test.gd).
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

## Waits (wall clock) until the round has spent `seconds` in its current state.
func wait_state_time(seconds: float) -> void:
	for i in 1200:
		if screen.battle_round.time_in_state >= seconds:
			return
		await process_frame

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	Session = load("res://Scripts/Classes/Battle/BattleSession.gd")
	Handler = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	Round = load("res://Scripts/Classes/Battle/BattleRound.gd")
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	out = args.get("out", out)
	DirAccess.make_dir_recursive_absolute(out)
	var settings = root.get_node("Settings")
	var saved_settings_file := FileAccess.get_file_as_string(settings.SETTINGS_DIR)
	var saved_video: Dictionary = settings.file.video.duplicate(true)
	var original_window := root.size
	var packs: Array = settings.file.visuals.resource_packs
	var added_pack: String = args.get("pack", "")
	if added_pack != "":
		packs.insert(0, added_pack)
	var wanted: Array = String(args.get("shots", "1,2,3,4,5,6,7,8")).split(",")
	if not wanted.has("1"):
		Round.pre_round_override = 0.0
	var wh: PackedStringArray = String(args.get("window", "1920x1080")).split("x")
	await ensure_window(Vector2i(int(wh[0]), int(wh[1])))
	Handler.start_match()
	session = Session.begin(int(args.get("seed", "19")))
	var guard := 0
	while guard < 1500 and not (current_scene != null and current_scene.get_script() == BS and is_instance_valid(G.current_level) \
			and G.current_level.scene_file_path == LEVEL_1_1 and not G.transitioning_scene):
		await process_frame
		guard += 1
	screen = current_scene
	var handler = G.current_level.get_node_or_null("BattleHandler")
	if handler != null:
		handler.set_process(false)
	session.attacks.bots_send = false
	session.attacks.pressure_enabled = false
	var layout: Dictionary = screen.layout
	var goomba = load("res://Scripts/Classes/Battle/BattleEnemyType.gd").Kind.GOOMBA
	var koopa = load("res://Scripts/Classes/Battle/BattleEnemyType.gd").Kind.KOOPA
	var mode = load("res://Scripts/Classes/Battle/BattleTargeting.gd").Mode

	if wanted.has("1"):
		# the start sequence, in real time from the moment the round is frozen
		while screen.battle_round.state != Round.State.PRE_ROUND:
			await process_frame
		for step in [["01a-here-we-go", 0.3], ["01b-ready", 1.5], ["01c-three", 2.6], ["01d-two", 3.6], ["01e-one", 4.6]]:
			await wait_state_time(step[1])
			await grab(step[0])
		while screen.battle_round.state == Round.State.PRE_ROUND:
			await process_frame
		await frames(6)
		await grab("01f-go")
		while screen.battle_round.banner_text() != "":
			await process_frame
	await frames(5)
	if screen.battle_round.state == Round.State.PRE_ROUND:
		await wait_state_time(99.0)
	advance(14)
	await frames(40)

	if wanted.has("2"):
		await grab("02-whole-screen")
		await grab("02-window-hud", layout.game.grow(2.0), 2)
		await grab("02-left-panel", Rect2(0, 0, 108, 270), 3)
		await grab("02-right-panel", Rect2(372, 0, 108, 270), 3)
	if wanted.has("3"):
		var cross: Rect2 = layout.hud.selector.cross.grow(6.0)
		await frames(120) # the intro fade is over: at rest
		await grab("03a-selector-rest", cross, 6)
		screen.select_target_mode(mode.LOWEST_TIME)
		await frames(2)
		await grab("03b-selector-just-changed", cross, 6)
		await frames(14)
		await grab("03c-selector-swell-peak", cross, 6)
		await frames(40)
		await grab("03d-selector-settling", cross, 6)
		await frames(90)
		await grab("03e-selector-back-at-rest", cross, 6)
		screen.select_target_mode(mode.MOST_COINS)
		await frames(6)
		await grab("03f-most-coins-refused", cross, 6)
		await frames(120)
		screen.select_target_mode(mode.ATTACKERS)
		await frames(10)
		await grab("03g-attackers-chosen", cross, 6)
		screen.select_target_mode(mode.RANDOM)
		await frames(3)
		await grab("03h-reticle-punch", Rect2(0, 0, 108, 270), 4)
		await frames(40)
		await grab("03i-reticle-settled", Rect2(0, 0, 108, 270), 4)
	if wanted.has("4"):
		var bar: Rect2 = Rect2(layout.strip_a.position - Vector2(2, 1), Vector2(layout.strip_a.size.x + 4, 28))
		await grab("04a-bar-empty", bar, 4)
		fixed_target(0)
		for k in 4:
			session.report_enemy_defeat(alive_between(1, 34, 3 + k * 5), goomba if k % 2 == 0 else koopa)
			if k < 3:
				var p := 0
				while p < 25:
					p += 1
					await process_frame
		for t in [["04b-bar-watch-out", 0.5], ["04c-bar-travelling", 1.0], ["04d-bar-later", 1.0]]:
			await frames(int(60.0 * t[1]))
			await grab(t[0], bar, 4)
			await grab(t[0] + "-screen")
		advance(4) # the first three become ACTIVE
		await frames(30)
		await grab("04e-bar-active", bar, 4)
		await frames(60)
		await grab("04f-bar-waiting", bar, 4)
	if wanted.has("5"):
		var victim := alive_between(1, 17, 5)
		await grab("05a-before-ko", layout.slots[victim - 1].grow(6.0), 8)
		session.report_ko(victim, session.KoCause.HAZARD)
		advance(3)
		var pane = screen.panes[victim - 1]
		for k in 600:
			await process_frame
			if pane.marked:
				break
		var shots := [0.03, 0.12, 0.28, 0.45, 0.63, 0.8]
		for i in shots.size():
			pane.ko_age = shots[i]
			pane.overlay.queue_redraw()
			screen.set_process(false) # hold the clock so the crop shows the chosen moment
			await grab("05b-ko-%d" % i, (layout.slots[victim - 1] as Rect2).grow(6.0), 8)
			screen.set_process(true)
		pane.ko_age = pane.KO_SECONDS
		await grab("05c-ko-settled", Rect2(0, 0, 108, 270), 4)
		for k in 8:
			session.report_ko(alive_between(18, 34, k), session.KoCause.TIME)
		advance(3)
		await frames(120)
		await grab("05d-many-kos")
	if wanted.has("6"):
		await grab("06-late-match")
	if wanted.has("7"):
		var panes_cls = load("res://Scripts/Classes/Battle/BattleOpponentPane.gd")
		panes_cls.show_labels = true
		await frames(4)
		await grab("07-labels-debug")
		panes_cls.show_labels = false
	if wanted.has("11"):
		# the player's send: the reticle's flight at several moments, then the bot-to-player line (doc 51)
		var layout_now: Dictionary = screen.layout
		var target_id := alive_between(18, 34, 5)
		fixed_target(target_id)
		await frames(40)
		screen.game_frozen = true # holds the presentation clock; the moments below are stepped by hand
		var atk = session.report_enemy_defeat(0, load("res://Scripts/Classes/Battle/BattleEnemyType.gd").Kind.GOOMBA)
		var elapsed := 0.0
		for step in [["11a-send-0ms", 0.0], ["11b-send-60ms", 0.06], ["11c-send-120ms", 0.06], ["11d-send-190ms", 0.07], ["11e-send-250ms", 0.06]]:
			screen.attack_view.update(step[1])
			elapsed += step[1]
			screen.refresh()
			await grab(step[0] + "-window", Rect2(100, 0, 280, 270), 3)
			await grab(step[0] + "-right", Rect2(372, 0, 108, 270), 3)
		print("SEND target=", target_id, " flight=", atk.seq)
		screen.game_frozen = false
		await frames(60)
		fixed_target(0)
		session.report_enemy_defeat(alive_between(1, 17, 6), load("res://Scripts/Classes/Battle/BattleEnemyType.gd").Kind.KOOPA)
		await frames(14)
		await grab("11f-bot-to-player-line")
		await grab("11f-bot-to-player-line-bar", Rect2(0, 190, 480, 80), 2)
	if wanted.has("10"):
		# the results: the field must look exactly as it did when the round ended (doc 51)
		await grab("10a-before-death")
		get_first_node_in_group("Players").die()
		var got_results := false
		for i in 1800:
			await process_frame
			if screen.battle_round.state == Round.State.RESULTS:
				got_results = true
				break
		await frames(90)
		await grab("10b-results")
		await grab("10b-results-left-panel", Rect2(0, 0, 108, 270), 3)
		await grab("10b-results-right-panel", Rect2(372, 0, 108, 270), 3)
		print("RESULTS reached: ", got_results)
	if wanted.has("8"):
		await grab("08-window-crop", Rect2(100, 0, 280, 270), 3)
	if added_pack != "":
		packs.erase(added_pack)
	if root.size != original_window:
		root.size = original_window
		await frames(30)
	for key in saved_video:
		settings.file.video[key] = saved_video[key]
	var settings_out := FileAccess.open(settings.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	Round.pre_round_override = -1.0
	quit(0)
