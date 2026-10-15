extends SceneTree
## Layout and data-binding checks for the Battle screen. The layout part is pure geometry; the
## binding part puts a BattleScreen in the tree without a level (composition, routing and window
## ownership are in battle_screen_test.gd). Needs the imported project (autoloads + scenes).
## Run: godot --headless --fixed-fps 60 --path . -s tests/battle_hud_test.gd

var failures := 0
var BS
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

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	LAYOUT = load("res://Scripts/Classes/Battle/BattleHudLayout.gd")
	var G = root.get_node("Global")
	test_layout()

	# Outside Battle nothing exists.
	G.current_game_mode = G.GameMode.CAMPAIGN
	check(not BS.is_active() and BS.instance == null, "no Battle screen outside Battle")
	check(HANDLER.sim_speed() == 1, "dev sim speed defaults to 1")
	check(not BS.routes("res://Scenes/Levels/SMB1/World1/1-1.tscn"), "Classic scenes are never routed into a Battle screen")

	# Enter Battle with a screen and a session (no level: the data binding needs none).
	G.current_game_mode = G.GameMode.BATTLE
	var s = SESSION.begin(5)
	check(BS.routes("res://Scenes/Levels/SMB1/World1/1-1.tscn") and BS.routes("res://Scenes/Levels/LevelTransition.tscn"), "Battle routes game scenes")
	check(not BS.routes(BS.TITLE_SCENE) and not BS.routes(null), "the title (and a null scene) leave Battle instead of being routed")
	var screen = BS.new()
	root.add_child(screen)
	await frames(3)
	check(BS.instance == screen and BS.is_active(), "the screen registers itself as the Battle screen")
	check(screen.surfaces.size() == 34, "34 opponent preview surfaces")
	var ids := []
	for t in screen.surfaces:
		ids.append(t.contestant_id)
	check(ids == range(1, 35), "surfaces are contestants 1..34")
	check(screen._alive_label.text.contains("35"), "status shows 35 alive (%s)" % screen._alive_label.text)
	check(screen._time_label.text == "TIME 600", "timer comes from the session (%s)" % screen._time_label.text)
	check(screen._course_label.text == "1-1", "course badge shows 1-1 (%s)" % screen._course_label.text)

	# Data binding.
	s.report_ko(7, s.KoCause.HAZARD)
	await frames(2)
	check(screen.surfaces[6].ko, "KO propagates to preview 7")
	check(screen.surfaces.filter(func(t): return t.ko).size() == 1, "only the KO'd preview is marked")
	check(screen._alive_label.text == "34", "remaining count reflects the session (%s)" % screen._alive_label.text)
	for i in 30:
		s.step()
	await frames(2)
	check(screen._time_label.text == "TIME 570", "timer follows session ticks (%s)" % screen._time_label.text)
	var moved: int = screen.surfaces.filter(func(t): return not t.ko and t.progress > 0.0).size()
	check(moved > 0, "bot progress reaches the preview surfaces")
	check(screen._rank_label.text == "RANK %d/35" % s.get_provisional_rank(), "rank matches the session (%s)" % screen._rank_label.text)
	s.report_player_progress(0.9)
	check(s.get_provisional_rank() == 1 or s.get_provisional_rank() < 35, "player progress feeds rank")
	check(screen.driver == null or screen.driver.tracks.size() >= 1, "the live preview driver (opponent #1) is optional, never required")

	# The result overlay (interim, until the round lifecycle exists) is a view of the finished session.
	var others: int = s.alive_count
	s.report_ko(0, s.KoCause.HAZARD)
	s.resolve_to_end()
	screen.show_result(s, others)
	await frames(2)
	check(screen.showing_result and screen._overlay.visible, "result overlay is shown when the player is KO'd")
	check(screen._overlay.get_rect() == screen.layout.game, "the result covers the game window only")
	check(screen._overlay_label.text.contains("PLACE") or screen._overlay_label.text.contains("WON"), "result shows placement")
	check(screen._overlay_label.text.contains("WINNER"), "result shows the winner")
	check(screen._overlay_label.text.contains("LEFT"), "result shows opponents remaining at KO")
	check(not screen.result_dismissed(), "result stays up until dismissed")
	screen.result_age = HANDLER.RESULT_MAX_SECONDS
	check(screen.result_dismissed(), "result auto-continues after its timer")

	# A session going away (end of match) does not take the screen with it: leaving is a scene change.
	SESSION.clear()
	await frames(3)
	check(BS.is_active() and is_instance_valid(screen), "the screen outlives the session (it is the current scene, not a self-freeing overlay)")
	root.remove_child(screen)
	screen.free()
	check(not BS.is_active() and BS.instance == null, "freeing the screen unregisters it")
	await frames(2)

	if failures > 0:
		printerr("%d Battle HUD test(s) failed" % failures)
	else:
		print("All Battle HUD tests passed")
	quit(1 if failures > 0 else 0)

