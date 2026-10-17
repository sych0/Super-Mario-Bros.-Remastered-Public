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

## How many of the four corner brackets of pane `id` are pure red at their arm's middle.
func red_corners(img: Image, layout: Dictionary, id: int) -> int:
	var n := 0
	var rects: Array[Rect2] = load("res://Scripts/Classes/Battle/BattleTargetReticle.gd").corner_rects(layout.slots[id - 1])
	for i in range(0, rects.size(), 2): # one horizontal arm per corner (0, 2, 4, 6)
		var r: Rect2 = rects[i]
		# (px() samples the centre of whole logical pixel (x, y): ask for the arm's own centre)
		if is_reticle_red(px(img, r.position.x + r.size.x * 0.5 - 0.5, r.position.y + r.size.y * 0.5 - 0.5)):
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

## How many of the four corner brackets round `pane` (any rectangle: a pane, or the reticle in flight) are drawn: the arm's own middle.
func red_corners_of_rect(img: Image, pane: Rect2, alpha_ok := false) -> int:
	var n := 0
	var rects: Array[Rect2] = load("res://Scripts/Classes/Battle/BattleTargetReticle.gd").corner_rects(pane)
	for i in range(0, rects.size(), 2):
		var r: Rect2 = rects[i]
		if red_near(img, r.position.x + r.size.x * 0.5, r.position.y + r.size.y * 0.5):
			n += 1
	return n

func test_target_reticle(layout: Dictionary) -> void:
	print("-- the target reticle")
	var t: int = session.target_of(0)
	await frames(24) # (the reticle punches for 0.3 s when it lands: the corner samples are of the settled bracket)
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
	check(not is_reticle_red(px(img, rect.position.x + 1.5, rect.position.y + 1.5)), "the bracket is outside the pane, in the gap: the picture is not covered")
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
	print("-- the real player's send: the reticle holds at the window, then snaps to the pane")
	await wait_lines_gone()
	await frames(30)
	var base := await grab("attack_00_baseline")
	var target := alive_between(18, 34, 2)
	fixed_target(target)
	var old_target: int = session.target_of(0)
	var a = session.report_enemy_defeat(0, KIND.GOOMBA)
	# early: still inside BattleSendStyle.HOLD_SECONDS, so the bracket sits at the window's middle, not moving yet
	var flew: bool = await wait_flight(a.seq, 0.2)
	var img := await grab("attack_01_player_send")
	var view = screen.attack_view
	var ret = screen.target_reticle
	var f = view.flight_of(a.seq)
	check(flew and f != null and f.target == target and ret.flying.size() == 1 and ret.flying[0].target == target, "the reticle is in the air towards the authoritative recipient (#%d)" % target)
	var early_progress: float = float(ret.flying[0].progress)
	check(early_progress == 0.0, "within BattleSendStyle.HOLD_SECONDS it has not started moving yet (doc 52: no glide, the reference holds it in the window)")
	var window_rect: Rect2 = GEO.send_rect(layout, target, 0.0)
	var pane: Rect2 = layout.slots[target - 1]
	check(red_corners_of_rect(img, window_rect) >= 3, "its bracket is drawn at the window's middle while it holds there (%d of 4 corners red)" % red_corners_of_rect(img, window_rect))
	check(red_corners_of_rect(img, pane) < 4 and red_corners_of_rect(img, layout.slots[old_target - 1]) < 4, "neither the old target's pane nor the recipient's carries the persistent bracket (it is the one in the air)")
	check(changed_fraction(img, base, pane.grow(-2.0)) < 0.25, "the recipient pane is not tinted (%.0f %% of its pixels changed)" % [changed_fraction(img, base, pane.grow(-2.0)) * 100.0])
	# late: past the hold, it has snapped most of the way onto the recipient's pane (doc 52: the crossing itself is 1-2 frames)
	var flew_late: bool = await wait_flight(a.seq, 0.95)
	var img_late := await grab("attack_01c_player_send_snapping")
	var late_progress: float = float(ret.flying[0].progress) if ret.flying.size() == 1 else 1.0
	check(flew_late and late_progress > early_progress, "past the hold the bracket is snapping onto the recipient's pane (%.2f)" % late_progress)
	# no gold line, no enemy riding it, no frame flash
	var from: Vector2 = GEO.send_start(layout)
	var to: Vector2 = pane.get_center()
	var line_hits := 0
	for k in range(1, 9):
		var p := from.lerp(to, 0.1 * k)
		var behind: Vector2 = p.lerp(from, 0.5)
		if px(img_late, behind.x, behind.y + 8.0).r > 0.97 and px(img_late, behind.x, behind.y + 8.0).g > 0.85 and px(img_late, behind.x, behind.y + 8.0).b < 0.5:
			line_hits += 1
	check(line_hits == 0, "no gold line trails behind it (%d gold samples)" % line_hits)
	var lit := 0
	for k in 6:
		var y: float = game.position.y + 30.0 + k * 30.0
		if px(base, game.position.x - 2.0, y).g - px(img_late, game.position.x - 2.0, y).g > 0.1:
			lit += 1
	check(lit == 0, "the game window's frame does not flash (%d of 6 samples changed)" % lit)
	# it lands, and one bracket is left
	await frames(25)
	var after := await grab("attack_01b_player_send_landed")
	check(ret.flying.is_empty() and ret.persistent_visible() and ret.target == session.target_of(0) and red_corners_of_rect(after, layout.slots[ret.target - 1]) == 4, "it has landed: one bracket, on the session's target (#%d)" % ret.target)
	var stray := 0
	for k in range(1, 9):
		var p := from.lerp(to, 0.1 * k)
		if not game.has_point(p) and diff(px(after, p.x, p.y), px(base, p.x, p.y)) > 0.2:
			stray += 1
	check(stray <= 1, "and nothing is left on the screen along its way (%d stray samples)" % stray)

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

