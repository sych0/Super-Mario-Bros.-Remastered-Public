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
	check(screen.panes.size() == 34, "34 opponent preview panes")
	var ids := []
	for t in screen.panes:
		ids.append(t.contestant_id)
	check(ids == range(1, 35), "panes are contestants 1..34")
	check(screen.badge_alive.value == "35/35", "the alive badge reads 35/35 at the start (%s)" % screen.badge_alive.value)
	check(screen.hud.time_left == 600 and screen.hud.timer_text(screen.hud.time_left) == "600", "the in-window timer comes from the session (%s)" % screen.hud.time_left)
	check(screen.badge_course.value == "1-1", "course badge shows 1-1 (%s)" % screen.badge_course.value)
	check(screen.get_node_or_null("TimeLabel") == null and screen.find_children("*", "Label", false, false).size() == 0, "no TIME or RANK text label is left on the canvas (the timer is in the window)")

	# Data binding.
	s.report_ko(7, s.KoCause.HAZARD)
	await frames(2)
	check(screen.panes[6].ko, "KO propagates to preview 7")
	check(screen.panes.filter(func(t): return t.ko).size() == 1, "only the KO'd preview is marked")
	check(screen.badge_alive.value == "34/35", "remaining count reflects the session on the same frame (%s)" % screen.badge_alive.value)
	for i in 30:
		s.step()
	await frames(2)
	check(screen.hud.time_left == 570, "timer follows session ticks (%s)" % screen.hud.time_left)
	var moved: int = screen.panes.filter(func(t): return not t.ko and t.cell.progress > 0.0).size()
	check(moved > 0, "bot progress reaches the preview cells")
	s.report_player_progress(0.9)
	check(s.get_provisional_rank() == 1 or s.get_provisional_rank() < 35, "player progress feeds rank")
	check(screen.driver == null or screen.driver.tracks.size() >= 1, "the live preview driver (all 34 opponents) is optional, never required")

	# The result card is a view of the finished session, shown by the round lifecycle (BattleRound).
	var RoundCls = load("res://Scripts/Classes/Battle/BattleRound.gd")
	RoundCls.pre_round_override = 0.0
	screen.set_process(false) # drive the lifecycle by hand
	screen.battle_round.begin_round()
	screen.battle_round.level_ready()
	var others: int = s.alive_count - 1
	s.report_ko(0, s.KoCause.HAZARD)
	screen.round_over(RoundCls.End.DEATH)
	screen.death_finished()
	await frames(2)
	check(screen.showing_result and screen._overlay.visible, "result overlay is shown when the player is KO'd")
	check(screen._overlay.get_rect() == screen.layout.game, "the result covers the game window only")
	check(screen._overlay_label.text.contains("PLACED") or screen._overlay_label.text.contains("WON"), "result shows placement")
	check(screen._overlay_label.text.contains("WINNER"), "result shows the winner")
	check(screen._overlay_label.text.contains("LEFT"), "result shows opponents remaining")
	check(screen._overlay_label.text.contains("NEXT ROUND"), "result says the next round follows (not the title)")
	check(not screen.battle_round.results_dismissed(true), "result cannot be skipped during its lockout")
	screen.battle_round.time_in_state = RoundCls.RESULTS_MAX_SECONDS
	check(screen.battle_round.results_dismissed(false), "result auto-continues after its timer")
	RoundCls.pre_round_override = -1.0

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

## True if every coordinate of `r` is a multiple of a quarter of a logical pixel: a whole device pixel at 1080p (4x).
func device_exact(r: Rect2) -> bool:
	for v in [r.position.x, r.position.y, r.size.x, r.size.y]:
		if not is_equal_approx(v * 4.0, roundf(v * 4.0)):
			return false
	return true

