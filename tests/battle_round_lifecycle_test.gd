extends SceneTree
## The Battle round lifecycle against the real project (doc 38, milestone 3): real levels run inside
## BattleScreen's GameViewport and the real Player dies, runs out of time and wins. Checks that a round
## ending (death, timeout, win) always leads to the results and then to a fresh round in the SAME
## BattleScreen, that the title / GameOver / TimeUp scenes are never loaded on the way, that only an
## explicit Quit returns to the title, that the pre-round freezes gameplay and the Battle clock, that the
## player's KO is registered at the moment of death, that five rounds in a row do not leak, and that
## Classic death / game over / time up behave exactly as before.
##   godot --headless --fixed-fps 60 --path . -s tests/battle_round_lifecycle_test.gd
## (Every frame is one 1/60 s step, so it is deterministic.) Script classes that mention autoloads are
## only reached through load(): a `-s` script is compiled before the autoloads exist.

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const GAME_OVER := "res://Scenes/Levels/GameOver.tscn"
const TIME_UP := "res://Scenes/Levels/TimeUp.tscn"
const FORBIDDEN := [TITLE, GAME_OVER, TIME_UP]

var failures := 0
var G
var S
var BS
var HANDLER
var SESSION
var ROUND
var LV
var seen: Array[String] = [] ## every scene BattleScreen loaded into the game window
var scene_changes := 0
var seeds: Array[int] = [] ## the seeds handed out by the scripted seed source
var seed_counter := [1000]
var classic_orphans_per_load := 0 ## orphan nodes one Classic LevelTransition -> 1-1 load leaves behind (the game's own)

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

func screen():
	return BS.instance

func rnd():
	return BS.instance.battle_round

func state() -> int:
	return BS.instance.battle_round.state

func session():
	return SESSION.current

## A round's level is in the game window with Mario in it.
func level_running() -> bool:
	return BS.is_active() and not G.transitioning_scene and is_instance_valid(G.current_level) \
		and G.current_level.scene_file_path == LEVEL_1_1 and G.current_level.get_parent() == BS.instance.game_viewport and player() != null

func on_title() -> bool:
	return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene

func window_state() -> Dictionary:
	var v: Dictionary = S.file.video
	return {"scale_size": root.content_scale_size, "aspect": root.content_scale_aspect, "mode": root.content_scale_mode,
		"stretch": root.content_scale_stretch, "video": [v.size, v.scaling, v.visuals], "hud_offset": G.get_node("GameHUD").offset}

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
	LV = load("res://Scripts/Classes/LevelClass.gd")
	scene_changed.connect(func(): scene_changes += 1)
	var saved_video: Dictionary = S.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR) # the game saves it on every window change
	S.get_node("Apply/Video").set_value("size", 0)
	S.get_node("Apply/Video").set_value("scaling", 0)
	await frames(2)
	var window_before := window_state()
	ROUND.pre_round_override = 0.5 # a short but real countdown
	HANDLER.seed_source = func() -> int:
		seed_counter[0] += 7
		seeds.append(seed_counter[0])
		return seed_counter[0]

	await measure_classic_orphans()
	await start_battle()
	await test_pre_round_freezes()
	await test_death_round()
	await test_results_field_frozen()
	await test_timeout_round()
	await test_win_round()
	await test_results_input()
	await test_pause_holds_round_timers()
	await test_never_left_battle()
	await test_five_rounds()
	await test_quit(window_before)
	await test_classic()

	HANDLER.seed_source = Callable()
	ROUND.pre_round_override = -1.0
	for key in saved_video:
		S.file.video[key] = saved_video[key]
	var settings_out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle round lifecycle test(s) failed" % failures)
	else:
		print("All Battle round lifecycle tests passed")
	quit(1 if failures > 0 else 0)

func orphan_count() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))

