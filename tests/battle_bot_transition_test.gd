extends SceneTree
## A real opponent clears the real 1-1 and plays on in the real 1-2, in the full Battle screen (doc 57). Started from the title as a
## build starts it, with the real player's game in the window, the HUD, the atlas, the panes, and the legacy previews for the other
## opponents. For each real opponent (BattleBotDirector.real_ids):
##   - its BattleBotWorld owns its game and its pane's picture from the first frame; the legacy previews never get it: no
##     BattlePreviewTrack, no BattlePreviewStages request for it, nothing but its world drawn in its cell;
##   - it reaches the real flagpole by the game's own rules (its Mario is put on the ground before 1-1's pole and runs and jumps at it:
##     the FlagPole state, the slide, the hold, the fade), the session logs its LEVEL_CLEAR, and its world loads the real
##     World1/1-2.tscn: the old level is freed, a new real Mario stands in the new level, the viewport and its texture are the same
##     ones, and the cell still draws that world's screen (never a stand-in, never the placeholder);
##   - its brain plays on in 1-2: Mario moves, lands on 1-2's terrain, the camera scrolls, 1-2's enemies wake and move;
##   - two real opponents transition independently: one's clear changes nothing in the other's game, each ends in its own 1-2, and
##     the real player's game and Global's skin inputs are untouched;
##   - the ownership guards: the flag is read with or without `--`; the previews refuse a world-driven opponent; a world that cannot
##     load its course says so and its pane shows the failure, never a preview.
##   godot --headless --fixed-fps 60 --path . -s tests/battle_bot_transition_test.gd
## Script classes that mention autoloads are only reached through load() (a `-s` script is compiled before the autoloads exist).

const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const LEVEL_1_2 := "res://Scenes/Levels/SMB1/World1/1-2.tscn"

var failures := 0
var G
var S
var BS
var ROUND
var DIRECTOR
var WORLD
var HANDLER
var SESSION
var GW
var CELL
var DRIVER
var CONTESTANT

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

func scr():
	return BS.instance

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = root.get_node("Settings")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	ROUND = load("res://Scripts/Classes/Battle/BattleRound.gd")
	DIRECTOR = load("res://Scripts/Classes/Battle/BattleBotDirector.gd")
	WORLD = load("res://Scripts/Classes/Battle/BattleBotWorld.gd")
	HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	GW = load("res://Scripts/Classes/GameWorld.gd")
	CELL = load("res://Scripts/Classes/Battle/BattlePreviewCell.gd")
	DRIVER = load("res://Scripts/Classes/Battle/BattlePreviewDriver.gd")
	CONTESTANT = load("res://Scripts/Classes/Battle/BattleContestant.gd")
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR)
	ROUND.pre_round_override = 0.3
	HANDLER.seed_source = func() -> int: return 11

	test_flag()
	await test_one_real_opponent()
	await test_two_real_opponents()
	await test_guards()

	DIRECTOR.count_override = -1
	ROUND.pre_round_override = -1.0
	HANDLER.seed_source = Callable()
	var out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	out.store_string(saved_settings_file)
	out.close()
	if failures > 0:
		printerr("%d Battle bot transition test(s) failed" % failures)
	else:
		print("All Battle bot transition tests passed")
	quit(1 if failures > 0 else 0)

# ---- helpers ----------------------------------------------------------------------------------------------------------------

## Battle from the title with `n` real opponents, as a build starts it; the real player stands still and cannot be hurt (the round
## must go on while the bots play), and the dice opponents do not send (nothing arrives at random in a real opponent's level).
func start_battle(n: int) -> bool:
	DIRECTOR.count_override = n
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return on_title(), 900)
	current_scene.start_battle()
	var up: bool = await wait_until(func(): return BS.is_active() and scr().bots != null and scr().driver != null \
		and scr().battle_round.state == ROUND.State.PLAYING and is_instance_valid(G.current_level), 1500)
	if up:
		scr().session.attacks.bots_send = false
		var p = G.current_level.get_node_or_null("Player")
		if p != null:
			p.can_hurt = false
	return up

