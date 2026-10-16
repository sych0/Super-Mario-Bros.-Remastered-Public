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

	await test_player_send(layout, game)
	await test_bot_send(layout, game)
	await test_incoming_in_preview(layout)
	await test_player_incoming(layout, game)
	await test_stress()

	if added_pack != "":
		packs.erase(added_pack)
	if root.size != original_window:
		root.size = original_window
		await frames(30)
	for key in saved_video:
		S.file.video[key] = saved_video[key]
	load("res://Scripts/Classes/Battle/BattleRound.gd").pre_round_override = -1.0
	var settings_out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle attack render test(s) failed" % failures)
	else:
		print("All Battle attack render tests passed")
	quit(1 if failures > 0 else 0)

func test_player_send(layout: Dictionary, game: Rect2) -> void:
	print("-- the real player's send")
	var base := await grab("attack_00_baseline")
	var target := alive_between(18, 34, 2)
	fixed_target(target)
	var a = session.report_enemy_defeat(0, KIND.GOOMBA)
	var flew: bool = await wait_flight(a.seq, 0.5)
	var img := await grab("attack_01_player_send")
	var view = screen.attack_view
	var f = view.flight_of(a.seq)
	check(flew and f != null and f.target == target, "the line is in the air towards the authoritative recipient (#%d)" % target)
	var pane: Rect2 = layout.slots[target - 1]
	check(changed_fraction(img, base, pane.grow(-2.0)) > 0.5, "that pane is marked: more than half its pixels changed (%.0f %%)" % [changed_fraction(img, base, pane.grow(-2.0)) * 100.0])
	var other: Rect2 = layout.slots[alive_between(1, 17, 5) - 1]
	check(changed_fraction(img, base, other.grow(-2.0)) < 0.2, "a pane that is not the target is not marked")
	# the line itself: sample along it, between the launch point and the head
	var from: Vector2 = GEO.launch_point(layout, 0, target)
	var to: Vector2 = GEO.landing_point(layout, 0, target)
	var e: float = f.eased(view.clock)
	var hits := 0
	for k in range(1, 9):
		var p := from.lerp(to, e * (0.3 + 0.07 * k))
		if diff(px(img, p.x, p.y), px(base, p.x, p.y)) > 0.12:
			hits += 1
	check(hits >= 6, "the line is drawn along the way from the game window to the pane (%d of 8 samples changed)" % hits)
	check(game.has_point(from) and not game.has_point(Vector2(from.x, 500)), "and it starts inside the game window")
	# everything of it is gone once the lines have landed
	await wait_lines_gone()
	var after := await grab()
	check(changed_fraction(after, base, pane.grow(-2.0)) < 0.3, "once it has landed and faded the pane is no longer marked")
	var ghost := 0
	for k in range(1, 9):
		var p := from.lerp(to, 0.1 * k)
		if not game.has_point(p) and diff(px(after, p.x, p.y), px(base, p.x, p.y)) > 0.2:
			ghost += 1
	check(ghost <= 1, "and no line is left on the screen (%d stray samples)" % ghost)