## What the game itself leaves behind per level load, in Classic, for comparison with Battle's rounds.
func measure_classic_orphans() -> void:
	print("-- baseline: orphan nodes per Classic level load")
	var counts: Array[int] = []
	for i in 4:
		G.current_campaign = "SMB1"
		G.current_game_mode = G.GameMode.CAMPAIGN
		G.clear_saved_values()
		G.world_num = 1
		G.level_num = 1
		G.reset_values()
		LV.first_load = true
		PipeCutsceneReset()
		load("res://Scripts/Parts/LevelTransition.gd").level_to_transition_to = LEVEL_1_1
		G.transition_to_scene("res://Scenes/Levels/LevelTransition.tscn")
		await wait_until(func(): return current_scene != null and current_scene.scene_file_path == LEVEL_1_1 and not G.transitioning_scene and player() != null, 1500)
		await frames(40)
		counts.append(orphan_count())
	classic_orphans_per_load = maxi(counts[3] - counts[2], counts[2] - counts[1])
	print("   orphans after each Classic load: ", counts, " -> %d per load" % classic_orphans_per_load)
	G.current_game_mode = G.GameMode.NONE

func PipeCutsceneReset() -> void:
	load("res://Scripts/Parts/PipeCutscene.gd").seen_cutscene = false

# ---- helpers: rounds ------------------------------------------------------------------------------

## From the title: the real "Battle" start. Leaves round 1 in its pre-round.
func start_battle() -> void:
	print("-- starting Battle from the title")
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return on_title(), 900)
	current_scene.start_battle()
	var up: bool = await wait_until(func(): return level_running() and state() != ROUND.State.LOADING, 1500)
	check(up, "round 1: Battle starts, 1-1 is in the game window and the pre-round has begun")
	BS.instance.game_scene_changed.connect(func(scene): seen.append(scene.scene_file_path))
	seen.append(G.current_level.scene_file_path)

## Waits for the pre-round to release into PLAYING.
func play() -> void:
	await wait_until(func(): return state() == ROUND.State.PLAYING and level_running(), 600)
	await frames(2)

## Dismisses the results (as the timeout would) and waits for the next round's pre-round.
func next_round() -> void:
	var n: int = rnd().round_number
	rnd().time_in_state = ROUND.RESULTS_MAX_SECONDS
	await wait_until(func(): return rnd().round_number == n + 1 and level_running() and state() != ROUND.State.LOADING, 1800)

func results_up() -> bool:
	return await wait_until(func(): return state() == ROUND.State.RESULTS, 1500)

# ---- pre-round ------------------------------------------------------------------------------------

func test_pre_round_freezes() -> void:
	print("-- PRE_ROUND freezes gameplay and the Battle clock")
	var scr = screen()
	check(state() == ROUND.State.PRE_ROUND and rnd().frozen(), "round 1 is in PRE_ROUND")
	check(scr.game_viewport.process_mode == Node.PROCESS_MODE_DISABLED and scr.game_frozen, "the game window is frozen")
	check(scr._banner.visible and scr._banner.text == "READY", "READY is showing")
	# the real match-start sequence (doc 47 B35-RESULT-001) runs at its documented length; this suite shortens the pre-round,
	# so the round is told the full length here and its clock is set to each probe (the screen shows what the round says)
	var short_length: float = rnd().pre_round_seconds
	rnd().pre_round_seconds = ROUND.PRE_ROUND_SECONDS
	for probe in [[0.3, "HERE WE GO..."], [1.0, "READY"], [2.6, "3"], [3.6, "2"], [4.6, "1"]]:
		rnd().time_in_state = probe[0]
		await frames(2)
		check(state() == ROUND.State.PRE_ROUND and scr._banner.visible and scr._banner.text == probe[1] and scr._banner.size == scr.layout.game.size, "%.1f s into the pre-round the window says %s" % [probe[0], probe[1]])
	var held: float = rnd().time_in_state
	G.game_paused = true
	await frames(40)
	check(is_equal_approx(rnd().time_in_state, held) and scr._banner.text == "1" and is_equal_approx(scr._banner.age, scr._banner.age), "the pause menu holds the countdown on its word (%.2f s)" % rnd().time_in_state)
	var banner_age: float = scr._banner.age
	await frames(10)
	check(is_equal_approx(scr._banner.age, banner_age), "...and its pop animation")
	G.game_paused = false
	rnd().pre_round_seconds = short_length
	rnd().time_in_state = 0.0
	check(scr.game_frozen and scr.game_viewport.process_mode == Node.PROCESS_MODE_DISABLED, "(the window stayed frozen through all of it)")
	var p := player()
	var x0 := p.global_position.x
	var ticks0: int = session().tick_count
	var time0: int = G.time
	var cam0: Vector2 = scr.game_viewport.get_camera_2d().get_screen_center_position()
	Input.action_press("move_right_0")
	await frames(20)
	Input.action_release("move_right_0")
	check(state() == ROUND.State.PRE_ROUND, "(still in the pre-round after 20 frames)")
	check(is_equal_approx(p.global_position.x, x0), "gameplay is frozen: Mario does not move with the stick held (%.2f -> %.2f)" % [x0, p.global_position.x])
	check(session().tick_count == ticks0 and session().tick_count == 0, "the Battle simulation is frozen (tick %d)" % session().tick_count)
	check(G.time == time0, "the game's own timer is frozen too (%d)" % G.time)
	check(cam0.y > -208.0 and cam0.y < 32.0 and absf(cam0.x) < 400.0, "the frozen picture is 1-1's start, not a first-frame default (camera %s)" % cam0)
	await play()
	check(state() == ROUND.State.PLAYING and not scr.game_frozen and scr.game_viewport.process_mode == Node.PROCESS_MODE_PAUSABLE, "PLAYING releases the game window")
	check(scr._banner.visible and scr._banner.text == "GO!", "GO! shows as play is released")
	var cam1: Vector2 = scr.game_viewport.get_camera_2d().get_screen_center_position()
	check(cam1.distance_to(cam0) < 8.0, "the camera did not jump on release (%s -> %s)" % [cam0, cam1])
	var x1 := p.global_position.x
	Input.action_press("move_right_0")
	await frames(70)
	Input.action_release("move_right_0")
	check(p.global_position.x > x1 + 20.0, "gameplay resumes: Mario moves (%.1f -> %.1f)" % [x1, p.global_position.x])
	check(session().tick_count >= 1, "the Battle simulation resumes (tick %d)" % session().tick_count)
	check(G.time < time0 or session().tick_count >= 1, "the clock runs again")

