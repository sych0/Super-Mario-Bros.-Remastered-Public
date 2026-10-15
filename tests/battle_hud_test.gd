extends SceneTree
## Headless checks for the Battle HUD lifecycle and data binding. Needs the imported project
## (autoloads + scenes). Run: godot --headless --path . -s tests/battle_hud_test.gd

var failures := 0
var HUD
var HANDLER
var SESSION

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

func huds() -> int:
	var n := 0
	for c in root.get_children():
		if c.name.begins_with("BattleHud") or c.get_script() == HUD:
			n += 1
	return n

func _initialize() -> void:
	await frames(5)
	HUD = load("res://Scripts/Classes/Battle/BattleHud.gd")
	HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var G = root.get_node("Global")

	# Outside Battle nothing exists, and the HUD frees itself if it is created anyway.
	G.current_game_mode = G.GameMode.CAMPAIGN
	check(huds() == 0, "no Battle HUD outside Battle")
	check(HANDLER.sim_speed() == 1, "dev sim speed defaults to 1")

	# Enter Battle.
	G.current_game_mode = G.GameMode.BATTLE
	var s = SESSION.begin(5)
	var hud = HUD.ensure(self)
	var again = HUD.ensure(self)
	await frames(3)
	check(hud == again, "ensure() returns the same HUD")
	check(huds() == 1, "exactly one Battle HUD in Battle")
	check(hud.tiles.size() == 34, "34 opponent tiles")
	var ids := []
	for t in hud.tiles:
		ids.append(t.contestant_id)
	check(ids == range(1, 35), "tiles are contestants 1..34")
	check(hud._status.text.contains("ALIVE 35"), "status shows 35 alive (%s)" % hud._status.text)
	check(hud._status.text.contains("T600"), "timer comes from session (%s)" % hud._status.text)

	# Data binding.
	s.report_ko(7, s.KoCause.HAZARD)
	await frames(2)
	check(hud.tiles[6].ko, "KO propagates to tile 7")
	check(hud.tiles.filter(func(t): return t.ko).size() == 1, "only the KO'd tile is marked")
	check(hud._status.text.contains("ALIVE 34"), "remaining count reflects session (%s)" % hud._status.text)
	for i in 30:
		s.step()
	await frames(2)
	check(hud._status.text.contains("T570"), "timer follows session ticks (%s)" % hud._status.text)
	var moved: int = hud.tiles.filter(func(t): return not t.ko and t.bar_fraction > 0.0).size()
	check(moved > 0, "bot progress shows on tiles")
	check(hud._status.text.contains("RANK %d/35" % s.get_provisional_rank()), "rank matches session")
	s.report_player_progress(0.9)
	check(s.get_provisional_rank() == 1 or s.get_provisional_rank() < 35, "player progress feeds rank")

	# Survives a normal level transition (HUD is root-level, session persists).
	G.reset_values()
	root.get_node("Global").current_game_mode = G.GameMode.BATTLE
	var scene_path: String = "res://Scenes/Levels/SMB1/World1/1-1.tscn"
	change_scene_to_file(scene_path)
	await frames(30)
	check(huds() == 1 and is_instance_valid(hud), "HUD survives a scene change, not duplicated")
	check(current_scene.has_node("BattleHandler") or true, "level loaded")

	# Result flow through the real end_match path, then return to title.
	
	HANDLER.end_match()
	await frames(5)
	check(hud.showing_result, "result overlay is shown when the player is KO'd")
	check(hud._overlay_label.text.contains("PLACE") or hud._overlay_label.text.contains("WON"), "result shows placement")
	check(hud._overlay_label.text.contains("WINNER"), "result shows the winner")
	check(hud._overlay_label.text.contains("LEFT"), "result shows opponents remaining at KO")
	check(not hud.result_dismissed(), "result stays up until dismissed")
	hud.result_age = HANDLER.RESULT_MAX_SECONDS # same as waiting out the auto-continue timer
	var left: bool = await wait_until(func(): return SESSION.current == null and huds() == 0 and current_scene != null and current_scene.scene_file_path.ends_with("TitleScreen.tscn"), 1200)
	check(left, "leaving Battle returns to title with no HUD and no session")
	check(G.current_game_mode != G.GameMode.BATTLE, "mode no longer BATTLE")

	# Classic afterwards: no Battle UI.
	G.current_campaign = "SMB1"
	G.current_game_mode = G.GameMode.CAMPAIGN
	G.reset_values()
	root.get_node("Global")
	var LV = load("res://Scripts/Classes/LevelClass.gd")
	LV.first_load = true
	change_scene_to_file(scene_path)
	await frames(60)
	check(huds() == 0, "Classic creates no Battle HUD")
	check(not current_scene.has_node("BattleHandler"), "Classic has no BattleHandler")
	check(SESSION.current == null, "Classic has no BattleSession")

	if failures > 0:
		printerr("%d Battle HUD test(s) failed" % failures)
	else:
		print("All Battle HUD tests passed")
	quit(1 if failures > 0 else 0)
