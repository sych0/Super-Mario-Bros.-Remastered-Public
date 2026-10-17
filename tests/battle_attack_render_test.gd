extends SceneTree
## Render checks for the visible attack loop: the real project is drawn by a real GL renderer and the
## display framebuffer is inspected. Covers what a headless run cannot see: the line of a send is on
## screen between its sender and its target and the target pane is marked, a bot's line across the
## player's playfield is only faint, an ACTIVE attack puts a halo, a marker and an enemy into the
## opponent's miniature game and a pip on its pane, the real player's incoming strip shows lit and dim
## icons and its counts, the game window's frame lights up when something is sent at the player, and
## all of it is gone again when the lines have landed. Also pins the cost of drawing a heavy second.
##
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 \
##     -s tests/battle_attack_render_test.gd -- [out=/some/dir] [pack=SandboxStandIn]
## (pack= adds a resource pack for this run only, see tests/tools/make_standin_pack.py; out= saves the pictures it inspects)

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(_session, _sender, _draw) -> int:
	return target
"""

var failures := 0
var args := {}
var G
var S
var BS
var HANDLER
var SESSION
var KIND
var GEO
var FixedPolicy
var screen
var session
var out := ""
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
func grab(name := "") -> Image:
	await RenderingServer.frame_post_draw
	var img := DisplayServer.screen_get_image(0)
	img = img.get_region(Rect2i(DisplayServer.window_get_position(), DisplayServer.window_get_size()))
	shot_scale = img.get_width() / 480.0
	if name != "" and out != "":
		DirAccess.make_dir_recursive_absolute(out)
		img.save_png("%s/%s_%dx%d.png" % [out, name, img.get_width(), img.get_height()])
	return img

func px(img: Image, x: float, y: float) -> Color:
	return img.get_pixel(clampi(int((x + 0.5) * shot_scale), 0, img.get_width() - 1), clampi(int((y + 0.5) * shot_scale), 0, img.get_height() - 1))

func diff(a: Color, b: Color) -> float:
	return maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b)))

## Fraction of the pixels of the logical `rect` that differ from `base` by more than `tol`.
func changed_fraction(img: Image, base: Image, rect: Rect2, tol := 0.05) -> float:
	var n := 0
	var changed := 0
	var step := 2
	for y in range(int(rect.position.y * shot_scale), int(rect.end.y * shot_scale), step):
		for x in range(int(rect.position.x * shot_scale), int(rect.end.x * shot_scale), step):
			n += 1
			if diff(img.get_pixel(x, y), base.get_pixel(x, y)) > tol:
				changed += 1
	return float(changed) / float(maxi(n, 1))

## How many pixels of `rect` have the pink / red of the incoming-enemy halo and marker.
func halo_pixels(img: Image, rect: Rect2) -> int:
	var n := 0
	for y in range(int(rect.position.y * shot_scale), int(rect.end.y * shot_scale)):
		for x in range(int(rect.position.x * shot_scale), int(rect.end.x * shot_scale)):
			var c := img.get_pixel(x, y)
			if c.r > 0.55 and c.r - c.g > 0.22 and c.b > 0.3 and c.r - c.b > 0.0 and c.b < c.r + 0.1:
				n += 1
	return n

func fixed_target(id: int) -> void:
	var p = FixedPolicy.new()
	p.target = id
	session.attacks.targeting = p

func advance(n: int) -> void:
	for i in n:
		session.step()
		screen.driver.update(0.0)
		screen.driver.update(0.5)
	HANDLER.presentation_alpha = 0.5
	for cell in screen.cells:
		if cell.is_live():
			cell.queue_redraw()

func alive_between(lo: int, hi: int, skip := 0) -> int:
	var n := 0
	for id in range(lo, hi + 1):
		if session.contestants[id].alive:
			if n == skip:
				return id
			n += 1
	return -1

## Waits until the line of attack `seq` has travelled `fraction` of its way (the screen picks a new send up on its next frame).
func wait_flight(seq: int, fraction: float) -> bool:
	for i in 600:
		var f = screen.attack_view.flight_of(seq)
		if f != null and f.travel(screen.attack_view.clock) >= fraction:
			return true
		if f == null and i > 10:
			return false
		await process_frame
	return false

func wait_lines_gone() -> void:
	await frames(3)
	for i in 900:
		if screen.attack_view.flights.is_empty():
			break
		await process_frame
	await frames(3)

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = root.get_node("Settings")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	KIND = load("res://Scripts/Classes/Battle/BattleEnemyType.gd").Kind
	GEO = load("res://Scripts/Classes/Battle/BattleAttackGeometry.gd")
	load("res://Scripts/Classes/Battle/BattleRound.gd").pre_round_override = 0.0
	load("res://Scripts/Classes/Battle/BattleIncomingSpawner.gd").enabled = false # the view only: attacks on the player stay off the level here
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	out = args.get("out", "")
	var packs: Array = S.file.visuals.resource_packs
	var added_pack: String = args.get("pack", "")
	if added_pack != "":
		packs.insert(0, added_pack)
	var saved_video: Dictionary = S.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR)
	var original_window := root.size
	await ensure_window(Vector2i(1920, 1080))

	G.current_game_mode = G.GameMode.NONE
	HANDLER.start_match()
	session = SESSION.begin(19) # a fixed match, so the previews look the same every run
	var up: bool = await wait_until(func(): return level_running(), 1500)
	check(up, "Battle starts and 1-1 is running")
	screen = current_scene
	await frames(5)
	var handler = G.current_level.get_node_or_null("BattleHandler")
	if handler != null:
		handler.set_process(false) # the test, not the wall clock, drives the Battle clock
	session.attacks.bots_send = false
	session.attacks.pressure_enabled = false
	advance(14)
	await frames(20)
	var layout: Dictionary = screen.layout
	var game: Rect2 = layout.game

	await test_target_reticle(layout)
	await test_player_send(layout, game)
	await test_bot_send(layout, game)
	await test_incoming_in_preview(layout)
	await test_player_incoming(layout, game)
	await test_stress()
	await test_target_reticle_ko(layout) # last: it KOs a contestant, which the sections above must not see

	if added_pack != "":
		packs.erase(added_pack)
	if root.size != original_window:
		root.size = original_window
		await frames(30)
	for key in saved_video:
		S.file.video[key] = saved_video[key]
	load("res://Scripts/Classes/Battle/BattleRound.gd").pre_round_override = -1.0
	load("res://Scripts/Classes/Battle/BattleIncomingSpawner.gd").enabled = true
	var settings_out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle attack render test(s) failed" % failures)
	else:
		print("All Battle attack render tests passed")
	quit(1 if failures > 0 else 0)

## Red as the reference's reticle: r > 225, g < 50, b < 70 (8 bits).
func is_reticle_red(c: Color) -> bool:
	return c.r > 225.0 / 255.0 and c.g < 50.0 / 255.0 and c.b < 70.0 / 255.0

## How many of the four corner brackets of pane `id` have both arms red at their middle (the rest box: the persistent bracket inside the pane).
func red_corners(img: Image, layout: Dictionary, id: int) -> int:
	var centers: Array[Vector2] = load("res://Scripts/Classes/Battle/BattleTargetReticle.gd").arm_centers(GEO.rest_box(layout.slots[id - 1]))
	var n := 0
	for k in 4:
		if red_near(img, centers[2 * k].x, centers[2 * k].y) and red_near(img, centers[2 * k + 1].x, centers[2 * k + 1].y):
			n += 1
	return n

## Whether a pure reticle red lies within one device pixel of the logical point (x, y).
func red_near(img: Image, x: float, y: float) -> bool:
	var cx := int(x * shot_scale)
	var cy := int(y * shot_scale)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c := img.get_pixel(clampi(cx + dx, 0, img.get_width() - 1), clampi(cy + dy, 0, img.get_height() - 1))
			if is_reticle_red(c):
				return true
	return false

## How many of the four corner brackets of a bracket whose OUTER box is `box` (the reticle in flight, or at rest) have both arms red at their middle.
func red_corners_of_box(img: Image, box: Rect2) -> int:
	var centers: Array[Vector2] = load("res://Scripts/Classes/Battle/BattleTargetReticle.gd").arm_centers(box)
	var n := 0
	for k in 4:
		if red_near(img, centers[2 * k].x, centers[2 * k].y) and red_near(img, centers[2 * k + 1].x, centers[2 * k + 1].y):
			n += 1
	return n

func test_target_reticle(layout: Dictionary) -> void:
	print("-- the target reticle")
	var t: int = session.target_of(0)
	await frames(24)
	var img := await grab("target_00_reticle")
	check(t >= 1 and red_corners(img, layout, t) == 4, "the player's target pane (#%d) has a red bracket at all four corners" % t)
	var others_red := 0
	for id in range(1, 35):
		if id != t:
			others_red += red_corners(img, layout, id)
	check(others_red <= 12, "no other pane has a whole one (a neighbour's near corners can sit in the shared gap: %d arms)" % others_red)
	var others_full := 0
	for id in range(1, 35):
		if id != t and red_corners(img, layout, id) == 4:
			others_full += 1
	check(others_full == 0, "no other pane has all four")
	var rect: Rect2 = layout.slots[t - 1]
	check(is_reticle_red(px(img, rect.position.x + 3.0, rect.position.y + 3.0)) and not is_reticle_red(px(img, rect.get_center().x, rect.get_center().y)), "the bracket is inside the pane (thick corners over the picture's corners) and open in the middle (doc 54)")
	# it follows the player's mode (the times are equal, so one lower time decides)
	var equal_time: int = session.get_player().time_left
	var low := alive_between(18, 34, 3)
	session.contestants[low].time_left = equal_time - 40
	check(screen.select_target_mode(1) and session.target_of(0) == low, "(Lowest Time selected: #%d)" % low)
	await frames(24)
	var img2 := await grab("target_01_lowest_time")
	check(red_corners(img2, layout, low) == 4 and (low == t or red_corners(img2, layout, t) < 4), "in Lowest Time the bracket moves to the lowest-time pane (#%d) and leaves the old one" % low)
	session.contestants[low].time_left = equal_time
	check(screen.select_target_mode(0) and session.player_target_mode == 0, "(Random selected again, times restored)")
	await frames(3)

## At the very end (it KOs a contestant, which the sections above must not see), once the stress test's lines are gone.
func test_target_reticle_ko(layout: Dictionary) -> void:
	print("-- the target reticle after a KO")
	session.attacks.targeting = load("res://Scripts/Classes/Battle/BattleTargetingModes.gd").new() # the stock router (earlier sections installed test policies)
	session.attacks.bots_send = false
	screen.attack_view.clear_flights()
	await frames(30)
	var victim: int = session.target_of(0)
	var img := await grab("target_02_before_ko")
	check(victim >= 1 and red_corners(img, layout, victim) == 4, "the bracket is on the target (#%d)" % victim)
	session.report_ko(victim, session.KoCause.HAZARD)
	var next: int = session.target_of(0)
	advance(1)
	await frames(24)
	var img3 := await grab("target_03_after_ko")
	check(next != victim and next >= 1 and red_corners(img3, layout, next) == 4 and red_corners(img3, layout, victim) < 4, "when its pane is KO'd the bracket moves to #%d and no whole one is left on the KO'd one" % next)
	var shown := 0
	for id in range(1, 35):
		if red_corners(img3, layout, id) == 4:
			shown += 1
	check(shown == 1, "exactly one pane has a whole bracket")

func test_player_send(layout: Dictionary, game: Rect2) -> void:
	print("-- the real player's send: the bracket flies in a straight line at constant speed from the window's middle (doc 54)")
	await wait_lines_gone()
	await frames(30)
	var base := await grab("attack_00_baseline")
	var target := alive_between(18, 34, 2)
	fixed_target(target)
	var old_target: int = session.target_of(0)
	var view = screen.attack_view
	var ret = screen.target_reticle
	var pane: Rect2 = layout.slots[target - 1]
	# hold the clock and step the flight by hand: each picture is of an exact moment (15 frames = 0.25 s)
	screen.game_frozen = true
	var a = session.report_enemy_defeat(0, KIND.GOOMBA)
	view.update(0.0)
	screen.refresh()
	var f = view.flight_of(a.seq)
	check(f != null and f.target == target and ret.flying.size() == 1 and ret.flying[0].target == target and not ret.persistent_visible(), "the reticle is in the air towards the authoritative recipient (#%d)" % target)
	var seen_dx := []
	var moments := [0.0, 5.0 / 15.0, 10.0 / 15.0, 14.0 / 15.0]
	var prev_center := Vector2.ZERO
	var prev_step := Vector2.ZERO
	var linear := true
	var at_window := 0
	var imgs := []
	var elapsed := 0.0
	for m in moments:
		view.update(m * F_SECONDS() - elapsed)
		elapsed = m * F_SECONDS()
		screen.refresh()
		var shot := await grab("attack_01_player_send_%02d" % int(m * 15.0))
		imgs.append(shot)
		var prog: float = float(ret.flying[0].progress) if ret.flying.size() == 1 else 1.0
		var box: Rect2 = GEO.send_rect(layout, target, prog)
		var corners := red_corners_of_box(shot, box)
		check(corners >= 3, "at frame %d of 15 its bracket is drawn where the flight says: centre (%.1f, %.1f), %d of 4 corners red" % [int(round(m * 15.0)), box.get_center().x, box.get_center().y, corners])
		if m == 0.0 and box.get_center().is_equal_approx(game.get_center()):
			at_window += 1
	check(at_window == 1, "frame 0 is at the window's middle (240, 120)")
	check(red_corners_of_box(imgs[0], GEO.rest_box(pane)) < 4 and red_corners_of_box(imgs[0], GEO.rest_box(layout.slots[old_target - 1])) < 4, "neither the old target's pane nor the recipient's carries the persistent bracket while it flies (it is the one in the air)")
	check(changed_fraction(imgs[1], base, pane.grow(-2.0)) < 0.25, "the recipient pane is not tinted (%.0f %% of its pixels changed)" % [changed_fraction(imgs[1], base, pane.grow(-2.0)) * 100.0])
	# no gold line, no enemy riding it, no frame flash
	var from: Vector2 = GEO.send_start(layout)
	var to: Vector2 = pane.get_center()
	var line_hits := 0
	for k in range(1, 9):
		var p := from.lerp(to, 0.1 * k)
		var behind: Vector2 = p.lerp(from, 0.5)
		var c := px(imgs[3], behind.x, behind.y + 8.0)
		if c.r > 0.97 and c.g > 0.85 and c.b < 0.5:
			line_hits += 1
	check(line_hits == 0, "no gold line trails behind it (%d gold samples)" % line_hits)
	var lit := 0
	for k in 6:
		var y: float = game.position.y + 30.0 + k * 30.0
		if px(base, game.position.x - 2.0, y).g - px(imgs[3], game.position.x - 2.0, y).g > 0.1:
			lit += 1
	check(lit == 0, "the game window's frame does not flash (%d of 6 samples changed)" % lit)
	# a newer send takes the bracket over: it restarts at the window's middle, and the old one is gone
	var target2 := alive_between(1, 17, 3)
	fixed_target(target2)
	var b = session.report_enemy_defeat(0, KIND.KOOPA)
	view.update(0.0)
	screen.refresh()
	var rapid := await grab("attack_01d_player_send_rapid")
	check(ret.flying.size() == 1 and ret.flying[0].seq == b.seq and ret.flying[0].target == target2 and float(ret.flying[0].progress) == 0.0, "a newer send takes over: one bracket in the air, the newest, back at its start")
	check(red_corners_of_box(rapid, GEO.send_rect(layout, target, 14.0 / 15.0)) < 3, "...and the older bracket is not drawn any more (it never lands)")
	check(red_corners_of_box(rapid, GEO.send_rect(layout, target2, 0.0)) >= 3, "...the new one sits at the window's middle")
	# it lands, and one bracket is left
	screen.game_frozen = false
	await frames(40)
	var after := await grab("attack_01b_player_send_landed")
	check(ret.flying.is_empty() and ret.persistent_visible() and ret.target == session.target_of(0) and red_corners(after, layout, ret.target) == 4, "it has landed: one bracket, on the session's target (#%d)" % ret.target)
	check(red_corners(after, layout, target) < 4 or ret.target == target, "(the cancelled one never settled on #%d)" % target)
	var stray := 0
	for k in range(1, 9):
		var p := from.lerp(pane.get_center(), 0.1 * k)
		if not game.has_point(p) and diff(px(after, p.x, p.y), px(base, p.x, p.y)) > 0.2:
			stray += 1
	check(stray <= 1, "and nothing is left on the screen along its way (%d stray samples)" % stray)

func F_SECONDS() -> float:
	return load("res://Scripts/Classes/Battle/BattleSendStyle.gd").SECONDS

func test_bot_send(layout: Dictionary, game: Rect2) -> void:
	print("-- a bot's send at another bot: nothing is drawn")
	await wait_lines_gone()
	await frames(30)
	var base := await grab()
	var sender := alive_between(1, 17, 4)
	var target := alive_between(18, 34, 8)
	fixed_target(target)
	var a = session.report_enemy_defeat(sender, KIND.KOOPA)
	await frames(8)
	var img := await grab("attack_02_bot_send")
	var view = screen.attack_view
	check(view.flight_of(a.seq) == null and view.flights.is_empty() and screen.target_reticle.flying.is_empty(), "the send makes no flight and no reticle")
	var pane: Rect2 = layout.slots[target - 1]
	check(changed_fraction(img, base, pane.grow(-2.0)) < 0.25, "the target pane is not marked")
	var from: Vector2 = GEO.center_of(layout, sender)
	var to: Vector2 = GEO.center_of(layout, target)
	var drawn := 0
	for k in range(1, 40):
		var p := from.lerp(to, k / 40.0)
		if game.has_point(p) or pane.has_point(p) or (layout.slots[sender - 1] as Rect2).has_point(p):
			continue
		if diff(px(img, p.x, p.y), px(base, p.x, p.y)) > 0.3:
			drawn += 1
	check(drawn <= 2, "and no line runs between the two panes (%d changed samples along it)" % drawn)
	var inside := 0
	for k in range(1, 40):
		var p := from.lerp(to, k / 40.0)
		if game.has_point(p) and diff(px(img, p.x, p.y), px(base, p.x, p.y)) > 0.3:
			inside += 1
	check(inside <= 2, "nor across the player's playfield (%d changed samples)" % inside)
	await wait_lines_gone()

func test_incoming_in_preview(layout: Dictionary) -> void:
	print("-- an incoming enemy in an opponent's preview")
	await wait_lines_gone()
	var target := 1
	var pane: Rect2 = layout.slots[target - 1]
	var before := await grab()
	var halo_before := halo_pixels(before, pane)
	fixed_target(target)
	session.report_enemy_defeat(alive_between(18, 34, 12), KIND.GOOMBA)
	advance(5) # ACTIVE after 3 s; the picture trails the session by 2 s, so it shows it from here on
	await wait_lines_gone()
	var img := await grab("attack_03_incoming_goomba_pane")
	var track = screen.driver.tracks[target]
	check(track.invaders.size() == 1 and track.invaders[0].kind == KIND.GOOMBA, "the opponent's preview has one incoming Goomba")
	check(screen.cells[target - 1].frame.invaders.size() == 1, "and its picture carries it")
	var halo := halo_pixels(img, pane)
	check(halo > halo_before + 150, "its pane shows a halo and a marker around it (%d red / pink pixels against %d before)" % [halo, halo_before])
	var pip := px(img, pane.end.x - 5.0 + 1.5, pane.position.y + 3.5)
	check(not (pip.r > 0.9 and pip.g < 0.3 and pip.b < 0.3), "no red pip sits in the pane's corner any more: SMB35 shows no marker (%s)" % pip.to_html(false))
	check(screen.panes[target - 1].incoming == Vector2i(0, 1) and not screen.panes[target - 1].draws_pips(), "(the pane's own count is still 0 queued / 1 active)")
	# several, all at once: a Goomba, a Koopa and a Goomba active together
	advance(10) # (the first one has ended)
	await frames(5)
	check(track.invaders.is_empty() and screen.panes[target - 1].incoming == Vector2i.ZERO, "(the first one is over)")
	fixed_target(target)
	session.report_enemy_defeat(alive_between(18, 34, 12), KIND.GOOMBA)
	session.report_enemy_defeat(alive_between(18, 34, 13), KIND.KOOPA)
	session.report_enemy_defeat(alive_between(18, 34, 14), KIND.GOOMBA)
	advance(5)
	await wait_lines_gone()
	var img2 := await grab("attack_04_incoming_several_pane")
	check(track.invaders.size() == 3, "three incoming enemies are three pictures in that preview (%d)" % track.invaders.size())
	check(halo_pixels(img2, pane) > halo + 100, "and the pane shows clearly more of them (%d halo pixels)" % halo_pixels(img2, pane))
	var pips := 0
	for i in 3:
		var c := px(img2, pane.end.x - 5.0 + 1.5 - 4.0 * i, pane.position.y + 3.5)
		if c.r > 0.9 and c.g < 0.3 and c.b < 0.3:
			pips += 1
	check(pips == 0 and screen.panes[target - 1].incoming == Vector2i(0, 3), "three ACTIVE enemies, and still no pip (%d red samples)" % pips)
	# and it all ends with the attacks: Goomba at 5 s, Koopa at 7 s after activation
	advance(14)
	await frames(10)
	var img3 := await grab()
	check(track.invaders.is_empty() and screen.panes[target - 1].incoming == Vector2i.ZERO, "when the session resolves them the preview and the pane are clear")
	check(halo_pixels(img3, pane) <= halo_before + 60, "and the halos are gone from the picture")

## The bar's own pixel row at the icon `k`'s centre (send order; BattleIncomingStrip.place_all), `dx` from its centre and `dy` below the bar's top.
func tile(img: Image, k: int, dx := 0.0, dy := 4.0) -> Color:
	var bar = screen.incoming_strip
	var xs: PackedFloat32Array = bar.place_all(bar.items, bar.size.x)
	var r: Rect2 = screen.layout.strip_a
	return px(img, floorf(r.position.x + xs[k] + dx), floorf(r.position.y + dy))

## Whether icon `k`'s sprite is on the bar: some pixel in its 8 x 8 box differs clearly from the bar's own zone colour.
func icon_drawn(img: Image, k: int, zone: Color) -> bool:
	var bar = screen.incoming_strip
	var xs: PackedFloat32Array = bar.place_all(bar.items, bar.size.x)
	var r: Rect2 = screen.layout.strip_a
	for dy in range(2, 11, 2):
		for dx in range(-3, 4, 2):
			if diff(px(img, floorf(r.position.x + xs[k] + dx), floorf(r.position.y + dy)), zone) > 0.2:
				return true
	return false

func test_player_incoming(layout: Dictionary, game: Rect2) -> void:
	print("-- attacks aimed at the real player: the bar, the lines, WATCH OUT! (doc 54)")
	await wait_lines_gone()
	var base := await grab()
	var bar = screen.incoming_strip
	var strip: Rect2 = layout.strip_a
	# the three zones are the reference's flat colours
	var gold_c := px(base, strip.position.x + 40.0, strip.position.y + 6.0)
	var orange_c := px(base, strip.position.x + 130.0, strip.position.y + 6.0)
	var dark_c := px(base, strip.position.x + 230.0, strip.position.y + 6.0)
	check(diff(gold_c, bar.ZONE_GOLD) < 0.04 and diff(orange_c, bar.ZONE_ORANGE) < 0.04 and diff(dark_c, bar.ZONE_DARK) < 0.04, "the bar is the reference's gold, orange and darker orange (%s %s %s)" % [gold_c.to_html(false), orange_c.to_html(false), dark_c.to_html(false)])
	# sends at the player: icons enter the bar at once, bare sprites
	fixed_target(0)
	var seqs := []
	for i in 4:
		seqs.append(session.report_enemy_defeat(alive_between(1, 34, 3 + i * 5), KIND.KOOPA if i == 0 else KIND.GOOMBA).seq)
	await frames(3)
	var img := await grab("attack_05_incoming_on_player_icons")
	check(bar.items.size() == 4 and bar.items.all(func(it): return not it.in_transit), "four sends at the player are four icons in the bar at once (none in transit)")
	var drawn := 0
	for i in 4:
		if icon_drawn(img, i, bar.ZONE_DARK):
			drawn += 1
	check(drawn == 4, "each is a sprite on the bar (%d of 4)" % drawn)
	var plate := 0
	for i in 4:
		var c := tile(img, i, -5.6, 4.0)
		var bg_zone: Color = bar.ZONE_DARK
		if diff(c, bg_zone) > 0.1:
			plate += 1
	check(plate == 0, "...bare: no plate or outline round any of them (%d of 4 have one)" % plate)
	# the game window's frame does NOT light up
	var lit := 0
	for k in 6:
		var y: float = game.position.y + 30.0 + k * 30.0
		if px(base, game.position.x - 2.0, y).g - px(img, game.position.x - 2.0, y).g > 0.1:
			lit += 1
	check(lit == 0, "the game window's frame does not flash red while attacks land (%d of 6 samples)" % lit)
	# (the test's policy sends every re-target at the player, so the four senders aim at the player now: clear every aim first)
	for id in range(1, 35):
		if session.contestants[id].alive and session.contestants[id].target_id == 0:
			session.attacks.set_target(session, id, 1 if id != 1 else 2)
	await frames(3)
	check(not screen.status_strip.is_showing() and screen.attack_view.lines().is_empty(), "with nobody aiming at the player there is no line and no WATCH OUT!")
	# an opponent starts aiming at the player: its thin red line grows from its pane to the pill, and the pill appears
	var pill: Rect2 = layout.pill
	var sender := alive_between(1, 17, 6)
	if session.contestants[sender].target_id == 0:
		session.attacks.set_target(session, sender, alive_between(1, 17, 8))
	session.attacks.set_target(session, sender, 0)
	await frames(2)
	var early := await grab("attack_05_line_growing")
	await frames(30)
	var full := await grab("attack_05_line_full")
	var lines: Array = load("res://Scripts/Classes/Battle/BattleAttackLayer.gd").drawn_lines(screen.attack_view)
	check(lines.size() >= 1 and lines.any(func(l): return l.sender == sender and float(l.progress) == 1.0), "the line of the opponent that aims at the player has grown all the way (%d lines)" % lines.size())
	var a_pt: Vector2 = GEO.launch_point(layout, sender, 0)
	var b_pt: Vector2 = GEO.landing_point(layout, sender, 0)
	var red_samples := 0
	for k in range(1, 8):
		var p := a_pt.lerp(b_pt, k / 8.0)
		if red_near(full, p.x, p.y):
			red_samples += 1
	check(red_samples >= 5 and (layout.slots[sender - 1] as Rect2).has_point(a_pt), "it is a thin solid red line from the sender's own pane to the pill (%d of 7 samples red)" % red_samples)
	check(is_equal_approx(b_pt.x, pill.position.x) and is_equal_approx(b_pt.y, pill.position.y + GEO.PILL_LINE_DROP), "it ends on the pill's left edge, for a sender in the left panel")
	var half_red := 0
	for k in range(1, 8):
		var p := a_pt.lerp(b_pt, 0.5 + k / 16.0)
		if red_near(early, p.x, p.y):
			half_red += 1
	check(half_red <= 3, "two frames after it starts the head is still near its pane: the far half is not drawn yet (%d red samples)" % half_red)
	# WATCH OUT!: black plate with a red ring, white flash decayed
	await frames(8)
	var pill_img := await grab("attack_05_watch_out")
	var plate_px := px(pill_img, pill.position.x + 10.5, pill.get_center().y)
	var ring_px := px(pill_img, pill.position.x + 7.0, pill.get_center().y)
	check(screen.status_strip.is_showing() and plate_px.r < 0.2 and plate_px.g < 0.2 and plate_px.b < 0.2, "WATCH OUT! is up: a black plate (%s)" % plate_px.to_html(false))
	check(ring_px.r > 0.9 and ring_px.g < 0.2 and ring_px.b < 0.2, "inside a red ring (%s)" % ring_px.to_html(false))
	var stripe_px := px(pill_img, pill.position.x + 4.5, pill.get_center().y)
	check(stripe_px.r > 0.9 and stripe_px.g > 0.25 and stripe_px.g < 0.5 and stripe_px.b < 0.1, "and an orange stripe at each end (%s)" % stripe_px.to_html(false))
	# the opponent stops aiming: line and pill go that frame
	session.attacks.set_target(session, sender, alive_between(1, 17, 8))
	await frames(3)
	var gone := await grab("attack_05_line_gone")
	check(not screen.status_strip.is_showing() and not red_near(gone, a_pt.lerp(b_pt, 0.5).x, a_pt.lerp(b_pt, 0.5).y), "when it stops aiming the line and WATCH OUT! are gone")
	# the bar: icons travel at constant speed, then wait at the gold boundary
	var x_a: float = bar.place_all(bar.items, bar.size.x)[0]
	await frames(30)
	check(bar.place_all(bar.items, bar.size.x)[0] < x_a, "(the icons are travelling left)")
	advance(3) # three go ACTIVE, the fourth waits
	await frames(80)
	check(screen.incoming_strip.counts == Vector2i(1, 3), "the strip counts 1 queued / 3 active")
	var settled := await grab("attack_05_incoming_on_player_strip_settled")
	var xs: PackedFloat32Array = bar.place_all(bar.items, bar.size.x)
	var boundary: float = bar.gold_end(strip.size.x)
	check(is_equal_approx(xs[0], boundary + bar.WAIT_OFFSET) and is_equal_approx(xs[1] - xs[0], bar.PITCH), "the first waits at the gold boundary, the others one pitch behind each other")
	var waiting_drawn := 0
	for i in 4:
		if icon_drawn(settled, i, bar.ZONE_ORANGE):
			waiting_drawn += 1
	check(waiting_drawn == 4, "all four are on the bar, waiting (%d of 4)" % waiting_drawn)
	var after_icons: Vector2 = Vector2(strip.position.x + boundary + bar.WAIT_OFFSET + bar.PITCH * 6.0, strip.position.y + 5.5) # past the last waiting slot
	var empty := px(settled, after_icons.x, after_icons.y)
	check(diff(empty, bar.ZONE_ORANGE) < 0.05, "and nothing after them (%s)" % empty.to_html(false))
	check(not screen.incoming_strip.show_legend, "the bar carries no text or counts (the debug legend is off)")
	# the release: an icon whose enemy appears runs on across the boundary and is gone (no marker is left behind)
	var seq0: int = int(bar.items[0].seq)
	check(session.report_player_incoming_spawned(seq0), "(the real game puts the first enemy in the level)")
	await frames(40)
	var released := await grab("attack_05_incoming_released")
	var bx: float = strip.position.x + boundary
	var left_marker := 0
	for dx in range(-30, -4, 3):
		for dy in range(3, 10, 2):
			var c := px(released, bx + dx, strip.position.y + dy)
			if diff(c, bar.ZONE_GOLD) > 0.15 and not (c.r > 0.85 and c.g < 0.3):
				left_marker += 1 # (a thin red line of an attacker may cross the zone: that is not a marker)
	check(left_marker == 0, "the released icon leaves no marker in the gold zone (%d off-colour samples)" % left_marker)
	var ground := px(settled, game.position.x + 100.0, game.end.y - 20.0)
	check(diff(ground, px(base, game.position.x + 100.0, game.end.y - 20.0)) < 0.05, "the game window itself shows nothing of them: its ground is as before")
	var spawned := 0
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and n.global_position.x > 0.0 and n.has_meta("battle_attack_seq"):
			spawned += 1
	check(spawned == 0, "and no enemy was spawned into it")

func test_stress() -> void:
	print("-- a heavy second")
	session.attacks.targeting = load("res://Scripts/Classes/Battle/BattleTargetingRandomSurvivor.gd").new()
	for burst in 3:
		for id in range(0, 35):
			session.report_enemy_defeat(id, KIND.GOOMBA if (id + burst) % 3 else KIND.KOOPA)
		advance(1)
	advance(6)
	await wait_lines_gone()
	var layer = screen.attack_layer
	layer.stat_draw_us = 0
	layer.stat_draws = 0
	var sent := 0
	for id in range(0, 35):
		if session.report_enemy_defeat(id, KIND.KOOPA if id % 4 == 0 else KIND.GOOMBA) != null:
			sent += 1 # (a bot that has been eliminated cannot send)
	await frames(2)
	var img := await grab("attack_06_stress")
	var in_air: int = screen.attack_view.player_flights().size()
	check(sent >= 12 and in_air <= 1 and screen.attack_view.flights.filter(func(f): return f.sender != 0).is_empty(), "of %d simultaneous sends only the real player's can be in the air, and only the newest of them (%d): nothing else is drawn as a flight" % [sent, in_air])
	await frames(10)
	var per_draw: float = float(layer.stat_draw_us) / maxi(layer.stat_draws, 1)
	check(per_draw < 10000.0, "drawing what is left costs %.0f us a frame (limit 10 ms)" % per_draw)
	var invaders := 0
	for id in screen.driver.tracks:
		invaders += screen.driver.tracks[id].invaders.size()
	var active: int = session.attacks.history.filter(func(a): return a.state == 1).size()
	check(invaders >= 20 and invaders <= active + 10, "and %d incoming enemies are being shown in the previews at the same time (%d attacks are ACTIVE)" % [invaders, active])
	check(img.get_width() == 1920, "(the whole screen rendered: %s)" % img.get_size())