func quit_battle() -> void:
	DIRECTOR.count_override = -1
	HANDLER.quit_battle()
	await wait_until(func(): return on_title(), 900)
	await frames(3)

## Puts world `w`'s Mario on the ground `dist` px before its course's pole (on the ground he stood on at the start) and has him run and
## jump at it. Everything after that is the game's: the pole, the FlagPole state, the slide, the world's hold and fade, the cut.
func run_at_pole(w, dist: float, ground_y: float) -> void:
	w.player.global_position = Vector2(w._goal_x - dist, ground_y)
	w.player.velocity = Vector2.ZERO
	w.script_buttons = func(ww) -> Dictionary: return {"move_right": true, "jump": ww.ticks % 40 < 25}

## Plays until `w` is in course 1 (or `max_frames`), recording the phases it went through and whether its Mario rode the pole.
func play_to_next_course(w, max_frames := 900) -> Dictionary:
	var seen := {"phases": [], "flagpole": false, "frames": 0}
	for f in max_frames:
		await process_frame
		var ph: String = WORLD.Phase.keys()[w.phase]
		if seen.phases.is_empty() or seen.phases[-1] != ph:
			seen.phases.append(ph)
		if is_instance_valid(w.player) and w.player.state_machine.is_state("FlagPole"):
			seen.flagpole = true
		seen.frames = f + 1
		if w.course == 1:
			break
	return seen

func facts(w) -> Dictionary:
	return {"course": w.course, "phase": w.phase, "level": w.level.get_instance_id() if is_instance_valid(w.level) else 0,
		"player": w.player.get_instance_id() if is_instance_valid(w.player) else 0, "x": w.player.global_position.x if is_instance_valid(w.player) else 0.0,
		"viewport": w.viewport.get_instance_id(), "vp_rid": w.viewport.get_viewport_rid().get_id(), "scene": w.scene_path, "ticks": w.ticks}

## Everything a real opponent's game must never change in the real player's game, and Global's skin inputs (a world pushes its own
## while its resources resolve and must put them back).
func real_game_state() -> Dictionary:
	return {"level": G.current_level.get_instance_id() if is_instance_valid(G.current_level) else 0,
		"level_file": G.current_level.scene_file_path if is_instance_valid(G.current_level) else "", "world": G.world_num, "level_num": G.level_num,
		"theme": G.level_theme, "theme_time": G.theme_time, "theme_override": G.theme_override, "time_override": G.time_override,
		"room": G.current_room_type, "score": G.score, "coins": G.coins, "paused": paused}

## The ownership of opponent `id` in the screen, right now: who has it, and what its cell last drew.
func ownership(id: int) -> Dictionary:
	var cell = scr().cells[id - 1]
	var w = scr().bots.world(id) if scr().bots != null else null
	return {"world": w, "cell_bot": cell.bot, "is_bot": cell.is_bot(), "is_live": cell.is_live(), "frame": cell.frame,
		"track": scr().driver != null and scr().driver.tracks.has(id),
		"stage_query": scr().driver != null and scr().driver.stages.queried_for(id),
		"source": cell.last_source.duplicate(), "world_driven": scr().session.contestants[id].world_driven}

func world_owned(id: int, o: Dictionary) -> bool:
	return o.world != null and o.world_driven and o.is_bot and o.cell_bot == o.world and not o.is_live and o.frame == null \
		and not o.track and not o.stage_query

# ---- the command line --------------------------------------------------------------------------------------------------------

