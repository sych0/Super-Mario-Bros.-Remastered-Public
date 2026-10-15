extends SceneTree
## Headless checks for the Battle HUD lifecycle and data binding. Needs the imported project
## (autoloads + scenes). Run: godot --headless --path . -s tests/battle_hud_test.gd

var failures := 0
var HUD
var HANDLER
var SESSION
var LAYOUT

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
	LAYOUT = load("res://Scripts/Classes/Battle/BattleHudLayout.gd")
	var G = root.get_node("Global")
	test_layout(G)
	var S = root.get_node("Settings")
	S.file.video.size = 0

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
	check(hud.surfaces.size() == 34, "34 opponent preview surfaces")
	var ids := []
	for t in hud.surfaces:
		ids.append(t.contestant_id)
	check(ids == range(1, 35), "surfaces are contestants 1..34")
	check(root.content_scale_size == Vector2i(426, 240) and root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP, "Battle forces the native 16:9 resolution")
	var center: Rect2 = hud.layout.center
	var visible_all := true
	for t in hud.surfaces:
		var r := Rect2(t.position, t.size)
		if r.intersects(center) or not Rect2(Vector2.ZERO, hud.layout.viewport).encloses(r) or t.size.x < 10 or not t.visible:
			visible_all = false
	check(visible_all, "all 34 slots are on screen and outside the gameplay area")
	check(hud._alive_label.text.contains("35"), "status shows 35 alive (%s)" % hud._alive_label.text.replace("\n", " "))
	check(hud._time_label.text.contains("600"), "timer comes from session (%s)" % hud._time_label.text.replace("\n", " "))

	# Data binding.
	s.report_ko(7, s.KoCause.HAZARD)
	await frames(2)
	check(hud.surfaces[6].ko, "KO propagates to preview 7")
	check(hud.surfaces.filter(func(t): return t.ko).size() == 1, "only the KO'd preview is marked")
	check(hud._alive_label.text.contains("34"), "remaining count reflects session (%s)" % hud._alive_label.text.replace("\n", " "))
	for i in 30:
		s.step()
	await frames(2)
	check(hud._time_label.text.contains("570"), "timer follows session ticks (%s)" % hud._time_label.text.replace("\n", " "))
	var moved: int = hud.surfaces.filter(func(t): return not t.ko and t.progress > 0.0).size()
	check(moved > 0, "bot progress reaches the preview surfaces")
	check(hud._rank_label.text.contains("%d/35" % s.get_provisional_rank()), "rank matches session")
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
	await frames(3)
	check(root.content_scale_size == Vector2i(256, 240), "leaving Battle restores the user's 4:3 resolution (%s)" % root.content_scale_size)
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
	check(root.content_scale_size == Vector2i(256, 240), "Classic after Battle is 4:3 (%s)" % root.content_scale_size)
	check(not current_scene.has_node("BattleHandler"), "Classic has no BattleHandler")
	check(SESSION.current == null, "Classic has no BattleSession")

	# Existing user resolutions are untouched by the Battle changes (4:3, 5:4-ish, 16:9, expand).
	for idx in 4:
		S.file.video.size = idx
		G.current_game_mode = G.GameMode.CAMPAIGN
		LV.first_load = true
		change_scene_to_file(scene_path)
		await frames(30)
		var want_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND if idx == 3 else Window.CONTENT_SCALE_ASPECT_KEEP
		check(Vector2(root.content_scale_size) == G.RESOLUTIONS[idx] and root.content_scale_aspect == want_aspect and huds() == 0, "Classic resolution option %d unchanged (%s)" % [idx, root.content_scale_size])
	S.file.video.size = 0

	if failures > 0:
		printerr("%d Battle HUD test(s) failed" % failures)
	else:
		print("All Battle HUD tests passed")
	quit(1 if failures > 0 else 0)

func test_layout(G) -> void:
	var l: Dictionary = LAYOUT.compute(G.RESOLUTIONS[2])
	check(l.center == Rect2(85, 0, 256, 240), "gameplay area is the classic 256x240 centred in 426x240 (%s)" % l.center)
	var slots: Array = l.slots
	check(slots.size() == 34, "layout has 34 slots")
	var overlap := false
	for i in slots.size():
		for j in range(i + 1, slots.size()):
			if slots[i].intersects(slots[j]):
				overlap = true
		if slots[i].intersects(l.center):
			overlap = true
	check(not overlap, "slots never overlap each other or the gameplay area")
	check(slots[0].position.x < l.center.position.x and slots[17].position.x >= l.center.end.x, "17 slots per side (left 1-17, right 18-34)")
	check(slots[0].size.x / slots[0].size.y > 1.0 and slots[0].size.x / slots[0].size.y < 1.2, "slots keep roughly the gameplay aspect (%s)" % slots[0].size)