# ---- player KO -> ROUND_OVER -> RESULTS -> next round ----------------------------------------------------

func test_death_round() -> void:
	print("-- player death")
	var scr = screen()
	var round_no: int = rnd().round_number
	var old = session()
	var old_ref: WeakRef = weakref(old)
	var old_seed: int = old.seed_value
	var changes_before := scene_changes
	var alive_before: int = old.alive_count
	var tick_before: int = old.tick_count
	player().die()
	# the KO is registered at the moment of death, not when the death music ends
	check(not old.get_player().alive and old.get_player().ko_cause == SESSION.KoCause.HAZARD, "the player's KO is registered the instant they die")
	check(old.get_player().placement == alive_before and old.get_player().ko_tick == tick_before, "...with the placement and tick of that moment (place %d at tick %d)" % [old.get_player().placement, old.get_player().ko_tick])
	check(state() == ROUND.State.ROUND_OVER and rnd().end_cause == ROUND.End.DEATH, "the round is over (death) while the death animation still plays")
	check(not scr.showing_result, "the results wait for the death animation")
	var ko_events: int = old.events.filter(func(e): return e.id == 0 and e.type == SESSION.EventType.KO).size()
	HANDLER.on_player_died()
	HANDLER.on_player_died()
	player().die()
	check(ko_events == 1 and old.events.filter(func(e): return e.id == 0 and e.type == SESSION.EventType.KO).size() == 1, "the player's KO is logged once")
	check(old.get_player().placement == alive_before and rnd().history.count(ROUND.State.ROUND_OVER) == 1, "a duplicate KO cannot change the placement or re-end the round")
	var ticks_during: int = old.tick_count
	await frames(30)
	check(old.tick_count == ticks_during and not old.finished, "the bots wait while the death animation plays")
	var got: bool = await results_up()
	check(got, "the death animation finishes and the RESULTS come up")
	check(old.finished and old.winner_id >= 0 and old.get_player().placement == alive_before, "the rest of the ranking was resolved, the player's own placement unchanged (place %d)" % old.get_player().placement)
	var places := {}
	for c in old.contestants:
		places[c.placement] = true
	check(places.size() == 35, "35 distinct placements in the finished round")
	check(scr._overlay.visible and scr._overlay_label.text.contains("PLACED %d" % alive_before) and scr._overlay_label.text.contains("OUT BY: HAZARD") and scr._overlay_label.text.contains("LEVELS CLEARED: 0") and scr._overlay_label.text.contains("WINNER: #") and scr._overlay_label.text.contains("OPPONENTS LEFT") and scr._overlay_label.text.contains("NEXT ROUND"), "the results show placement, cause, winner, levels cleared and opponents left")
	check(current_scene == scr and not G.transitioning_scene, "still in the Battle screen: no scene change on the way to the results")
	# next round
	await next_round()
	var fresh = session()
	check(rnd().round_number == round_no + 1 and screen() == scr and current_scene == scr, "the next round runs in the SAME BattleScreen")
	check(fresh != old and fresh.seed_value != old_seed and fresh.seed_value == seeds[-1], "a fresh BattleSession with a new seed (%d -> %d)" % [old_seed, fresh.seed_value])
	check(fresh.contestants.size() == 35 and fresh.alive_count == 35 and fresh.tick_count == 0 and not fresh.finished and fresh.winner_id == -1, "35 fresh contestants, tick 0, not finished")
	check(fresh.contestants.all(func(c): return c.alive and c.placement == 0 and c.ko_tick == -1 and c.levels_cleared == 0 and c.ko_cause == SESSION.KoCause.NONE and c.time_left == SESSION.START_TIME), "no KO, order, placement or progress carried over")
	check(fresh.events.is_empty(), "the event log is empty")
	check(G.current_game_mode == G.GameMode.BATTLE, "game mode is still Battle")
	check(G.world_num == 1 and G.level_num == 1 and G.current_level.scene_file_path == LEVEL_1_1, "World 1-1 again")
	check(not paused and not player().is_dead and G.time == SESSION.START_TIME, "the game is unpaused with a live Mario and the full Battle timer (time %d)" % G.time)
	check(state() == ROUND.State.PRE_ROUND and scr.game_frozen, "the next round starts with a PRE_ROUND")
	check(not scr._overlay.visible, "the results card is gone")
	check(scene_changes == changes_before, "no scene change: the title was never loaded (%d scene changes)" % (scene_changes - changes_before))
	await play()
	await frames(5)
	old = null # the test's own reference
	check(old_ref.get_ref() == null, "the previous round's BattleSession is gone")
	check(scr.driver != null and scr.driver.session == fresh and scr.cells.filter(func(c): return c.is_live()).size() == 34, "the previews follow the fresh session (34 live)")