func test_flag() -> void:
	print("-- --battle-real-bots=N is read before or after `--`, and a bad value is an error, not a silent 0")
	check(DIRECTOR.parse_count("", PackedStringArray(["-s", "x.gd", "--battle-real-bots=4"])) == 4,
		"`game --battle-real-bots=4` (no `--`: Godot keeps it in the engine arguments) gives 4 real opponents; it used to give 0")
	check(DIRECTOR.parse_count("", PackedStringArray(["--battle-real-bots=4"])) == 4, "`game -- --battle-real-bots=4` gives 4")
	check(DIRECTOR.parse_count("3", PackedStringArray()) == 3 and DIRECTOR.parse_count("3", PackedStringArray(["--battle-real-bots=1"])) == 1,
		"SMB1R_BATTLE_REAL_BOTS=3 gives 3; the command line wins over it")
	check(DIRECTOR.parse_count("", PackedStringArray()) == 0 and DIRECTOR.parse_count("", PackedStringArray(["--battle-real-bots=99"])) == 34,
		"nothing asked: 0 (the default build); more than 34: 34")
	check(DIRECTOR.parse_count("", PackedStringArray(["--battle-real-bots=four"])) == 0, "a value that is not a number: 0, with an error")
	var ids: Array = []
	DIRECTOR.count_override = 4
	ids = DIRECTOR.real_ids()
	DIRECTOR.count_override = -1
	check(ids == [1, 2, 3, 4], "4 real opponents are contestants 1-4")

# ---- one real opponent ---------------------------------------------------------------------------------------------------------

