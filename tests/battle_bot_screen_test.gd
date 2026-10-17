extends SceneTree
## Real bot worlds inside the Battle screen (doc 56), with the real player's game running: opponents 1 and 2 play the real
## game (BattleBotDirector.count_override = 2), 3..34 keep the previews. Checks the wiring and that the real player's game
## is the same game it always was:
##   - the session marks 1 and 2 world-driven before its first tick; the screen's director holds their worlds; their cells
##     show their games; the preview driver has tracks for 3..34 only;
##   - the worlds stand still through the pre-round and play from GO;
##   - the real player's level is the real 1-1 in the game window and Global's current level; the window's camera follows the
##     real Mario, never a bot; the bots' kills, coins and blocks never reach the real score, coins or level record;
##   - a bot that dies is a KO card on its pane after its animation; the course label follows the bot's own course;
##   - the round ending stops the worlds where they are; the next round has fresh worlds; Quit leaves none behind.
##   godot --headless --fixed-fps 60 --path . -s tests/battle_bot_screen_test.gd
## Script classes that mention autoloads are only reached through load() (a `-s` script is compiled before the autoloads exist).

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const TITLE := "res://Scenes/Levels/TitleScreen.tscn"

var failures := 0
var G
var S
var BS
var HANDLER
var SESSION
var ROUND
var DIRECTOR
var WORLD
var GW

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

func state() -> int:
	return BS.instance.battle_round.state

func player() -> Node2D:
	return G.current_level.get_node_or_null("Player") if is_instance_valid(G.current_level) else null

func level_running() -> bool:
	return BS.is_active() and not G.transitioning_scene and is_instance_valid(G.current_level) \
		and G.current_level.scene_file_path == LEVEL_1_1 and G.current_level.get_parent() == BS.instance.game_viewport and player() != null

func on_title() -> bool:
	return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = root.get_node("Settings")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	ROUND = load("res://Scripts/Classes/Battle/BattleRound.gd")
	DIRECTOR = load("res://Scripts/Classes/Battle/BattleBotDirector.gd")
	WORLD = load("res://Scripts/Classes/Battle/BattleBotWorld.gd")
	GW = load("res://Scripts/Classes/GameWorld.gd")
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR)
	ROUND.pre_round_override = 0.5
	DIRECTOR.count_override = 2

	await test_round()

	DIRECTOR.count_override = -1
	ROUND.pre_round_override = -1.0
	var out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	out.store_string(saved_settings_file)
	out.close()
	if failures > 0:
		printerr("%d Battle bot screen test(s) failed" % failures)
	else:
		print("All Battle bot screen tests passed")
	quit(1 if failures > 0 else 0)

func test_round() -> void:
	print("-- Battle with two real-game opponents")
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return on_title(), 900)
	current_scene.start_battle()
	var up: bool = await wait_until(func(): return level_running() and state() != ROUND.State.LOADING and BS.instance.bots != null, 1500)
	check(up, "Battle runs the real 1-1 in the game window and the screen made its real-game opponents")
	var scr = BS.instance
	var session = SESSION.current
	check(session.contestants[1].world_driven and session.contestants[2].world_driven and not session.contestants[3].world_driven, "the session marks opponents 1 and 2 (and only them) as playing a real game")
	var w1 = scr.bots.world(1)
	var w2 = scr.bots.world(2)
	check(w1 != null and w2 != null and scr.bots.worlds.size() == 2, "the director holds their two worlds")
	check(scr.cells[0].bot == w1 and scr.cells[1].bot == w2 and scr.cells[2].bot == null, "cells 1 and 2 show their real games; cell 3 does not")
	check(scr.driver != null and not scr.driver.tracks.has(1) and not scr.driver.tracks.has(2) and scr.driver.tracks.has(3) and scr.driver.tracks.size() == 32, "the preview driver keeps tracks for 3..34 only")
	check(w1.level.scene_file_path == LEVEL_1_1 and w1.player != player() and w1.player.get_viewport() != scr.game_viewport, "each bot plays its own 1-1, not in the game window")
	check(G.current_level.get_parent() == scr.game_viewport, "Global.current_level is the real player's level")
	# The pre-round holds everyone.
	if state() == ROUND.State.PRE_ROUND:
		var x0: float = w1.player.global_position.x
		await frames(10)
		check(state() != ROUND.State.PRE_ROUND or is_equal_approx(w1.player.global_position.x, x0), "the bots stand still through the pre-round")
	await wait_until(func(): return state() == ROUND.State.PLAYING, 600)
	var start_x: float = w1.player.global_position.x
	var score0: int = G.score
	var coins0: int = G.coins
	var cam_follows_real := true
	var bot_moved := false
	for f in 360:
		await process_frame
		var cam: Camera2D = scr.game_viewport.get_camera_2d()
		if cam == null or player() == null or absf(cam.get_screen_center_position().x - player().global_position.x) > 160.0:
			cam_follows_real = false
	bot_moved = w1.player.global_position.x > start_x + 200.0 or w2.player.global_position.x > start_x + 200.0 or not session.contestants[1].alive
	check(bot_moved, "the bots play once the round is on (bot 1 x %.0f -> %.0f)" % [start_x, w1.player.global_position.x])
	check(cam_follows_real, "the game window's camera follows the real Mario all along (never a bot's)")
	check(G.score == score0 and G.coins == coins0, "the bots' kills and coins never reach the real score or coins (score %d, coins %d)" % [G.score, G.coins])
	check(scr.cells[0].course_index() == w1.course, "the pane's course is the bot's own course")
	# A bot's death: a KO, then its card.
	if session.contestants[2].alive:
		w2.player.global_position.y = 70.0 # (a test shortcut: into the pit)
	await wait_until(func(): return not session.contestants[2].alive, 30)
	check(not session.contestants[2].alive, "bot 2's death in its game is its KO in the session")
	await wait_until(func(): return scr.cells[1].marked(), 240)
	check(scr.cells[1].marked() and w2.ko_shown, "after its death animation its pane is marked for the KO card")
	check(not paused and G.current_level.get_parent() == scr.game_viewport, "the real game was not paused or replaced by it")
	# The round ends (the real player is out): the worlds stop where they are.
	session.report_ko(0, SESSION.KoCause.HAZARD)
	scr.round_over(ROUND.End.DEATH)
	await wait_until(func(): return scr.field_frozen, 300)
	var held_x: float = w1.player.global_position.x
	await frames(30)
	check(scr.bots.stopped and w1.process_mode == Node.PROCESS_MODE_DISABLED and is_equal_approx(w1.player.global_position.x, held_x), "at the round's end the bots' games stop where they are")
	# The next round: fresh worlds for its own session.
	scr._start_next_round()
	var fresh: bool = await wait_until(func(): return SESSION.current != session and scr.bots != null and scr.bots.session == SESSION.current and level_running(), 1500)
	await frames(3)
	check(fresh and not is_instance_valid(w1) and not is_instance_valid(w2) and scr.bots.worlds.size() == 2 and scr.cells[0].bot == scr.bots.world(1), "the next round has fresh real games for its own session; the old ones are gone")
	# Quit: nothing is left.
	HANDLER.quit_battle()
	await wait_until(func(): return on_title(), 900)
	await frames(5)
	check(GW.bot_worlds == 0, "after Quit no bot world is left (%d)" % GW.bot_worlds)
