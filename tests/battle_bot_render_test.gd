extends SceneTree
## Real bot worlds on the opponent panes, as pixels (doc 56): with one opponent playing a real game, its atlas cell is a
## crop of that game's own rendered screen (not a preview, not a placeholder), it changes as the bot plays, and its
## course-clear fade darkens it. Doc 57: after a real flagpole clear the cell is that world's real 1-2 screen (never the
## legacy previews' stand-in); and a real stomp of the real player and one of the real opponent each draw the same send ghost,
## seen leaving its sender (the game window, the opponent's pane) and bursting on the recipient's pane. Needs a real renderer:
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility \
##     --resolution 1920x1080 --fixed-fps 60 -s tests/battle_bot_render_test.gd -- out=/tmp/bot_pics
## `out=` saves the cell and the bot's screen as PNGs (never into the repository).

const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const LEVEL_1_2 := "res://Scenes/Levels/SMB1/World1/1-2.tscn"
const GOOMBA_PREFAB := "res://Scenes/Prefabs/Entities/Enemies/Goomba.tscn"
const KOOPA_PREFAB := "res://Scenes/Prefabs/Entities/Enemies/GreenKoopaTroopa.tscn"
const RECIPIENT := 9
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 9
func choose(session, sender, _draw) -> int:
	if sender != target:
		return target
	for c in session.contestants:
		if c.alive and c.id != sender:
			return c.id
	return -1