func test_one_real_opponent() -> void:
	print("-- one real opponent: the real 1-1, the flag, the real 1-2, its own pane all along")
	var violations0: int = DIRECTOR.violations
	check(await start_battle(1), "Battle runs with 1 real opponent")
	var w = scr().bots.world(1)
	var o := ownership(1)
	check(world_owned(1, o), "opponent 1 is its BattleBotWorld's: its cell shows its world, no legacy track, no stage request")
	check(scr().driver.tracks.size() == 33 and not scr().driver.tracks.has(1) and scr().driver.tracks.has(2), "the legacy previews have 2-34 only")
	check(w.scene_path == LEVEL_1_1 and w.level.scene_file_path == LEVEL_1_1, "it plays the real World 1-1")
	await frames(2)
	o = ownership(1)
	check(o.source.get("kind") == "world" and o.source.get("world") == w.get_instance_id(), "its cell draws its world's screen (%s)" % [o.source])
	await wait_until(func(): return w.ticks > 60 and is_instance_valid(w.player) and w.player.is_on_floor(), 300)
	var ground_y: float = w.player.global_position.y
	var real0 := real_game_state()
	var before := facts(w)
	var tex0: Texture2D = w.pane_texture()
	var tex_rid0: int = tex0.get_rid().get_id()
	run_at_pole(w, 46.0, ground_y)
	var seen := await play_to_next_course(w)
	check(seen.flagpole, "its Mario rode the real flagpole (the game's FlagPole state)")
	check(seen.phases == ["PLAYING", "CLEARING", "FADING", "PLAYING"], "the world's flow: play, the slide and hold, the fade, the cut (%s)" % [seen.phases])
	check(w.course == 1, "it cleared 1-1 (course 0 -> 1) in %d frames" % seen.frames)
	if w.course != 1:
		await quit_battle()
		return
	var t: Dictionary = w.transitions[-1]
	check(t.from == 0 and t.course == 1 and t.requested == LEVEL_1_2 and t.loaded == LEVEL_1_2,
		"requested next course 1 = %s; loaded %s" % [t.requested.get_file(), t.loaded.get_file()])
	check(w.scene_path == LEVEL_1_2 and w.level.scene_file_path == LEVEL_1_2 and w.level.get_parent() == w.viewport,
		"the actual PackedScene instanced is the real World1/1-2.tscn, in the world's own viewport")
	check(w.failure == "" and w.phase == WORLD.Phase.PLAYING, "no failure; the world is playing")
	check(w.player != null and w.player.get_parent() == w.level and w.player.get_instance_id() != before.player and w.player.player_id == 101,
		"a fresh real Mario stands in the new level, on this opponent's pad")
	check(w.theme == "Underground" and w.world_num == 1 and w.level_num == 2, "1-2 is skinned as its own underground level")
	await frames(2)
	check(t.old_level != null and t.old_level.get_ref() == null, "the old 1-1 level is freed")
	check(w.viewport.get_instance_id() == before.viewport and w.viewport.get_viewport_rid().get_id() == before.vp_rid,
		"the viewport survives the cut (same object, same RID)")
	check(w.pane_texture() == tex0 and w.pane_texture().get_rid().get_id() == tex_rid0, "the pane's source texture is the same viewport texture")
	o = ownership(1)
	check(world_owned(1, o), "after the cut opponent 1 is still world-driven and its cell is still its world's")
	check(o.source.get("kind") == "world" and o.source.get("world") == w.get_instance_id() and o.source.get("course") == 1 \
		and o.source.get("texture") == tex_rid0, "the cell's last draw is that world's screen on course 1 (%s)" % [o.source])
	var clears: Array = scr().session.events.filter(func(e): return e.id == 1 and e.type == SESSION.EventType.LEVEL_CLEAR)
	check(clears.size() == 1 and scr().session.contestants[1].levels_cleared == 1, "the session logged opponent 1's LEVEL_CLEAR (1 course)")
	check(scr().cells[0].course_index() == 1 and scr().cells[0].world_level_text() == "1-2", "its pane's course is 1-2")
	# Its brain plays on in the real 1-2.
	w.script_buttons = Callable()
	var x0: float = w.player.global_position.x
	var view0: Rect2 = w.view_rect()
	var landed := false
	var moved_enemy := ""
	var enemy_x := {}
	for f in 8 * 60:
		await process_frame
		if not is_instance_valid(w.player) or w.phase != WORLD.Phase.PLAYING:
			break
		if w.player.is_on_floor():
			landed = true
		for e in w.enemies:
			if not is_instance_valid(e) or not e.is_inside_tree() or e.process_mode == Node.PROCESS_MODE_DISABLED:
				continue
			var key: int = e.get_instance_id()
			if not enemy_x.has(key):
				enemy_x[key] = e.global_position.x
			elif absf(e.global_position.x - enemy_x[key]) > 4.0 and moved_enemy == "":
				moved_enemy = String(e.name)
		if landed and moved_enemy != "" and w.player.global_position.x > x0 + 100.0:
			break
	check(w.course == 1 and w.scene_path == LEVEL_1_2, "it is still in the real 1-2")
	check(is_instance_valid(w.player) and w.player.global_position.x > x0 + 40.0, "its Mario plays on in 1-2 (x %.0f -> %.0f)" % [x0,
		w.player.global_position.x if is_instance_valid(w.player) else 0.0])
	check(landed, "on 1-2's own terrain (he stood on its floor)")
	check(w.view_rect().position.x > view0.position.x, "its camera scrolls through 1-2 (%.0f -> %.0f)" % [view0.position.x, w.view_rect().position.x])
	check(moved_enemy != "", "1-2's enemies wake and move in its game (%s)" % moved_enemy)
	o = ownership(1)
	check(world_owned(1, o) and o.source.get("world") == w.get_instance_id(), "and the whole time opponent 1 is owned by its world only")
	check(not scr().driver.stages.queried_for(1), "BattlePreviewStages was never asked for anything on opponent 1's behalf")
	check(DIRECTOR.violations == violations0, "no ownership violation was refused (%d)" % (DIRECTOR.violations - violations0))
	var real1 := real_game_state()
	check(real1 == real0, "the real player's game and Global's skin inputs are untouched by the transition")
	await quit_battle()

# ---- two real opponents ---------------------------------------------------------------------------------------------------------