# ---- the match field under the results (doc 51) ------------------------------------------------------------

## Everything the panes show, as plain values: for every opponent the picture's state and whether it is a KO card, the alive badge,
## the timer, the order and place of the panes.
func field_snapshot() -> Dictionary:
	var scr = screen()
	var sigs := PackedStringArray()
	var marked := []
	var places := []
	for i in scr.cells.size():
		sigs.append(scr.cells[i].frame.signature() if scr.cells[i].frame != null else "-")
		if scr.panes[i].marked:
			marked.append(scr.panes[i].contestant_id)
		places.append([scr.panes[i].contestant_id, scr.panes[i].position, scr.panes[i].size])
	return {"pictures": hash("|".join(sigs)), "marked": marked, "places": places, "badge": scr.badge_alive.value, "time": scr.hud.time_left,
		"live": scr.cells.filter(func(c): return c.is_live()).size(), "valid": scr.cells.filter(func(c): return c.frame != null and c.frame.valid).size(),
		"placements": scr.panes.map(func(p): return p.placement)}

func test_results_field_frozen() -> void:
	print("-- the match field survives ROUND_OVER and RESULTS exactly as it was")
	var scr = screen()
	await frames(60 * 14) # some opponents go out
	var playing := field_snapshot()
	check(playing.live == 34 and playing.valid == 34 and playing.marked.size() >= 1, "(14 s in: all 34 pictures are live and %d opponents show a KO card)" % playing.marked.size())
	var s = session()
	player().die()
	check(state() == ROUND.State.ROUND_OVER and scr.field_frozen, "the round is over: the field is held from this moment")
	var over := field_snapshot()
	check(over.live == 34 and over.valid == 34 and over.places == playing.places, "no picture fell back to a placeholder, and no pane moved, at ROUND_OVER")
	var kept := true
	for id in playing.marked:
		if not over.marked.has(id):
			kept = false
	check(kept, "every KO card of the match is still a KO card (%d)" % over.marked.size())
	var tick_over: int = s.tick_count
	var got: bool = await results_up()
	check(got and s.finished and s.tick_count > tick_over, "the results came up and the rest of the match was played out behind them (tick %d -> %d, %d alive left)" % [tick_over, s.tick_count, s.alive_count])
	await frames(90)
	var results := field_snapshot()
	check(results.pictures == over.pictures, "every opponent's picture is exactly the one it showed when the round ended")
	check(results.marked == over.marked and results.places == over.places and results.placements == over.placements, "the KO cards (and their placements) are the same, and no pane moved or changed")
	check(results.live == 34 and results.valid == 34, "no pane fell back to the placeholder: all 34 pictures are still live")
	check(results.badge == over.badge and results.time == over.time, "the alive badge and the timer are held too (%s, %d)" % [results.badge, results.time])
	check(scr.panes.all(func(p): return not p.is_animating()), "no KO animation is left running")
	check(scr.target_reticle.flying.is_empty() and not scr.target_reticle.visible and scr.attack_view.flights.is_empty(), "no reticle flight, bracket or line hangs over the results")
	check(scr._overlay.visible and scr._overlay.get_rect() == scr.layout.game, "the results dim the game window only (the dimming is independent of the field)")
	# the next round resets everything
	await next_round()
	check(not scr.field_frozen and state() == ROUND.State.PRE_ROUND, "the next round releases the field")
	await play()
	await frames(10)
	var fresh := field_snapshot()
	check(fresh.marked.is_empty() and fresh.badge == "35/35" and fresh.live == 34 and fresh.pictures != results.pictures, "...and shows a new match: no KO card, 35/35, 34 live pictures of the new round")
	check(fresh.placements.all(func(pl): return pl == 0), "no placement of the old round survives")