"""

var failures := 0
var out_dir := ""
var bot_ground_y := 0.0 ## the ground the opponent's Mario stood on at 1-1's start
var G
var S
var BS
var ROUND
var DIRECTOR
var ATLAS

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

func on_title() -> bool:
	return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("out="):
			out_dir = a.substr(4)
	_run()

## The cell of opponent 1 in the atlas, as an image.
func cell_image(scr) -> Image:
	var img: Image = scr.atlas.get_texture().get_image()
	return img.get_region(ATLAS.cell_rect(0))

## Distinct colours and how much of the picture is the overworld's sky (blue).
func stats(img: Image) -> Dictionary:
	var colours := {}
	var sky := 0
	var red := 0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			colours[c.to_html(false)] = true
			if c.b > 0.7 and c.r < 0.6 and c.g > 0.4:
				sky += 1
			if c.r > 0.6 and c.g < 0.35 and c.b < 0.3:
				red += 1
			n += 1
	return {"colours": colours.size(), "sky": float(sky) / n, "red": red}

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = root.get_node("Settings")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	ROUND = load("res://Scripts/Classes/Battle/BattleRound.gd")
	DIRECTOR = load("res://Scripts/Classes/Battle/BattleBotDirector.gd")
	ATLAS = load("res://Scripts/Classes/Battle/BattlePreviewAtlas.gd")
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR)
	ROUND.pre_round_override = 0.3
	DIRECTOR.count_override = 1
	var HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	HANDLER.seed_source = func() -> int: return 11 # (the same round every run)
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return on_title(), 900)
	current_scene.start_battle()
	await wait_until(func(): return BS.is_active() and BS.instance.bots != null and BS.instance.battle_round.state == ROUND.State.PLAYING, 1500)
	var scr = BS.instance
	var w = scr.bots.world(1)
	await frames(30)
	var screen: Image = w.viewport.get_texture().get_image()
	var st_screen := stats(screen)
	check(screen.get_size() == Vector2i(256, 240) and st_screen.colours > 8, "the bot's own 256x240 screen is rendered (%d colours)" % st_screen.colours)
	var cell := cell_image(scr)
	var st := stats(cell)
	check(st.colours > 8 and st.sky > 0.2, "opponent 1's cell is its real 1-1: %d colours, %.0f%% overworld sky" % [st.colours, st.sky * 100.0])
	check(st.red > 0, "the bot's Mario is on it (%d red samples)" % st.red)
	if out_dir != "":
		DirAccess.make_dir_recursive_absolute(out_dir)
		screen.save_png(out_dir.path_join("bot1_screen.png"))
		cell.save_png(out_dir.path_join("bot1_cell.png"))
	await wait_until(func(): return w.player.is_on_floor(), 120)
	bot_ground_y = w.player.global_position.y
	var x0: float = w.player.global_position.x
	await frames(120)
	var cell2 := cell_image(scr)
	var differs := 0
	for y in range(0, cell.get_height(), 3):
		for x in range(0, cell.get_width(), 3):
			if not cell.get_pixel(x, y).is_equal_approx(cell2.get_pixel(x, y)):
				differs += 1
	check(differs > 50 and w.player.global_position.x != x0, "the cell follows the bot's game as it plays (%d samples changed)" % differs)
	if out_dir != "":
		cell2.save_png(out_dir.path_join("bot1_cell_later.png"))
	w.fade = 1.0 # (as on the last frames of a course-clear cut)
	scr.cells[0]._process(0.0)
	await frames(3)
	var dark := cell_image(scr)
	var lum := 0.0
	for y in range(0, dark.get_height(), 4):
		for x in range(0, dark.get_width(), 4):
			lum += dark.get_pixel(x, y).get_luminance()
	check(lum / ((dark.get_height() / 4) * (dark.get_width() / 4)) < 0.05, "the course-clear fade blackens the cell")
	w.fade = 0.0
	await test_send_ghosts(scr, w)
	await test_next_course(scr, w)
	DIRECTOR.count_override = -1
	ROUND.pre_round_override = -1.0
	HANDLER.seed_source = Callable()
	load("res://Scripts/Classes/Battle/BattleHandler.gd").quit_battle()
	await wait_until(func(): return on_title(), 900)
	var out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	out.store_string(saved_settings_file)
	out.close()
	if failures > 0:
		printerr("%d Battle bot render test(s) failed" % failures)
	else:
		print("All Battle bot render tests passed")
	quit(1 if failures > 0 else 0)

# ---- doc 57: the same send ghost for the real player's stomp and a real opponent's ------------------------------------------------

## Drops `prefab` on the ground `dx` px ahead of `mario` in `level`, puts `mario` clear above it (over its head: a Koopa is taller than
## a Goomba), falling: the game's own stomp follows.
func physical_stomp(level: Node, mario, prefab: String, dx: float) -> Node:
	var e: Node2D = load(prefab).instantiate()
	e.position = Vector2(mario.global_position.x + dx, mario.global_position.y)
	level.add_child(e)
	await frames(3)
	mario.global_position = e.global_position + Vector2(0, -48 if prefab == KOOPA_PREFAB else -30)
	mario.velocity = Vector2(0, 60)
	return e

## The ghost of the newest SENT from `sender`, or {}.
func newest_ghost(scr, sender: int) -> Dictionary:
	var out := {}
	for g in scr.attack_view.send_ghosts():
		if int(g.sender) == sender:
			out = g
	return out

## The age of the ghost of send `seq`, or -1 once it is gone.
func ghost_age(scr, seq: int) -> float:
	for x in scr.attack_view.send_ghosts():
		if int(x.seq) == seq:
			return float(x.age)
	return -1.0

## With the game paused, the canvas with the ghost layer, without it, and with it again: how many pixels of `rect` (canvas units) the
## layer changes, and their centre (canvas units). A pixel that differs between the two captures with the layer is something that moves
## on its own while paused (a score note of the real game) and is not counted.
func layer_pixels(scr, rect: Rect2, tag: String) -> Dictionary:
	await frames(2)
	var shown: Image = root.get_texture().get_image()
	scr.ghost_layer.visible = false
	await frames(2)
	var hidden: Image = root.get_texture().get_image()
	scr.ghost_layer.visible = true
	await frames(2)
	var again: Image = root.get_texture().get_image()
	var k := float(shown.get_width()) / 480.0
	var n := 0
	var sum := Vector2.ZERO
	var r := Rect2i(Vector2i(rect.position * k), Vector2i(rect.size * k)).intersection(Rect2i(Vector2i.ZERO, shown.get_size()))
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var a := shown.get_pixel(x, y)
			var b := hidden.get_pixel(x, y)
			var c := again.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.12 and a.is_equal_approx(c):
				n += 1
				sum += Vector2(x, y)
	if out_dir != "":
		shown.save_png(out_dir.path_join("ghost_%s.png" % tag))
	return {"pixels": n, "centre": sum / maxf(n, 1) / k}

## Stomps an enemy of `prefab` with `mario` (the real player's or the opponent's) and checks the ghost on the canvas: seen leaving the
## sender's own window (`from_rect`) a few frames in, and its burst on the recipient's pane at 0.5 s. Returns {leaving, burst} pixels.
func ghost_on_canvas(scr, level: Node, mario, sender: int, prefab: String, label: String, from_rect: Rect2) -> Dictionary:
	var before: int = scr.attack_view.send_ghosts().size()
	var seq0 := int(newest_ghost(scr, sender).get("seq", -1))
	var got := false
	for attempt in 3: # (a drop can miss: the enemy may have turned and walked off before Mario lands)
		await physical_stomp(level, mario, prefab, 40.0)
		got = await wait_until(func(): return int(newest_ghost(scr, sender).get("seq", -1)) != seq0, 120)
		if got:
			break
	check(got, "%s: the stomp is a send (its SENT has a ghost)" % label)
	if not got:
		return {}
	var g := newest_ghost(scr, sender)
	await wait_until(func(): return float(newest_ghost(scr, sender).get("age", 0.0)) >= 3.0 / 60.0, 30)
	paused = true
	g = newest_ghost(scr, sender)
	var layout: Dictionary = scr.layout
	var expect: Vector2 = load("res://Scripts/Classes/Battle/BattleSendGhost.gd").point(layout, sender, RECIPIENT,
		load("res://Scripts/Classes/Battle/BattleSendGhost.gd").progress(float(g.age)))
	var leaving := await layer_pixels(scr, from_rect, label.replace(" ", "_").replace("'", "") + "_leaving")
	check(leaving.pixels > 40 and (leaving.centre as Vector2).distance_to(expect) < 4.0,
		"%s: its ghost is seen leaving its sender (%d pixels in %s, centred at %s, expected %s)" % [label, leaving.pixels,
		"the game window" if sender == 0 else "its pane", leaving.centre.round(), expect.round()])
	paused = false
	var seq := int(g.seq)
	await wait_until(func(): return ghost_age(scr, seq) < 0.0 or ghost_age(scr, seq) >= 0.5 + 1.0 / 60.0, 60)
	paused = true
	var pane: Rect2 = layout.slots[RECIPIENT - 1]
	var burst := await layer_pixels(scr, pane, label.replace(" ", "_").replace("'", "") + "_burst")
	check(burst.pixels > 40 and (burst.centre as Vector2).distance_to(pane.get_center()) < 3.0,
		"%s: and bursts on the recipient's pane at 0.5 s (%d pixels, centred at %s)" % [label, burst.pixels, burst.centre.round()])
	paused = false
	await frames(30)
	return {"leaving": leaving.pixels, "burst": burst.pixels}

func test_send_ghosts(scr, w) -> void:
	print("-- the real player's and a real opponent's stomps: the same send ghost, seen from each sender")
	var fixed := GDScript.new()
	fixed.source_code = FIXED_SOURCE
	fixed.reload()
	scr.session.attacks.bots_send = false
	scr.session.attacks.targeting = fixed.new()
	var human = G.current_level.get_node("Player")
	human.can_hurt = false
	w.script_buttons = func(_w) -> Dictionary: return {} # (the opponent's Mario stands still for its stomps)
	w.player.can_hurt = false
	await frames(10)
	var layout: Dictionary = scr.layout
	var results := {}
	for pair in [[GOOMBA_PREFAB, "Goomba"], [KOOPA_PREFAB, "Koopa"]]:
		results["human " + pair[1]] = await ghost_on_canvas(scr, G.current_level, human, 0, pair[0], "real player's %s" % pair[1], layout.game)
		results["bot " + pair[1]] = await ghost_on_canvas(scr, w.level, w.player, 1, pair[0], "real opponent's %s" % pair[1], layout.slots[0])
	for kind in ["Goomba", "Koopa"]:
		var h: Dictionary = results.get("human " + kind, {})
		var b: Dictionary = results.get("bot " + kind, {})
		if not h.is_empty() and not b.is_empty():
			check(absf(h.burst - b.burst) <= maxf(h.burst, b.burst) * 0.15,
				"%s: the real player's burst and the opponent's are the same picture (%d / %d pixels)" % [kind, h.burst, b.burst])
	w.script_buttons = Callable()
	if is_instance_valid(w.player):
		w.player.can_hurt = true

# ---- doc 57: the real next course on the pane ----------------------------------------------------------------------------------------

func test_next_course(scr, w) -> void:
	print("-- the real opponent clears 1-1: its pane is its own real 1-2")
	if not is_instance_valid(w.player) or w.phase != w.Phase.PLAYING:
		check(false, "the opponent is still playing 1-1 (it is %s)" % [w.Phase.keys()[w.phase]])
		return
	# On 1-1's ground (the y its Mario started on), just before the pole, protected from what the stomps above left lying about.
	w.player.can_hurt = false
	w.player.global_position = Vector2(w._goal_x - 46.0, bot_ground_y)
	w.player.velocity = Vector2.ZERO
	w.script_buttons = func(ww) -> Dictionary: return {"move_right": true, "jump": ww.ticks % 40 < 25}
	var entered: bool = await wait_until(func(): return w.course == 1, 600)
	w.script_buttons = Callable()
	check(entered and w.level.scene_file_path == LEVEL_1_2, "it rode the real flagpole into the real 1-2 (%s)" % [w.describe()])
	if not entered:
		return
	await frames(40)
	var screen: Image = w.viewport.get_texture().get_image()
	var cell := cell_image(scr)
	var crop := screen.get_region(Rect2i(load("res://Scripts/Classes/Battle/BattleBotWorld.gd").PANE_CROP))
	crop.resize(cell.get_width(), cell.get_height(), Image.INTERPOLATE_NEAREST)
	var same := 0
	var n := 0
	for y in range(0, cell.get_height(), 2):
		for x in range(0, cell.get_width(), 2):
			n += 1
			if cell.get_pixel(x, y).is_equal_approx(crop.get_pixel(x, y)):
				same += 1
	check(float(same) / n > 0.85, "its cell is its world's own 1-2 screen, cropped (%.0f%% of the pixels the same)" % (100.0 * same / n))
	var st := stats(cell)
	check(st.sky < 0.02, "an underground picture, not 1-1's sky or the 3-2 stand-in's (%.1f%% sky)" % (st.sky * 100.0))
	check(scr.cells[0].last_source.get("kind") == "world" and scr.cells[0].last_source.get("course") == 1 and not scr.driver.tracks.has(1),
		"drawn from its world on course 1; no legacy preview has it")
	if out_dir != "":
		cell.save_png(out_dir.path_join("bot1_cell_1-2.png"))
		screen.save_png(out_dir.path_join("bot1_screen_1-2.png"))