func test_two_real_opponents() -> void:
	print("-- two real opponents transition independently")
	var violations0: int = DIRECTOR.violations
	check(await start_battle(2), "Battle runs with 2 real opponents")
	var a = scr().bots.world(1)
	var b = scr().bots.world(2)
	check(world_owned(1, ownership(1)) and world_owned(2, ownership(2)) and a != b and a.viewport != b.viewport \
		and a.viewport.world_2d != b.viewport.world_2d, "each is its own world: own viewport, own World2D, own pane")
	await wait_until(func(): return a.ticks > 60 and is_instance_valid(a.player) and a.player.is_on_floor() \
		and is_instance_valid(b.player) and b.player.is_on_floor(), 300)
	var ground_a: float = a.player.global_position.y
	var real0 := real_game_state()
	# A clears while B plays its 1-1 with its brain.
	run_at_pole(a, 46.0, ground_a)
	var b_before := facts(b)
	var seen := await play_to_next_course(a)
	check(a.course == 1 and seen.flagpole and a.level.scene_file_path == LEVEL_1_2, "opponent 1 rode the pole and entered the real 1-2")
	var b_at_cut := facts(b)
	check(b_at_cut.course == 0 and b_at_cut.level == b_before.level and b_at_cut.player == b_before.player and b_at_cut.scene == LEVEL_1_1 \
		and b_at_cut.viewport == b_before.viewport, "opponent 2 is untouched by 1's clear: same 1-1 level, same Mario, same viewport")
	check(b.phase == WORLD.Phase.PLAYING or b.phase == WORLD.Phase.DYING or b.phase == WORLD.Phase.OUT, "opponent 2 was not released by 1's flag (it never left its own flow)")
	check(b.ticks > b_before.ticks, "opponent 2 kept playing while 1 cleared (%d -> %d ticks)" % [b_before.ticks, b.ticks])
	check(b.theme == "Overworld" and b.world_num == 1 and b.level_num == 1, "opponent 2 is still skinned as 1-1")
	a.script_buttons = Callable()
	await frames(60)
	check(a.course == 1 and a.phase == WORLD.Phase.PLAYING, "opponent 1 plays its 1-2 on")
	if b.phase != WORLD.Phase.PLAYING:
		print("   (opponent 2 was KO'd by its own 1-1 before it reached the pole; the second transition is skipped)")
		await quit_battle()
		return
	# Then B clears while A plays its 1-2.
	var a_before := facts(a)
	var ground_b: float = ground_a # (the same 1-1: the same ground)
	run_at_pole(b, 52.0, ground_b)
	seen = await play_to_next_course(b)
	check(b.course == 1 and seen.flagpole and b.level.scene_file_path == LEVEL_1_2, "opponent 2 rode its own pole and entered its own real 1-2")
	var a_at_cut := facts(a)
	check(a_at_cut.level == a_before.level and a_at_cut.player == a_before.player and a_at_cut.course == 1 and a.scene_path == LEVEL_1_2,
		"opponent 1 is untouched by 2's clear: same 1-2 level, same Mario")
	check(a_at_cut.ticks > a_before.ticks, "opponent 1 kept playing its 1-2 meanwhile")
	check(a.level != b.level and a.player != b.player and a.level.get_parent() == a.viewport and b.level.get_parent() == b.viewport,
		"each 1-2 is its own instance, in its own world")
	check(a.pad != b.pad and a.player.player_id == 101 and b.player.player_id == 102, "each Mario reads its own pad")
	check(a.transitions.size() == 2 and b.transitions.size() == 2 and a.transitions[-1].loaded == LEVEL_1_2 and b.transitions[-1].loaded == LEVEL_1_2,
		"each world logged exactly its own two courses (1-1, 1-2)")
	check(GW.bot_worlds == 2, "two bot worlds are live, no more (%d)" % GW.bot_worlds)
	b.script_buttons = Callable()
	var ax: float = a.player.global_position.x
	var bx: float = b.player.global_position.x
	await frames(120)
	check(a.course == 1 and b.course == 1 and is_instance_valid(a.player) and is_instance_valid(b.player) \
		and (a.player.global_position.x != ax or a.phase != WORLD.Phase.PLAYING) and (b.player.global_position.x != bx or b.phase != WORLD.Phase.PLAYING),
		"both play their own 1-2 on")
	for id in [1, 2]:
		var o := ownership(id)
		check(world_owned(id, o) and o.source.get("kind") == "world" and o.source.get("world") == o.world.get_instance_id(),
			"opponent %d's pane is its world's screen, never a preview (%s)" % [id, o.source])
	check(DIRECTOR.violations == violations0, "no ownership violation (%d)" % (DIRECTOR.violations - violations0))
	check(real_game_state() == real0, "the real player's game and Global's skin inputs are untouched by both transitions")
	# The real player's time-out ends the real player's game only (BattleHandler used to call time_up on every Mario in the tree).
	scr().session.report_ko(0, SESSION.KoCause.TIME)
	await wait_until(func(): return scr().battle_round.state != ROUND.State.PLAYING, 120)
	check(scr().battle_round.state != ROUND.State.PLAYING and a.death.is_empty() and b.death.is_empty() \
		and scr().session.contestants[1].alive and scr().session.contestants[2].alive,
		"the real player's time-out kills the real player's Mario only, never a real opponent's (%s / %s)" % [a.death, b.death])
	await quit_battle()