func overlaps(a: Rect2, b: Rect2) -> bool:
	return a.intersects(b)

func whole(r: Rect2) -> bool:
	return r.position == r.position.round() and r.size == r.size.round()

func test_layout() -> void:
	var l: Dictionary = LAYOUT.compute()
	check(l.canvas == Vector2(480, 270), "Battle canvas is 480x270 (%s)" % l.canvas)
	check(l.game == Rect2(112, 3, 256, 240), "game window is the classic 256x240 at (112, 3) (%s)" % l.game)
	check(l.game.size == LAYOUT.GAME_SIZE, "window size is the classic gameplay size")
	check(l.game.get_center().x == 240.0, "game window is centred horizontally on the canvas")
	var all: Array = [l.game, l.frame, l.strip_a, l.strip_b, l.badge_left, l.badge_right, l.left, l.right] + l.slots
	check(all.all(func(r): return whole(r)), "all geometry is on whole logical pixels")
	check(Rect2(Vector2.ZERO, l.canvas).encloses(l.frame) and Rect2(Vector2.ZERO, l.canvas).encloses(l.game), "frame and window fit the canvas")
	check(l.frame.encloses(l.game) and l.frame.encloses(l.strip_a) and l.frame.encloses(l.strip_b), "the gold frame surrounds the window and both strips")
	var slots: Array = l.slots
	check(slots.size() == 34, "layout has 34 slots")
	var left_slots: Array = slots.slice(0, 17)
	var right_slots: Array = slots.slice(17)
	check(left_slots.all(func(r): return l.left.encloses(r)) and right_slots.all(func(r): return l.right.encloses(r)), "17 slots per side, each inside its own panel (left 1-17, right 18-34)")
	check(l.left.end.x <= l.frame.position.x and l.right.position.x >= l.frame.end.x, "panels end where the frame begins")
	var clash := false
	for i in slots.size():
		for j in range(i + 1, slots.size()):
			clash = clash or overlaps(slots[i], slots[j])
		for other in [l.game, l.frame, l.strip_a, l.strip_b, l.badge_left, l.badge_right]:
			clash = clash or overlaps(slots[i], other)
	check(not clash, "no slot overlaps another slot, the window, the frame, a strip or a badge")
	clash = overlaps(l.badge_left, l.frame) or overlaps(l.badge_right, l.frame) or overlaps(l.badge_left, l.badge_right)
	check(not clash, "badges don't overlap the frame or each other")
	clash = overlaps(l.game, l.strip_a) or overlaps(l.game, l.strip_b) or overlaps(l.strip_a, l.strip_b)
	check(not clash, "the window and the two strips never overlap")
	check(l.strip_a.position.y >= l.game.end.y and l.strip_b.position.y >= l.strip_a.end.y and l.strip_b.end.y <= l.frame.end.y, "both strips fit under the window, inside the frame")
	check(l.strip_a.position.x == l.game.position.x and l.strip_a.size.x == l.game.size.x and l.strip_b.position.x == l.game.position.x and l.strip_b.size.x == l.game.size.x, "strips are exactly as wide as the window")
	check(l.badge_left.position.x >= slots[1].end.x and l.badge_right.end.x <= slots[17].position.x and l.badge_left.position.y == 0.0 and l.badge_right.position.y == 0.0, "badges hang from the top in the inner corners (course left, alive right)")
	check(l.badge_left.end.x <= l.left.end.x and l.badge_right.position.x >= l.right.position.x, "badges are inside their panels")
	check(slots.all(func(r): return r.size == Vector2(32, 41)), "every slot is 32x41 logical px")
	var aspect: float = slots[0].size.x / slots[0].size.y
	check(absf(aspect - 129.0 / 165.0) < 0.01, "slots keep the reference's portrait aspect (%s)" % aspect)
	for key in ["status_left", "status_right"]:
		var r: Rect2 = l[key]
		check(r.size.y == l.top and r.position.y == 0.0 and not overlaps(r, l.badge_left) and not overlaps(r, l.badge_right) and slots.all(func(s): return not overlaps(r, s)), "%s is one text line in the strip above the grid, clear of badges and slots" % key)

	# Whole-screen coverage: panes + badges + window + frame + strips never leave the canvas.
	var inside: bool = slots.all(func(r): return Rect2(Vector2.ZERO, l.canvas).encloses(r))
	check(inside, "every slot is on the canvas")