# ---- timeout -----------------------------------------------------------------------------------------------

func test_timeout_round() -> void:
	print("-- Battle timer runs out")
	var scr = screen()
	var round_no: int = rnd().round_number
	var old = session()
	var changes_before := scene_changes
	old.get_player().time_left = 1 # the next Battle second takes it to 0
	var over: bool = await wait_until(func(): return state() == ROUND.State.ROUND_OVER, 400)
	check(over and rnd().end_cause == ROUND.End.TIMEOUT, "running out of time ends the round (timeout)")
	check(old.get_player().ko_cause == SESSION.KoCause.TIME and not old.get_player().alive, "the session KO'd the player for time")
	var got: bool = await results_up()
	check(got and scr._overlay_label.text.contains("OUT BY: TIME"), "the results show the timeout")
	check(current_scene == scr and not seen.any(func(p): return FORBIDDEN.has(p)), "no Time Up, Game Over or title scene on the way")
	await next_round()
	check(rnd().round_number == round_no + 1 and session() != old and session().alive_count == 35 and level_running(), "a fresh round follows")
	check(scene_changes == changes_before, "the SceneTree never changed scene")
	await play()

# ---- win ----------------------------------------------------------------------------------------------------

func test_win_round() -> void:
	print("-- the player is the last one standing")
	var scr = screen()
	var round_no: int = rnd().round_number
	var old = session()
	var changes_before := scene_changes
	await frames(3)
	for id in range(1, 35):
		old.report_ko(id, SESSION.KoCause.HAZARD)
	check(old.finished and old.winner_id == 0 and old.get_player().alive, "every opponent is out: the player has won")
	var over: bool = await wait_until(func(): return state() == ROUND.State.ROUND_OVER, 30)
	check(over and rnd().end_cause == ROUND.End.WIN, "a win ends the round")
	check(scr.game_frozen and scr.game_viewport.process_mode == Node.PROCESS_MODE_DISABLED, "the game window holds still after a win")
	check(not scr.showing_result, "a win holds for a moment before the results")
	var got: bool = await results_up()
	check(got and old.get_player().placement == 1 and scr._overlay_label.text.contains("YOU WON") and scr._overlay_label.text.contains("OPPONENTS LEFT: 0"), "the results show the win")
	await next_round()
	check(rnd().round_number == round_no + 1 and session() != old and session().alive_count == 35 and state() == ROUND.State.PRE_ROUND, "a fresh round follows a win, in its pre-round")
	check(current_scene == scr and scene_changes == changes_before and not seen.any(func(p): return FORBIDDEN.has(p)), "same screen, no scene change, no title / Game Over / Time Up")
	check(G.current_level.scene_file_path == LEVEL_1_1 and not player().is_dead and G.time == SESSION.START_TIME, "1-1 is fresh after a win (a win leaves no death to reset it)")
	await play()

