extends SceneTree
## Development tool: renders the real Battle screen (the real 1-1 in its game window, the previews, the
## attack lines and the incoming strip) in the six situations of the visible-attack milestone and saves
## PNGs of the display framebuffer. Needs a display (e.g. xvfb-run) and a GL renderer:
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 \
##     -s tests/tools/battle_attack_capture.gd -- out=/some/dir [seed=19] [pack=SandboxStandIn] [shots=1,2,3,4,5,6]
## 1 player -> opponent send (a real stomp, mid-flight)   2 bot -> bot send (mid-flight)
## 3 an opponent's pane with an incoming Goomba           4 a pane with several incoming enemies
## 5 attacks aimed at the real player (strip, flash, window frame)   6 many simultaneous attacks
## The session clock is driven by hand (the handler is switched off), so every picture is of a known
## Battle second; only the attack lines' timing follows the wall clock. Panes are also saved magnified.

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
var screen
var session
var FixedPolicy
var out := "/tmp/battle_attack"
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

func fixed_target(id: int) -> void:
	var p = FixedPolicy.new()
	p.target = id
	session.attacks.targeting = p

## Steps the session `n` Battle seconds, with the previews following (their picture trails by 2 s).
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

## The `skip`-th opponent still in the round among ids lo..hi (a defeat by an eliminated bot sends nothing).
func alive_between(lo: int, hi: int, skip := 0) -> int:
	var n := 0
	for id in range(lo, hi + 1):
		if session.contestants[id].alive:
			if n == skip:
				return id
			n += 1
	return -1

## Waits (wall clock) until the line of attack `seq` has travelled `fraction` of its way.
func wait_flight(seq: int, fraction: float) -> bool:
	for i in 600:
		var f = screen.attack_view.flight_of(seq)
		if f != null and f.travel(screen.attack_view.clock) >= fraction:
			return true
		if f == null and i > 10:
			return false # (the screen picks a new send up on its next frame)
		await process_frame
	return false