## The colour of the `k`-th icon's tile on the incoming bar (send order; BattleIncomingStrip.place_all), `dx` from its centre and `dy`
## below the bar's top: by default just inside the tile's top-left, left of the enemy's little picture.
func tile(img: Image, k: int, dx := -3.4, dy := 2.4) -> Color:
	var bar = screen.incoming_strip
	var xs: PackedFloat32Array = bar.place_all(bar.items, bar.size.x)
	var r: Rect2 = screen.layout.strip_a
	return px(img, floorf(r.position.x + xs[k] + dx), floorf(r.position.y + dy))

func test_player_incoming(layout: Dictionary, game: Rect2) -> void:
	print("-- attacks aimed at the real player")
	await wait_lines_gone()
	var base := await grab()
	fixed_target(0)
	var seqs := []
	for i in 4:
		seqs.append(session.report_enemy_defeat(alive_between(1, 34, 3 + i * 5), KIND.KOOPA if i == 0 else KIND.GOOMBA).seq)
	await wait_flight(seqs[3], 0.3)
	var img := await grab("attack_05_incoming_on_player_flights")
	# the game window's frame does NOT light up (SMB35 does not flash it)
	var lit := 0
	for k in 6:
		var y: float = game.position.y + 30.0 + k * 30.0
		var c := px(img, game.position.x - 2.0, y)
		var b := px(base, game.position.x - 2.0, y)
		if b.g - c.g > 0.1:
			lit += 1
	check(lit == 0, "the game window's frame does not flash red while attacks land (%d of 6 samples)" % lit)
	# thin red lines, one per sender, from the sender's own pane into the incoming bar
	var drawn_lines: Array = load("res://Scripts/Classes/Battle/BattleAttackLayer.gd").drawn_flights(screen.attack_view)
	var line_ok := drawn_lines.size() == 4
	for fl in drawn_lines:
		var a_pt: Vector2 = GEO.launch_point(layout, fl.sender, 0)
		var b_pt: Vector2 = GEO.landing_point(layout, fl.sender, 0)
		var head: Vector2 = a_pt.lerp(b_pt, fl.eased(screen.attack_view.clock))
		var red_samples := 0
		for k in range(1, 7):
			var p := a_pt.lerp(head, k / 7.0)
			if red_near(img, p.x, p.y):
				red_samples += 1
		if red_samples < 4:
			line_ok = false
		if not (layout.slots[fl.sender - 1] as Rect2).has_point(a_pt):
			line_ok = false
	check(line_ok, "each of the four attacks is a thin solid red line from its sender's pane towards the incoming bar")
	var strip: Rect2 = layout.strip_a
	# M6b (sampled in the column just left of the enemy's little picture, on the icon's own fill): while their lines are in the air the four icons are hollow place-holders (dark inside); once the lines land they are dim (QUEUED)
	var hollow := 0
	var hollow_colors := []
	for i in 4:
		var c := tile(img, i)
		hollow_colors.append(c.to_html(false))
		if diff(c, screen.incoming_strip.ZONE_DARK) < 0.1: # nothing filled in: the bar's own colour
			hollow += 1
	check(hollow >= 3 and screen.incoming_strip.items.all(func(it): return it.in_transit), "four attacks whose lines are still in the air are four hollow (in transit) icons at the right end of the incoming bar (%d hollow: %s)" % [hollow, hollow_colors])
	await wait_lines_gone()
	await frames(40) # the 'new' outlines have faded too
	var landed := await grab("attack_05_incoming_on_player_strip_queued")
	var dim := 0
	for i in 4:
		var c := tile(landed, i)
		if c.r < 0.7 and c.r > 0.3 and c.g < 0.4 and c.b < 0.3:
			dim += 1
	check(dim >= 3, "once the lines have landed they are four dim (QUEUED) icons in the incoming strip (%d dim)" % dim)
	check(screen.incoming_strip.counts == Vector2i(4, 0), "(the strip counts 4 queued / 0 active)")
	advance(3) # three go ACTIVE, the fourth waits
	await frames(1)
	var flash := await grab("attack_05_incoming_on_player_strip_flash")
	check(screen.incoming_strip.counts == Vector2i(1, 3), "the strip counts 1 queued / 3 active")
	var whitened := 0
	for i in 3:
		var c := tile(flash, i, -3.0, 2.4) # (the icons are still on their way: a pixel or two of margin from the tile's edge)
		if c.r > 0.9 and c.g > 0.32:
			whitened += 1
	check(whitened >= 2, "the icons that just became ACTIVE flash (%d of 3 whitened)" % whitened)
	await wait_lines_gone()
	await frames(60)
	var settled := await grab("attack_05_incoming_on_player_strip_settled")
	var lit_icons := 0 # (nothing spawns in this test, so an ACTIVE attack is ARRIVING: amber; in the level it would be red)
	var lit_colors := []
	for i in 3:
		var c := tile(settled, i)
		lit_colors.append(c.to_html(false))
		if c.r > 0.7 and c.g > 0.35 and c.g < 0.65 and c.b < 0.25:
			lit_icons += 1
	var dim_icon := tile(settled, 3, -3.4, 5.5)
	var after_icons: Vector2 = Vector2(strip.position.x + screen.incoming_strip.gold_end(strip.size.x) + 8.0 + 10.0 * 6.0, strip.position.y + 5.5) # past the last waiting slot
	var empty := px(settled, after_icons.x, after_icons.y)
	var bar: Color = screen.incoming_strip.ZONE_ORANGE # the bar's middle zone, where the icons wait
	check(lit_icons == 3, "three lit (ACTIVE, arriving: amber) icons once the flash has died down (%s)" % [lit_colors])
	check(dim_icon.r < 0.7 and dim_icon.r > 0.3 and dim_icon.g < 0.4, "and a dim one for the attack that is still queued (%s)" % dim_icon.to_html(false))
	check(diff(empty, bar) < 0.05, "and nothing after them (%s)" % empty.to_html(false))
	check(not screen.incoming_strip.show_legend, "the bar carries no text or counts (the debug legend is off)")
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
	var in_air: int = screen.attack_view.flights.size()
	var presented := 0
	for f in screen.attack_view.flights:
		if f.sender == 0 or f.target == 0:
			presented += 1
	check(sent >= 12 and in_air == presented and in_air <= sent, "of %d simultaneous sends only the ones that involve the real player are in the air (%d flights): bot-to-bot sends draw nothing" % [sent, in_air])
	await frames(10)
	var per_draw: float = float(layer.stat_draw_us) / maxi(layer.stat_draws, 1)
	check(per_draw < 10000.0, "drawing what is left costs %.0f us a frame (limit 10 ms; the old line pile-up cost about 5 draws a line)" % per_draw)
	var invaders := 0
	for id in screen.driver.tracks:
		invaders += screen.driver.tracks[id].invaders.size()
	var active: int = session.attacks.history.filter(func(a): return a.state == 1).size()
	check(invaders >= 20 and invaders <= active + 10, "and %d incoming enemies are being shown in the previews at the same time (%d attacks are ACTIVE)" % [invaders, active])
	check(img.get_width() == 1920, "(the whole screen rendered: %s)" % img.get_size())