# ---- results input ---------------------------------------------------------------------------------------------

func test_results_input() -> void:
	print("-- results input")
	var scr = screen()
	var round_no: int = rnd().round_number
	player().die()
	var got: bool = await results_up()
	check(got, "results are up")
	var pressed := [true]
	BS.confirm_source = func() -> bool: return pressed[0]
	await frames(20) # 1/3 s: inside the lockout
	check(state() == ROUND.State.RESULTS and rnd().round_number == round_no, "confirm held during the lockout does not skip the results")
	await frames(30) # 0.83 s
	check(state() == ROUND.State.RESULTS, "...still locked at 0.83 s")
	await frames(20) # 1.17 s
	var advanced: bool = await wait_until(func(): return rnd().round_number == round_no + 1 and level_running(), 1800)
	check(advanced, "after the lockout confirm starts the next round")
	BS.confirm_source = Callable()
	check(current_scene == scr and screen() == scr, "...in the same Battle screen")
	await play()
	# auto-advance: no confirm at all
	round_no = rnd().round_number
	var changes_before := scene_changes
	BS.confirm_source = func() -> bool: return false
	player().die()
	await results_up()
	rnd().time_in_state = ROUND.RESULTS_MAX_SECONDS - 0.2
	await frames(5)
	check(state() == ROUND.State.RESULTS, "without confirm the results stay up")
	var auto: bool = await wait_until(func(): return rnd().round_number == round_no + 1 and level_running(), 1800)
	check(auto and scene_changes == changes_before, "the results advance by themselves to a fresh round")
	BS.confirm_source = Callable()
	await play()

## The pause menu holds the pre-round and the results: their timers stop while it is open.
func test_pause_holds_round_timers() -> void:
	print("-- pause menu holds the pre-round and the results")
	var hud: CanvasLayer = G.get_node("GameHUD")
	var scr = screen()
	# RESULTS
	var round_no: int = rnd().round_number
	player().die()
	await results_up()
	await frames(10)
	hud.activate_pause_menu()
	await frames(3)
	check(paused and hud.get_node("BattlePause").visible and Global_game_paused(), "the pause menu opens over the results")
	var t0: float = rnd().time_in_state
	BS.confirm_source = func() -> bool: return true # even a confirm must wait
	await frames(150) # 2.5 s: longer than the results' lockout
	check(state() == ROUND.State.RESULTS and rnd().round_number == round_no, "the results do not advance or accept confirm while the pause menu is open")
	check(absf(rnd().time_in_state - t0) < 0.001, "the results timer is frozen (%.3f -> %.3f s)" % [t0, rnd().time_in_state])
	rnd().time_in_state = ROUND.RESULTS_MAX_SECONDS - 0.5 # as if it had been up for 9.5 s
	await frames(90)
	check(state() == ROUND.State.RESULTS, "...even past what would be the auto-advance time")
	hud.get_node("BattlePause").close()
	BS.confirm_source = Callable()
	await frames(5)
	check(not paused and not Global_game_paused(), "closing the pause menu unpauses the game")
	check(state() == ROUND.State.RESULTS and rnd().time_in_state > t0 - 0.001, "the results timer resumes from where it stopped")
	await next_round()
	check(rnd().round_number == round_no + 1 and level_running(), "the results then advance to the next round")
	await play()
	# PRE_ROUND (a longer countdown so there is something to hold)
	ROUND.pre_round_override = 1.0
	var n: int = rnd().round_number
	player().die()
	await results_up()
	await next_round() # this round's pre-round is 1.0 s
	check(state() == ROUND.State.PRE_ROUND, "a new round is in its pre-round")
	var elapsed0: float = rnd().time_in_state
	hud.activate_pause_menu()
	await frames(3)
	check(paused and hud.get_node("BattlePause").visible, "the pause menu opens during the pre-round")
	var frozen_at: float = rnd().time_in_state
	await frames(150)
	check(state() == ROUND.State.PRE_ROUND and absf(rnd().time_in_state - frozen_at) < 0.001, "the pre-round does not run down while paused (%.3f s in after 2.5 s paused)" % rnd().time_in_state)
	check(scr.game_frozen and session().tick_count == 0, "...and the game and the Battle clock are still frozen")
	hud.get_node("BattlePause").close()
	await frames(5)
	check(state() == ROUND.State.PRE_ROUND, "closing the menu resumes the countdown (it had not run out)")
	await play()
	check(state() == ROUND.State.PLAYING and rnd().round_number == n + 1, "...and it then releases into PLAYING")
	ROUND.pre_round_override = 0.5