func test_bot_send(layout: Dictionary, game: Rect2) -> void:
	print("-- a bot's send")
	await wait_lines_gone()
	var base := await grab()
	var sender := alive_between(1, 17, 4)
	var target := alive_between(18, 34, 8)
	fixed_target(target)
	var a = session.report_enemy_defeat(sender, KIND.KOOPA)
	await wait_flight(a.seq, 0.6)
	var img := await grab("attack_02_bot_send")
	var view = screen.attack_view
	var f = view.flight_of(a.seq)
	check(f != null and f.sender == sender and f.target == target, "the line runs from bot #%d to bot #%d" % [sender, target])
	var pane: Rect2 = layout.slots[target - 1]
	check(changed_fraction(img, base, pane.grow(-2.0)) > 0.5, "the target pane is marked")
	var from: Vector2 = GEO.launch_point(layout, sender, target)
	var to: Vector2 = GEO.landing_point(layout, sender, target)
	var e: float = f.eased(view.clock)
	var span: Vector2 = GEO.inside_span(from, to, game)
	check(span.x < span.y, "(this line crosses the player's playfield)")
	var outside := 0.0
	var outside_n := 0
	var inside := 0.0
	var inside_n := 0
	for k in range(1, 40):
		var t := e * k / 40.0
		var p := from.lerp(to, t)
		var d := diff(px(img, p.x, p.y), px(base, p.x, p.y))
		if t >= span.x and t <= span.y:
			inside += d
			inside_n += 1
		elif t < span.x:
			outside += d
			outside_n += 1
	check(outside_n > 3 and inside_n > 3 and outside / outside_n > 0.12, "where it runs between the panes it is drawn clearly (mean change %.2f)" % (outside / maxi(outside_n, 1)))
	check(inside_n > 3 and inside / inside_n < outside / maxi(outside_n, 1) * 0.75 and inside / inside_n > 0.01, "and across the game window it is only faint (mean change %.2f against %.2f)" % [inside / maxi(inside_n, 1), outside / maxi(outside_n, 1)])
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
	check(pip.r > 0.9 and pip.g < 0.3 and pip.b < 0.3, "a red pip in the pane's corner counts the ACTIVE enemy (%s)" % pip.to_html(false))
	check(screen.panes[target - 1].incoming == Vector2i(0, 1), "(the pane's own count is 0 queued / 1 active)")
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
	check(pips == 3 and screen.panes[target - 1].incoming == Vector2i(0, 3), "three pips, one per ACTIVE enemy (%d)" % pips)
	# and it all ends with the attacks: Goomba at 5 s, Koopa at 7 s after activation
	advance(14)
	await frames(10)
	var img3 := await grab()
	check(track.invaders.is_empty() and screen.panes[target - 1].incoming == Vector2i.ZERO, "when the session resolves them the preview and the pane are clear")
	check(halo_pixels(img3, pane) <= halo_before + 60, "and the halos are gone from the picture")

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
	# the game window's frame lights up (red) while the attacks land on it
	var lit := 0
	for k in 6:
		var y: float = game.position.y + 30.0 + k * 30.0
		var c := px(img, game.position.x - 2.0, y)
		var b := px(base, game.position.x - 2.0, y)
		if b.g - c.g > 0.1:
			lit += 1
	check(lit >= 4, "the game window's frame lights up red while attacks land on it (%d of 6 samples)" % lit)
	var strip: Rect2 = layout.strip_a
	# four queued icons, all dim, in the strip
	var dim := 0
	for i in 4:
		var c := px(img, strip.position.x + 46.0 + 11.0 * i, strip.position.y + 5.5)
		if c.r < 0.7 and c.r > 0.3 and c.g < 0.4 and c.b < 0.3:
			dim += 1
	check(dim >= 3, "four attacks are four dim (QUEUED) icons in the incoming strip (%d dim)" % dim)
	check(screen.incoming_strip.counts == Vector2i(4, 0), "(the strip counts 4 queued / 0 active)")
	advance(3) # three go ACTIVE, the fourth waits
	await frames(1)
	var flash := await grab("attack_05_incoming_on_player_strip_flash")
	check(screen.incoming_strip.counts == Vector2i(1, 3), "the strip counts 1 queued / 3 active")
	var whitened := 0
	for i in 3:
		var c := px(flash, strip.position.x + 46.0 + 11.0 * i, strip.position.y + 5.5)
		if c.r > 0.9 and c.g > 0.32:
			whitened += 1
	check(whitened >= 2, "the icons that just became ACTIVE flash (%d of 3 whitened)" % whitened)
	await wait_lines_gone()
	await frames(60)
	var settled := await grab("attack_05_incoming_on_player_strip_settled")
	var lit_icons := 0
	for i in 3:
		var c := px(settled, strip.position.x + 46.0 + 11.0 * i, strip.position.y + 5.5)
		if c.r > 0.85 and c.g < 0.35 and c.b < 0.25:
			lit_icons += 1
	var dim_icon := px(settled, strip.position.x + 46.0 + 11.0 * 3, strip.position.y + 5.5)
	var empty := px(settled, strip.position.x + 46.0 + 11.0 * 5 + 3.0, strip.position.y + 5.5)
	var bar: Color = BS.STRIP_A_COLOR.lerp(Color(0.2, 0.09, 0.04), 0.92) # the strip's dark bar over its gold
	check(lit_icons == 3, "three lit (ACTIVE) icons once the flash has died down")
	check(dim_icon.r < 0.7 and dim_icon.r > 0.3 and dim_icon.g < 0.4, "and a dim one for the attack that is still queued (%s)" % dim_icon.to_html(false))
	check(diff(empty, bar) < 0.05, "and nothing after them (%s)" % empty.to_html(false))
	var text_px := 0
	for y in range(int(strip.position.y * shot_scale), int(strip.end.y * shot_scale)):
		for x in range(int((strip.end.x - 96.0) * shot_scale), int(strip.end.x * shot_scale)):
			if settled.get_pixel(x, y).get_luminance() > 0.8:
				text_px += 1
	check(text_px > 150, "the counts are written on the right of the strip (%d bright pixels)" % text_px)
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
	check(sent >= 12 and in_air >= sent - 2, "every one of %d simultaneous sends is a line in the air at once (%d lines)" % [sent, in_air])
	await frames(10)
	var per_draw: float = float(layer.stat_draw_us) / maxi(layer.stat_draws, 1)
	check(layer.stat_draws > 5 and per_draw < 10000.0, "recording all those lines costs %.0f us a frame (limit 10 ms)" % per_draw)
	var invaders := 0
	for id in screen.driver.tracks:
		invaders += screen.driver.tracks[id].invaders.size()
	var active: int = session.attacks.history.filter(func(a): return a.state == 1).size()
	check(invaders >= 20 and invaders <= active + 10, "and %d incoming enemies are being shown in the previews at the same time (%d attacks are ACTIVE)" % [invaders, active])
	check(img.get_width() == 1920, "(the whole screen rendered: %s)" % img.get_size())
