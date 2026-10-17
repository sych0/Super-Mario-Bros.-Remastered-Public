extends SceneTree
## Real bot worlds on the opponent panes, as pixels (doc 56): with one opponent playing a real game, its atlas cell is a
## crop of that game's own rendered screen (not a preview, not a placeholder), it changes as the bot plays, and its
## course-clear fade darkens it. Needs a real renderer:
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility \
##     --resolution 1920x1080 --fixed-fps 60 -s tests/battle_bot_render_test.gd -- out=/tmp/bot_pics
## `out=` saves the cell and the bot's screen as PNGs (never into the repository).

const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"

var failures := 0
var out_dir := ""
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
	DIRECTOR.count_override = -1
	ROUND.pre_round_override = -1.0
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