func Global_game_paused() -> bool:
	return G.game_paused

func test_never_left_battle() -> void:
	print("-- no ordinary round ever left Battle")
	check(not seen.any(func(p): return FORBIDDEN.has(p)), "the title, Game Over and Time Up scenes were never loaded (%d scenes seen: %s)" % [seen.size(), str(seen.filter(func(p): return p != LEVEL_1_1))])
	check(rnd().round_number >= 5 and G.current_game_mode == G.GameMode.BATTLE and BS.is_active(), "after %d rounds Battle is still running" % rnd().round_number)

# ---- five rounds in a row ----------------------------------------------------------------------------------------

func snapshot() -> Dictionary:
	var scr = screen()
	var handlers: int = scr.game_viewport.find_children("BattleHandler", "", true, false).size()
	var viewports: int = scr.find_children("*", "SubViewport", true, false).size()
	var players: int = get_nodes_in_group("Players").size()
	return {
		"screens": BS.instance != null, "screen_children": scr.get_child_count(), "atlas_children": scr.atlas.get_child_count(),
		"panes": scr.panes.size(), "cells": scr.cells.size(), "viewports": viewports, "handlers": handlers, "players": players,
		"game_children": scr.game_viewport.get_child_count(), "level_complete_connections": G.level_complete_begin.get_connections().size(),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), "orphans": orphan_count(),
		"transition_finished": G.transition_finished.get_connections().size(),
	}

func test_five_rounds() -> void:
	print("-- five rounds in a row")
	var scr = screen()
	var snaps: Array[Dictionary] = []
	var session_refs: Array = []
	var first_round: int = rnd().round_number
	for i in 5:
		session_refs.append(weakref(session()))
		await frames(3)
		snaps.append(snapshot())
		if i % 2 == 0:
			player().die()
		else:
			session().get_player().time_left = 1
		await results_up()
		await next_round()
		await play()
		await frames(3)
	var base: Dictionary = snaps[0]
	var stable := true
	for sn in snaps:
		for key in ["screens", "screen_children", "atlas_children", "panes", "cells", "viewports", "handlers", "players", "game_children", "level_complete_connections", "transition_finished"]:
			if sn[key] != base[key]:
				stable = false
				printerr("   %s: %s vs %s" % [key, str(sn[key]), str(base[key])])
	check(stable, "BattleScreen, atlas, panes, cells, SubViewports (2), handler (1), Mario (1) and signal connections are identical in all five rounds")
	var nodes: Array = snaps.map(func(sn): return sn.nodes)
	var orphans: Array = snaps.map(func(sn): return sn.orphans)
	print("   node counts per round: ", nodes, "  orphans: ", orphans)
	check(nodes.max() - nodes.min() <= 4, "the total node count does not grow round after round (%s)" % str(nodes))
	var growth: Array = []
	for i in range(1, orphans.size()):
		growth.append(orphans[i] - orphans[i - 1])
	# The game's own ResourceSetterNew leaves stray nodes behind on every level load (Classic leaks the same
	# way, measured below as the baseline); a Battle round must not add to that.
	check(growth.all(func(g): return g <= classic_orphans_per_load + 2), "a Battle round leaks no more orphan nodes than a Classic level load (%s per round, Classic baseline %d)" % [str(growth), classic_orphans_per_load])
	check(screen() == scr and rnd().round_number == first_round + 5, "the same BattleScreen after five more rounds (round %d)" % rnd().round_number)
	await frames(5)
	var alive_sessions := 0
	for ref in session_refs:
		if ref.get_ref() != null:
			alive_sessions += 1
	check(alive_sessions <= 1, "at most the current BattleSession survives of the five recorded (%d alive)" % alive_sessions)
	var distinct := {}
	for s in seeds:
		distinct[s] = true
	check(distinct.size() == seeds.size() and seeds.size() >= 8, "every round used a new seed (%d distinct)" % distinct.size())
	check(not seen.any(func(p): return FORBIDDEN.has(p)), "still no title / Game Over / Time Up scene")