func test_layout() -> void:
	var l: Dictionary = LAYOUT.compute()
	check(l.canvas == Vector2(480, 270), "Battle canvas is 480x270 (%s)" % l.canvas)
	check(l.game == Rect2(112, 8, 256, 224), "the visible game window is 256x224 at (112, 8) (%s)" % l.game)
	check(l.game_size == Vector2(256, 240) and l.game_crop == Vector2(0, 8), "the simulation viewport stays 256x240; the window hides 8 rows above and 8 below (crop %s)" % l.game_crop)
	check(l.game.size.y + LAYOUT.GAME_CROP_TOP + LAYOUT.GAME_CROP_BOTTOM == l.game_size.y and l.game.size.x == l.game_size.x, "the crop accounts for exactly the 16 hidden rows")
	check(l.game.get_center().x == 240.0, "game window is centred horizontally on the canvas")
	var all: Array = [l.game, l.frame, l.strip_a, l.strip_b, l.badge_left, l.badge_right, l.left, l.right] + l.slots
	check(all.all(func(r): return device_exact(r)), "all geometry is whole device pixels at 1080p (quarters of a logical pixel)")
	check(whole(l.game) and whole(l.frame), "the window and the frame are on whole logical pixels")
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
	check(l.strip_a == Rect2(111.5, 236, 257, 12) and l.strip_b == Rect2(111.5, 249, 257, 13), "the incoming bar and the status strip are doc 47's rects (%s %s)" % [l.strip_a, l.strip_b])
	check(is_equal_approx(l.strip_a.get_center().x, l.game.get_center().x) and is_equal_approx(l.strip_b.get_center().x, l.game.get_center().x), "both strips are centred on the window")
	check(l.badge_left == Rect2(72.5, 0, 30, 30) and l.badge_right == Rect2(376.25, 0, 30.75, 43.75), "COURSE and ALIVE badges are doc 47's rects")
	check(l.badge_left.position.x >= slots[1].end.x and l.badge_right.end.x <= slots[17].position.x and l.badge_left.position.y == 0.0 and l.badge_right.position.y == 0.0, "badges hang from the top in the inner corners (course left, alive right)")
	check(l.badge_left.end.x <= l.left.end.x and l.badge_right.position.x >= l.right.position.x, "badges are inside their panels")
	check(slots.all(func(r): return r.size == Vector2(32.75, 41.5)), "every slot is 131x166 device px at 1080p: 32.75x41.5 logical")
	var aspect: float = slots[0].size.x / slots[0].size.y
	check(absf(aspect - 131.0 / 166.0) < 0.001, "slots keep the reference's portrait aspect (%s)" % aspect)
	# the grid: columns at x 1.25 / 35.25 / 69.25 (left) and 377.25 / 411.25 / 445.25 (right); rows at y 10.5, 53.5, 96.5, 139.5, 182.5, 225.5
	var xs := {}
	var ys := {}
	for r in slots:
		xs[r.position.x] = true
		ys[r.position.y] = true
	var want_x := [1.25, 35.25, 69.25, 377.25, 411.25, 445.25]
	var want_y := [10.5, 53.5, 96.5, 139.5, 182.5, 225.5]
	var got_x: Array = xs.keys()
	var got_y: Array = ys.keys()
	got_x.sort()
	got_y.sort()
	check(got_x == want_x and got_y == want_y, "grid columns %s and rows %s are doc 47's" % [got_x, got_y])
	check(slots[17].position == Vector2(411.25, 10.5), "the right panel's first pane is the one right of the ALIVE badge (%s)" % slots[17].position)
	check(slots[0].position == Vector2(1.25, 10.5) and slots[16].position.y == 225.5, "the left panel starts top-left and runs row by row")
	# the HUD inside the window
	var hud: Dictionary = l.hud
	for key in ["coins", "item_box", "timer"]:
		check(l.game.encloses(hud[key]), "HUD %s is inside the window (%s)" % [key, hud[key]])
	var sel: Dictionary = hud.selector
	check(l.game.encloses(sel.cross) and l.game.encloses(Rect2(sel.center - Vector2(5, 5), Vector2(10, 10))), "the selector cross and its centre button are inside the window")
	check(not overlaps(hud.coins, hud.timer) and not overlaps(sel.cross, hud.timer) and not overlaps(sel.cross, hud.item_box) and not overlaps(sel.cross, hud.coins), "coins, item box, selector and timer don't overlap each other")
	check(sel.lowest_time.position.y < sel.random.position.y and sel.random.position.y < sel.attackers.position.y and sel.random.position.y == sel.most_coins.position.y, "selector: Lowest Time above, Random and Most Coins on the middle row, Attackers below")
	check(sel.random.end.x <= sel.center.x and sel.most_coins.position.x >= sel.center.x, "selector: Random left of the centre button, Most Coins right of it")
	check(hud.timer.end.x <= l.game.end.x and hud.coins.position.x >= l.game.position.x, "coins sit top-left and the timer top-right")

	# Whole-screen coverage: panes + badges + window + frame + strips never leave the canvas.
	var inside: bool = slots.all(func(r): return Rect2(Vector2.ZERO, l.canvas).encloses(r))
	check(inside, "every slot is on the canvas")