## Waits (wall clock) until no attack line is left on screen, so a picture shows only what stays.
func wait_lines_gone() -> void:
	await frames(3) # (the screen picks new sends up on its next frame)
	for i in 900:
		if screen.attack_view.flights.is_empty():
			return
		await process_frame

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	Session = load("res://Scripts/Classes/Battle/BattleSession.gd")
	Handler = load("res://Scripts/Classes/Battle/BattleHandler.gd")
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
	load("res://Scripts/Classes/Battle/BattleRound.gd").pre_round_override = 0.0
	if args.has("window"):
		var wh: PackedStringArray = String(args.window).split("x")
		DisplayServer.window_set_position(Vector2i.ZERO)
		root.size = Vector2i(int(wh[0]), int(wh[1]))
		await frames(30)
	Handler.start_match()
	session = Session.begin(int(args.get("seed", "19")))
	var guard := 0
	while guard < 1500 and not (current_scene != null and current_scene.get_script() == BS and is_instance_valid(G.current_level) \
			and G.current_level.scene_file_path == LEVEL_1_1 and not G.transitioning_scene):
		await process_frame
		guard += 1
	screen = current_scene
	await frames(5)
	var handler = G.current_level.get_node_or_null("BattleHandler")
	if handler != null:
		handler.set_process(false) # the capture, not the wall clock, drives the Battle clock
	session.attacks.bots_send = false
	session.attacks.pressure_enabled = false # every bot stays in, so the pictures show attacks and not eliminations
	advance(14) # a few seconds in: the opponents are running, the player is at the start
	await frames(20)
	var wanted: Array = String(args.get("shots", "1,2,3,4,5,6")).split(",")
	var geo = load("res://Scripts/Classes/Battle/BattleAttackGeometry.gd")
	var layout: Dictionary = screen.layout
	var goomba = load("res://Scripts/Classes/Battle/BattleEnemyType.gd").Kind.GOOMBA
	var koopa = load("res://Scripts/Classes/Battle/BattleEnemyType.gd").Kind.KOOPA
	var player := get_first_node_in_group("Players")

	if wanted.has("1"):
		# a real stomp on a real Goomba: the real player's send
		fixed_target(alive_between(18, 34, 2))
		var goombas: Array = []
		for n in get_nodes_in_group("Enemies"):
			if is_instance_valid(n) and n.get_script().resource_path.ends_with("/Goomba.gd"):
				goombas.append(n)
		goombas.sort_custom(func(a, b): return a.global_position.x < b.global_position.x)
		goombas[0].stomped_on(player)
		var seq: int = session.attacks.history.size() - 1
		await wait_flight(seq, 0.55)
		await grab("01-player-sends-to-opponent")
		await frames(90)
	if wanted.has("2"):
		fixed_target(alive_between(18, 34, 8))
		var a = session.report_enemy_defeat(alive_between(1, 17, 4), koopa)
		await wait_flight(a.seq, 0.5)
		await grab("02-bot-sends-to-bot")
		await frames(90)
	if wanted.has("3"):
		fixed_target(1)
		session.report_enemy_defeat(alive_between(18, 34, 12), goomba)
		advance(8) # 3 s queued, then ACTIVE; the picture shows it from preview second 3 on
		await wait_lines_gone()
		await frames(10)
		await grab("03-opponent-with-incoming-goomba-pane", layout.slots[0], 1)
		await grab("03-opponent-with-incoming-goomba-pane-x4", layout.slots[0], 4)
		await grab("03-opponent-with-incoming-goomba-screen")
	if wanted.has("4"):
		fixed_target(1)
		session.report_enemy_defeat(alive_between(18, 34, 13), goomba)
		session.report_enemy_defeat(alive_between(18, 34, 14), koopa)
		session.report_enemy_defeat(alive_between(18, 34, 15), goomba)
		advance(7)
		await wait_lines_gone()
		await frames(10)
		await grab("04-opponent-with-several-incoming-pane", layout.slots[0], 1)
		await grab("04-opponent-with-several-incoming-pane-x4", layout.slots[0], 4)
		await grab("04-opponent-with-several-incoming-screen")
	if wanted.has("5"):
		fixed_target(0)
		var s5 := []
		s5.append(session.report_enemy_defeat(alive_between(1, 17, 1), koopa))
		s5.append(session.report_enemy_defeat(alive_between(18, 34, 1), goomba))
		s5.append(session.report_enemy_defeat(alive_between(18, 34, 9), goomba))
		await wait_flight(s5[2].seq, 0.5)
		await grab("05-incoming-on-real-player-flights")
		await frames(60)
		session.report_enemy_defeat(alive_between(1, 17, 7), koopa)
		advance(3) # the first three go ACTIVE; the fourth waits
		await frames(3)
		await grab("05-incoming-on-real-player-strip-flash")
		await grab("05-incoming-on-real-player-strip-flash-x4", Rect2(112, 238, 256, 24), 4)
		await frames(80)
		await grab("05-incoming-on-real-player-strip-settled")
		await grab("05-incoming-on-real-player-strip-settled-x4", Rect2(112, 238, 256, 24), 4)
	if wanted.has("6"):
		# The heaviest second a match can have: every contestant defeats an enemy at the same moment (35
		# lines at once), on top of enemies already incoming everywhere (three bursts earlier, so most
		# opponents have two or three ACTIVE and shown in their previews).
		session.attacks.targeting = load("res://Scripts/Classes/Battle/BattleTargetingRandomSurvivor.gd").new()
		for burst in 3:
			for id in range(0, 35):
				session.report_enemy_defeat(id, goomba if (id + burst) % 3 else koopa)
			advance(1)
		advance(6)
		await wait_lines_gone()
		await frames(10)
		for id in range(0, 35):
			session.report_enemy_defeat(id, koopa if id % 4 == 0 else goomba)
		await frames(12)
		await grab("06-stress-simultaneous-attacks")
		print("STRESS flights in the air: %d, ACTIVE attacks: %d" % [screen.attack_view.flights.size(), session.attacks.history.filter(func(a): return a.state == 1).size()])
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
	quit(0)