# ---- quit ---------------------------------------------------------------------------------------------------------

func test_quit(window_before: Dictionary) -> void:
	print("-- explicit Quit")
	var scr = screen()
	var changes_before := scene_changes
	HANDLER.quit_battle()
	paused = true # the pause menu pauses while it waits for the level to go
	check(SESSION.current == null and G.current_game_mode == G.GameMode.NONE, "Quit clears the session and leaves Battle mode")
	var left: bool = await wait_until(func(): return on_title(), 1800)
	check(left, "Quit returns to the title")
	await frames(10)
	check(scene_changes == changes_before + 1, "...by exactly one scene change")
	check(not BS.is_active() and BS.instance == null and not is_instance_valid(scr), "the BattleScreen is gone")
	var after := window_state()
	for key in window_before:
		check(after[key] == window_before[key], "Quit restores %s exactly" % key)
	check(G.get_node("Transition").custom_viewport == root or not is_instance_valid(G.get_node("Transition").custom_viewport) or G.get_node("Transition").custom_viewport == root, "the fade covers the whole screen again")
	# Quit also works from the results, and starts nothing.
	current_scene.start_battle()
	await wait_until(func(): return level_running() and state() != ROUND.State.LOADING, 1500)
	await play()
	player().die()
	await results_up()
	HANDLER.quit_battle()
	var left2: bool = await wait_until(func(): return on_title(), 1800)
	await frames(10)
	check(left2 and not BS.is_active() and SESSION.current == null, "Quit from the results also goes to the title, with no next round")
	paused = false

# ---- Classic is unchanged -------------------------------------------------------------------------------------------

func classic_level() -> void:
	G.current_campaign = "SMB1"
	G.current_game_mode = G.GameMode.CAMPAIGN
	G.clear_saved_values()
	G.world_num = 1
	G.level_num = 1
	G.reset_values()
	LV.first_load = true
	G.transition_to_scene(LEVEL_1_1)
	await wait_until(func(): return current_scene != null and current_scene.scene_file_path == LEVEL_1_1 and not G.transitioning_scene and player() != null, 900)
	await frames(20)

func test_classic() -> void:
	print("-- Classic death, Game Over and Time Up are unchanged")
	await classic_level()
	check(not BS.is_active() and SESSION.current == null and not G.current_level.has_node("BattleHandler"), "Classic 1-1 has no Battle screen, session or handler")
	# an ordinary death reloads the level and costs a life
	var lives: int = G.lives
	var first_level_id: int = G.current_level.get_instance_id()
	player().die()
	check(SESSION.current == null and not BS.is_active(), "a Classic death registers nothing with Battle")
	var reloaded: bool = await wait_until(func(): return is_instance_valid(G.current_level) and G.current_level.get_instance_id() != first_level_id and G.current_level.scene_file_path == LEVEL_1_1 and not G.transitioning_scene and player() != null, 1500)
	check(reloaded and G.lives == lives - 1, "a Classic death costs a life and reloads the level (%d -> %d)" % [lives, G.lives])
	check(current_scene.scene_file_path == LEVEL_1_1 and not BS.is_active(), "Classic stays in the normal scene tree")
	await frames(20)
	# the last life: Game Over
	G.lives = 1
	player().die()
	var over: bool = await wait_until(func(): return current_scene != null and current_scene.scene_file_path == GAME_OVER, 1500)
	check(over, "dying on the last life still goes to Game Over")
	check(not BS.is_active() and SESSION.current == null, "...without involving Battle")
	G.transition_to_scene(TITLE)
	await wait_until(func(): return on_title(), 900)
	await frames(10)
	# time up
	await classic_level()
	G.time = 0
	call_group("Players", "time_up")
	var up: bool = await wait_until(func(): return current_scene != null and current_scene.scene_file_path == TIME_UP, 1500)
	check(up, "running out of time in Classic still goes to Time Up")
	check(not BS.is_active() and SESSION.current == null, "...without involving Battle")
	G.transition_to_scene(TITLE)
	await wait_until(func(): return on_title(), 900)
	await frames(10)
	G.current_game_mode = G.GameMode.NONE