# ---- the guards ----------------------------------------------------------------------------------------------------------------

func test_guards() -> void:
	print("-- the ownership guards: refused, reported, visible; never a fallback")
	G.current_game_mode = G.GameMode.BATTLE
	var session = SESSION.begin(5)
	session.set_world_driven(1)
	var v0: int = DIRECTOR.violations
	var d = DRIVER.create(session, [1, 2, 3], 187.0)
	check(d != null and not d.tracks.has(1) and d.tracks.has(2) and d.tracks.has(3) and DIRECTOR.violations == v0 + 1,
		"the legacy previews refuse a world-driven opponent handed to them (no track for it; reported)")
	check(d.stages.forbidden.has(1) and d.stages.stage(1, 1).is_empty() and DIRECTOR.violations == v0 + 2,
		"BattlePreviewStages refuses a stage asked for on a world-driven opponent's behalf (no sketch, no stand-in)")
	check(not d.stages.stage(1, 2).is_empty(), "(and still serves the legacy opponents)")
	# A cell owned by a world refuses a preview frame.
	var w = WORLD.new(1, session, 5)
	root.add_child(w)
	w.start(0)
	var cell = CELL.new(1)
	root.add_child(cell)
	cell.set_bot(w)
	cell.refresh(session.contestants[1])
	cell.set_live(load("res://Scripts/Classes/Battle/BattleMiniGameRenderer.gd").new(), d.tracks[2].frame)
	check(cell.is_bot() and not cell.is_live() and cell.frame == null and DIRECTOR.violations == v0 + 3,
		"a cell that shows a real game refuses a legacy preview frame")
	await frames(2)
	check(cell.last_source.get("kind") == "world", "it draws its world")
	# The world cannot load its next course: it says so, and the pane shows the failure.
	w._load_course(BattleCourse_COUNT())
	await frames(2)
	check(w.failure != "" and w.phase == WORLD.Phase.FINISHED, "a world that cannot load its course fails loudly (%s)" % w.failure)
	check(cell.last_source.get("kind") == "failure", "its pane shows the failure, not a preview or a stand-in (%s)" % [cell.last_source])
	# A world-driven opponent whose cell has no world: the failure, never the placeholder.
	var orphan = CELL.new(2)
	root.add_child(orphan)
	session.set_world_driven(2)
	orphan.refresh(session.contestants[2])
	await frames(2)
	check(orphan.last_source.get("kind") == "failure" and orphan.last_source.get("why") == "no BattleBotWorld owns its pane",
		"a world-driven opponent with no world draws the failure, never the placeholder")
	var plain = CELL.new(3)
	root.add_child(plain)
	plain.refresh(session.contestants[3])
	await frames(2)
	check(plain.last_source.get("kind") == "placeholder", "(a legacy opponent without a preview still gets the placeholder)")
	for n in [w, cell, orphan, plain]:
		root.remove_child(n)
		n.free()
	SESSION.clear()
	G.current_game_mode = G.GameMode.NONE
	await frames(2)

func BattleCourse_COUNT() -> int:
	return load("res://Scripts/Classes/Battle/BattleCourse.gd").COURSE_COUNT
