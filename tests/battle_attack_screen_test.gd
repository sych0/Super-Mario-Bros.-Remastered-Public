extends SceneTree
## The visible attack loop on the real Battle screen, against the real project: the real player's kills
## and the bots' sends become lines and target marks, ACTIVE attacks become enemies in the opponents'
## previews and markers on their panes, attacks aimed at the real player show in the Battle UI (the
## incoming strip) without anything reaching the real game (no enemy spawned, nothing taken from the
## player), a new round clears every visual, and Classic never gets any of it. A headless run has no
## renderer, so pixels are checked in tests/battle_attack_render_test.gd. This is the view on its own:
## BattleIncomingSpawner is switched off, so attacks on the player never become real enemies here (that
## is tests/battle_incoming_game_test.gd).
##   godot --headless --fixed-fps 60 --path . -s tests/battle_attack_screen_test.gd
## Script classes that mention autoloads are only reached through load() (a `-s` script is compiled
## before the autoloads exist).

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const GOOMBA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/Goomba.gd"
const KOOPA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/KoopaTroopa.gd"
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(_session, _sender, _draw) -> int:
	return target
"""

var failures := 0
var G
var BS
var SESSION
var ROUND
var TYPES
var LV
var ATTACK
var FixedPolicy

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

func session():
	return SESSION.current

func screen():
	return BS.instance

func rnd():
	return BS.instance.battle_round

func level_running() -> bool:
	return BS.is_active() and not G.transitioning_scene and is_instance_valid(G.current_level) \
		and G.current_level.scene_file_path == LEVEL_1_1 and G.current_level.get_parent() == BS.instance.game_viewport and player() != null

func on_title() -> bool:
	return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene

func enemies(script_path: String) -> Array:
	var out := []
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and not n.is_queued_for_deletion() and (n.get_script() as Script).resource_path == script_path:
			out.append(n)
	out.sort_custom(func(a, b): return a.global_position.x < b.global_position.x)
	return out

func alive_bot(skip := 0) -> int:
	var seen := 0
	for id in range(1, 35):
		if session().contestants[id].alive:
			if seen == skip:
				return id
			seen += 1
	return -1

func fixed_target(id: int) -> void:
	var p = FixedPolicy.new()
	p.target = id
	session().attacks.targeting = p

## The session's whole incoming picture right now: per contestant, [queued, active] and the strip's rows.
func auth_all() -> Dictionary:
	var out := {}
	for id in 35:
		out[id] = auth_counts(id)
	return out

func auth_rows(id: int) -> Array:
	return session().get_incoming(id).map(func(d): return [d.seq, d.state, d.kind])

## The screen reads the session in its own _process, which runs before the level's BattleHandler steps
## the clock in the same frame: what it shows is the session's state as of the frame before, and so
## never more than one frame behind. So a sample is right if it equals the session's state now or at the
## previous sample.
func lagged(shown, before, now) -> bool:
	return shown == now or shown == before

func auth_counts(id: int) -> Vector2i:
	var q := 0
	var a := 0
	for d in session().get_incoming(id):
		if d.state == 1:
			a += 1
		else:
			q += 1
	return Vector2i(q, a)

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	ROUND = load("res://Scripts/Classes/Battle/BattleRound.gd")
	TYPES = load("res://Scripts/Classes/Battle/BattleEnemyType.gd")
	LV = load("res://Scripts/Classes/LevelClass.gd")
	ATTACK = load("res://Scripts/Classes/Battle/BattleAttack.gd")
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	var settings = root.get_node("Settings")
	var saved_video: Dictionary = settings.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(settings.SETTINGS_DIR)
	ROUND.pre_round_override = 0.0
	load("res://Scripts/Classes/Battle/BattleIncomingSpawner.gd").enabled = false

	await start_battle()
	await test_wiring()
	await test_target_reticle()
	await test_player_send()
	await test_bot_send()
	await test_panes_and_previews()
	await test_player_incoming_ui()
	await test_ui_fidelity()
	await test_round_restart()
	await test_attacks_off()
	await test_classic()

	ROUND.pre_round_override = -1.0
	load("res://Scripts/Classes/Battle/BattleIncomingSpawner.gd").enabled = true
	SESSION.default_attacks_enabled = true
	for key in saved_video:
		settings.file.video[key] = saved_video[key]
	var settings_out := FileAccess.open(settings.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle attack screen test(s) failed" % failures)
	else:
		print("All Battle attack screen tests passed")
	quit(1 if failures > 0 else 0)

func start_battle() -> void:
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return on_title(), 900)
	current_scene.start_battle()
	var up: bool = await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING, 1500)
	await frames(5)
	check(up, "Battle is running World 1-1 with the real player")
	quiet_bots()

## Only what a test sends exists: no bot sends, and nothing that is sent can change how a bot plays.
func quiet_bots() -> void:
	session().attacks.bots_send = false
	session().attacks.pressure_enabled = false

# ---- wiring ----------------------------------------------------------------------------------------------------

func test_wiring() -> void:
	print("-- wiring")
	var sc = screen()
	check(sc.attack_view != null and sc.attack_view.session == session(), "the screen has an attack presentation, reading this round's session")
	check(sc.attack_layer != null and sc.attack_layer.view == sc.attack_view and sc.incoming_strip.view == sc.attack_view, "the attack layer and the incoming strip show it")
	check(sc.attack_layer.get_parent() == sc and sc.incoming_strip.get_parent() == sc, "both are part of the Battle canvas (not of the game window)")
	check(sc.attack_layer.size == Vector2(480, 270) and sc.attack_layer.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the layer covers the 480x270 canvas and takes no input")
	var strip: Rect2 = sc.layout.strip_a
	check(Rect2(sc.incoming_strip.position, sc.incoming_strip.size) == strip, "the incoming strip sits exactly in the reference's strip A %s" % [strip])
	check(sc.game_viewport.size == Vector2i(256, 240) and sc.game_container.size == Vector2(256, 240), "the game window is still the contained 256x240 viewport")
	check(sc.attack_layer.find_children("*", "", true, false).is_empty() and sc.attack_view.flights.is_empty(), "nothing is on screen before the first attack")
	check(not sc.game_viewport.is_ancestor_of(sc.attack_layer) and not sc.game_viewport.is_ancestor_of(sc.incoming_strip), "no attack visual lives inside the game viewport")

# ---- the target reticle and the PROVISIONAL mode keys (doc 47 M-T1) ------------------------------------------------

func key_event(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = true
	return ev

func test_target_reticle() -> void:
	print("-- the target reticle and the provisional mode keys")
	var sc = screen()
	var s = session()
	var ret = sc.target_reticle
	check(ret != null and ret.get_parent() == sc and not sc.game_viewport.is_ancestor_of(ret) and ret.size == Vector2(480, 270) and ret.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the reticle is part of the Battle canvas, covers it and takes no input (not inside the game viewport)")
	check(ret.get_index() > sc.panes[33].get_index() and ret.get_index() < sc.attack_layer.get_index(), "it is drawn over the opponent panes and under the attack lines")
	await frames(3)
	var t: int = s.target_of(0)
	check(ret.visible and ret.target == t and t >= 1 and s.contestants[t].alive, "while playing it is on the player's target pane (#%d)" % t)
	var shown := 0
	for node in sc.find_children("TargetReticle", "", true, false):
		if node.visible:
			shown += 1
	check(shown == 1 and sc.panes[t - 1].ko == false, "exactly one reticle, on a living pane")
	# the mode keys
	check(s.player_target_mode == BattleTargeting_Mode().RANDOM and sc.selector.mode == BattleTargeting_Mode().RANDOM and sc.selector.visible, "the selector shows Random chosen")
	check(sc.get_node_or_null("TargetModeReadout") == null, "the provisional text readout of M-T1 is gone")
	for i in range(1, 35):
		s.contestants[i].time_left = 400
	s.contestants[23].time_left = 90
	root.push_input(key_event(KEY_I))
	await frames(3)
	check(s.player_target_mode == BattleTargeting_Mode().LOWEST_TIME and ret.target == 23, "the I key selects Lowest Time and the reticle goes to the lowest time (#23)")
	check(sc.selector.mode == BattleTargeting_Mode().LOWEST_TIME and sc.selector.age < sc.selector.FADE_END and sc.selector.opacity() > sc.selector.REST_ALPHA, "the selector follows, and lights up (age %.2f, opacity %.2f)" % [sc.selector.age, sc.selector.opacity()])
	root.push_input(key_event(KEY_K))
	await frames(3)
	check(s.player_target_mode == BattleTargeting_Mode().ATTACKERS and ret.visible and ret.target == s.target_of(0), "the K key selects Attackers")
	var before_mode: int = s.player_target_mode
	root.push_input(key_event(KEY_L))
	await frames(3)
	check(s.player_target_mode == before_mode and sc.selector.mode == before_mode and sc.selector.refused_mode == BattleTargeting_Mode().MOST_COINS and sc.selector.refuse_age < sc.selector.REFUSE_SECONDS, "the L key (Most Coins) is refused: the mode stays and the pill shows it is not available")
	var echo := key_event(KEY_J)
	echo.echo = true
	root.push_input(echo)
	await frames(2)
	check(s.player_target_mode == before_mode, "a held key (echo) does nothing")
	root.push_input(key_event(KEY_J))
	await frames(3)
	check(s.player_target_mode == BattleTargeting_Mode().RANDOM, "the J key selects Random again")
	# the pause menu: no changes while paused, and the state is untouched
	var tick: int = s.tick_count
	G.game_paused = true
	paused = true # what the pause menu does: the tree stops, and with it the Battle clock
	check(not sc.select_target_mode(BattleTargeting_Mode().LOWEST_TIME) and s.player_target_mode == BattleTargeting_Mode().RANDOM, "a mode cannot be selected while the game is paused")
	await frames(30)
	check(s.tick_count == tick and s.player_target_mode == BattleTargeting_Mode().RANDOM and s.target_of(0) == ret.target, "pausing leaves the mode, the target and the reticle as they were")
	paused = false
	G.game_paused = false
	# a KO of the target moves the reticle at once and it is never on the KO pane
	var victim: int = s.target_of(0)
	s.report_ko(victim, SESSION.KoCause.HAZARD)
	await frames(3)
	check(ret.target != victim and ret.target == s.target_of(0) and ret.visible, "when the target is KO'd the reticle moves on with it (#%d -> #%d)" % [victim, ret.target])
	var on_ko := false
	for i in range(0, 120):
		await process_frame
		if ret.visible and (not s.contestants[ret.target].alive or sc.panes[ret.target - 1].ko):
			on_ko = true
	check(not on_ko, "over two seconds the reticle is never on a KO'd pane")
	# the reticle only shows while the round is being set up or played
	var live_state: int = rnd().state
	var states_ok := true
	for st in [ROUND.State.LOADING, ROUND.State.ROUND_OVER, ROUND.State.RESULTS]:
		rnd().state = st
		if sc._reticle_target() != 0:
			states_ok = false
	rnd().state = ROUND.State.PRE_ROUND
	var in_pre_round: bool = sc._reticle_target() == s.target_of(0) and sc._reticle_target() > 0
	rnd().state = live_state
	check(states_ok and in_pre_round and sc._reticle_target() == s.target_of(0), "it shows in PRE_ROUND (on the target during the countdown) and PLAYING, and never in LOADING, ROUND_OVER or RESULTS")
	s.set_player_target_mode(BattleTargeting_Mode().RANDOM)

## BattleTargeting.Mode, reached through load() (a `-s` script is compiled before the project's classes exist).
func BattleTargeting_Mode():
	return load("res://Scripts/Classes/Battle/BattleTargeting.gd").Mode

# ---- the real player's send ------------------------------------------------------------------------------------

func test_player_send() -> void:
	print("-- the real player sends an enemy")
	var sc = screen()
	var s = session()
	var target := alive_bot(4)
	fixed_target(target)
	var goombas := enemies(GOOMBA_SCRIPT)
	goombas[0].stomped_on(player())
	await process_frame
	var a: Dictionary = s.attacks.attack_history()[0]
	var view = sc.attack_view
	check(view.flights.size() == 1 and view.flights[0].seq == a.seq and view.flights[0].sender == 0, "a real stomp becomes one flight, from the real player, with the attack's sequence id")
	check(view.flights[0].target == a.target and a.target == target and view.flights[0].kind == TYPES.Kind.GOOMBA,
		"it is aimed at the authoritative recipient (#%d) and carries a Goomba" % target)
	check(view.marked_ids() == [target] and view.target_strength(target) > 0.9, "that opponent's pane is the marked target")
	await process_frame
	check(sc.target_reticle.target == target and sc.target_reticle.visible, "and the reticle is on it: the player's target is the recipient of the send")
	var layer_rect: Rect2 = sc.layout.slots[target - 1]
	var landing: Vector2 = load("res://Scripts/Classes/Battle/BattleAttackGeometry.gd").landing_point(sc.layout, 0, target)
	check(layer_rect.has_point(landing) and sc.attack_layer.view == view, "the layer draws its line to a point inside that pane")
	await frames(3)
	check(sc.panes[target - 1].incoming == Vector2i(1, 0) and auth_counts(target) == Vector2i(1, 0), "the pane shows one queued enemy, as the session has it")
	check(sc.panes[target - 1].incoming == view.counts(target), "(the pane's marker is the presentation's count)")
	var others_clear := true
	for i in sc.panes.size():
		if i + 1 != target and sc.panes[i].incoming != Vector2i.ZERO:
			others_clear = false
	check(others_clear, "no other pane shows anything")
	await frames(70) # past the line's travel and linger
	check(view.flights.is_empty() and view.marked_ids().is_empty(), "the line is brief: it is gone within a second")
	check(view.records[a.seq].state == ATTACK.State.QUEUED or view.records[a.seq].state == ATTACK.State.ACTIVE, "(the attack itself goes on: it is not tied to the line)")

# ---- a bot's send ----------------------------------------------------------------------------------------------

func test_bot_send() -> void:
	print("-- a bot sends to a bot")
	var sc = screen()
	var s = session()
	var sender := alive_bot(1)
	var target := alive_bot(9)
	fixed_target(target)
	var a = s.report_enemy_defeat(sender, TYPES.Kind.KOOPA)
	await process_frame
	var f = sc.attack_view.flight_of(a.seq)
	check(f != null and f.sender == sender and f.target == target and f.kind == TYPES.Kind.KOOPA, "a bot-to-bot send is a flight from #%d to #%d" % [sender, target])
	var geo = load("res://Scripts/Classes/Battle/BattleAttackGeometry.gd")
	check((sc.layout.slots[sender - 1] as Rect2).has_point(geo.launch_point(sc.layout, f.sender, f.target)) and (sc.layout.slots[target - 1] as Rect2).has_point(geo.landing_point(sc.layout, f.sender, f.target)),
		"it runs from the sender's pane to the target's")
	# three bots send at the same moment to three different bots
	var picks := [alive_bot(12), alive_bot(15), alive_bot(18)]
	var shots := []
	for i in 3:
		fixed_target(picks[i])
		shots.append(s.report_enemy_defeat(alive_bot(20 + i), TYPES.Kind.GOOMBA if i != 1 else TYPES.Kind.KOOPA))
	await process_frame
	var distinct := {}
	var exact := true
	for i in 3:
		var g = sc.attack_view.flight_of(shots[i].seq)
		if g == null or g.target != picks[i] or g.kind != shots[i].kind:
			exact = false
		distinct[shots[i].seq] = true
	check(exact and distinct.size() == 3 and sc.attack_view.flights.size() >= 3, "three simultaneous sends are three separate flights, each with its own target and enemy")
	await frames(80)

# ---- panes and previews ------------------------------------------------------------------------------------------

func test_panes_and_previews() -> void:
	print("-- the target pane and its preview")
	var sc = screen()
	var s = session()
	# a fresh, exact picture: a Goomba and a Koopa to the same opponent
	var target := alive_bot(6)
	fixed_target(target)
	var tick0: int = s.tick_count
	var a = s.report_enemy_defeat(alive_bot(2), TYPES.Kind.GOOMBA)
	var b = s.report_enemy_defeat(alive_bot(3), TYPES.Kind.KOOPA)
	await frames(10)
	var q0: Vector2i = sc.panes[target - 1].incoming
	check(q0.x >= 2, "both enemies are queued on that pane's marker (%s)" % [q0])
	var shown := false
	var shown_kinds := []
	var counts_match := true
	var panes_match := true
	var frames_run := 0
	var track = sc.driver.tracks[target]
	var before := auth_all()
	while s.tick_count < tick0 + 14 and frames_run < 60 * 20:
		await process_frame
		frames_run += 1
		var now := auth_all()
		for i in sc.panes.size():
			if not lagged(sc.panes[i].incoming, before[i + 1], now[i + 1]):
				panes_match = false
		before = now
		if track.invader_for(a.seq) != null and track.invader_for(b.seq) != null and not shown:
			shown = true
			for inv in sc.cells[target - 1].frame.invaders:
				shown_kinds.append(inv.kind)
			shown_kinds.sort()
			# these two enemies are in this opponent's preview and in no other
			for id in sc.driver.tracks:
				if id != target and (sc.driver.tracks[id].invader_for(a.seq) != null or sc.driver.tracks[id].invader_for(b.seq) != null):
					counts_match = false
	check(panes_match, "every pane's marker equals the session's queued / active counts, on every frame (at most one frame behind)")
	check(shown and shown_kinds == [TYPES.Kind.GOOMBA, TYPES.Kind.KOOPA], "after its activation the opponent's preview shows a Goomba and a Koopa (the picture trails the session by %d s)" % int(sc.driver.LAG))
	check(counts_match, "and no other opponent's preview shows them")
	check(track.invader_for(a.seq) == null and track.invader_for(b.seq) == null and sc.panes[target - 1].incoming == Vector2i.ZERO and auth_counts(target) == Vector2i.ZERO,
		"once the session resolves them the preview and the marker are clear again")
	check(s.attacks.history[a.seq].resolution == ATTACK.Resolution.EXPIRED and s.attacks.history[b.seq].resolution == ATTACK.Resolution.EXPIRED, "(they ended by their authoritative timers)")

# ---- attacks on the real player ------------------------------------------------------------------------------------

func test_player_incoming_ui() -> void:
	print("-- attacks on the real player are visible, and only visible")
	var sc = screen()
	var s = session()
	fixed_target(0)
	var enemy_nodes: Array = get_nodes_in_group("Enemies").duplicate()
	var enemy_ids := enemy_nodes.map(func(n): return n.get_instance_id())
	var p = player()
	var lives: int = G.lives
	var score: int = G.score
	var coins: int = G.coins
	var time0: int = s.get_player().time_left
	var tick0: int = s.tick_count
	var power: String = p.power_state.name if p.get("power_state") != null else ""
	var pos: Vector2 = p.global_position
	var made := []
	for i in 4:
		made.append(s.report_enemy_defeat(alive_bot(i), TYPES.Kind.KOOPA if i % 2 == 0 else TYPES.Kind.GOOMBA))
	await process_frame
	var strip = sc.incoming_strip
	check(strip.rows.size() == 4 and strip.counts == Vector2i(4, 0), "four attacks on the real player are four icons, all queued (%s)" % [strip.counts])
	var kinds_ok := true
	for i in 4:
		if strip.rows[i].seq != made[i].seq or strip.rows[i].kind != made[i].kind:
			kinds_ok = false
	check(kinds_ok, "each icon carries the attack's sequence id and enemy type, in send order")
	check(sc.attack_view.marked_ids().has(0) and sc.attack_view.flights.size() >= 4, "and the attacks are lines that land on the game window")
	var saw_flash := false
	var strip_matches := true
	var active_seen := false
	var rows_before := auth_rows(0)
	var counts_before := auth_counts(0)
	for i in 60 * 5:
		await process_frame
		var rows: Array = strip.rows.map(func(r): return [r.seq, r.state, r.kind])
		var rows_now := auth_rows(0)
		var counts_now := auth_counts(0)
		if not lagged(rows, rows_before, rows_now) or not lagged(strip.counts, counts_before, counts_now):
			strip_matches = false
		rows_before = rows_now
		counts_before = counts_now
		rows = strip.rows
		if rows.size() > 0 and rows[0].state == ATTACK.State.ACTIVE:
			active_seen = true
			if rows[0].flash > 0.5:
				saw_flash = true
	check(strip_matches, "the strip's icons, states, enemy types and counts equal the authoritative queue on every frame (at most one frame behind)")
	check(active_seen and saw_flash, "an attack going QUEUED -> ACTIVE is shown, and its icon flashes")
	check(strip.counts == Vector2i(1, 3) and auth_counts(0) == Vector2i(1, 3), "three are active and the fourth waits: 1 queued / 3 active")
	await frames(60 * 8)
	check(strip.counts == Vector2i(1, 3), "they stay active: nothing resolves an attack on the real player by time")
	# the real game is untouched
	var now_ids: Array = get_nodes_in_group("Enemies").map(func(n): return n.get_instance_id())
	check(now_ids == enemy_ids, "no enemy was spawned into the game window (%d enemies before and after, same nodes)" % enemy_ids.size())
	var spawned := false
	for n in sc.game_viewport.find_children("*", "", true, false):
		if n.has_meta("battle_attack_seq") or str(n.name).to_lower().contains("invader"):
			spawned = true
	check(not spawned, "...and nothing in the game viewport is an attack's enemy")
	check(G.lives == lives and G.score == score and G.coins == coins, "lives, score and coins are unchanged")
	var elapsed: int = s.tick_count - tick0
	check(s.get_player().time_left == time0 - elapsed and elapsed >= 12, "the player's time ran down only by the %d Battle seconds that passed" % elapsed)
	check(is_instance_valid(p) and not p.is_dead and s.get_player().alive and (p.power_state.name if p.get("power_state") != null else "") == power, "the player is alive and has the same power state")
	check(p.global_position.distance_to(pos) < 1.0, "and has not been moved or pushed")
	# the game resolves one attack: its icon goes
	var first: int = strip.rows[0].seq
	check(s.resolve_player_incoming(first, ATTACK.Resolution.DEFEATED_BY_PLAYER), "(the game resolves one)")
	await frames(3)
	check(strip.rows.size() == 3 and not strip.rows.any(func(r): return r.seq == first) and strip.counts == auth_counts(0), "its icon is gone and the waiting one took its place (%s)" % [strip.counts])

# ---- the SMB35 UI pass on the real screen (doc 50) ---------------------------------------------------------------------

func test_ui_fidelity() -> void:
	print("-- the Battle HUD, selector, status strip and incoming bar on the real screen")
	var sc = screen()
	var s = session()
	var Mode = BattleTargeting_Mode()
	s.attacks.targeting = load("res://Scripts/Classes/Battle/BattleTargetingModes.gd").new() # (the earlier tests pinned every send to one target)
	var sel = sc.selector
	check(sel.get_parent() == sc.hud and sc.hud.get_parent() == sc and sc.hud.get_index() > sc.game_clip.get_index() and sc.hud.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the selector is part of the HUD over the game window, and takes no input")
	check(sc.get_node_or_null("TargetModeReadout") == null, "the provisional text readout is gone")
	check(sc.hud.coins == G.coins and sc.hud.time_left == s.get_player().time_left, "the HUD shows the classic game's coin count and the player's Battle time")
	# the selector follows the session, and the keys, and what the session refuses
	s.set_player_target_mode(Mode.ATTACKERS)
	await frames(2)
	check(sel.mode == Mode.ATTACKERS and sel.age < 0.5, "a mode the session changes shows in the selector at once")
	var tick0: int = s.tick_count
	# a pause holds the selector's and the reticle's animation (and the keys do nothing)
	sc.select_target_mode(Mode.LOWEST_TIME)
	await frames(2)
	var age0: float = sel.age
	var punch0: float = sc.target_reticle.pulse_age
	G.game_paused = true
	paused = true
	await frames(30)
	check(is_equal_approx(sel.age, age0) and is_equal_approx(sc.target_reticle.pulse_age, punch0), "a pause freezes the selector's fade and the reticle's punch (age %.2f, %.2f)" % [sel.age, sc.target_reticle.pulse_age])
	check(not sc.select_target_mode(Mode.RANDOM) and s.player_target_mode == Mode.LOWEST_TIME and sel.mode == Mode.LOWEST_TIME, "...and no mode can be chosen meanwhile")
	paused = false
	G.game_paused = false
	await frames(30)
	check(sel.age > age0 + 0.3, "after the pause the animation runs on")
	# Most Coins: shown as unavailable, refused, the mode is kept
	var rng_before: int = s.attacks.player_rng.state if s.attacks.get("player_rng") != null else 0
	var before: int = s.player_target_mode
	check(not sel.available[Mode.MOST_COINS] and not s.target_mode_available(Mode.MOST_COINS), "Most Coins is drawn as unavailable (the session says so)")
	check(not sc.select_target_mode(Mode.MOST_COINS) and s.player_target_mode == before and sel.mode == before and sel.refused_mode == Mode.MOST_COINS and sel.refuse_age < 0.2, "choosing Most Coins is refused: the mode is kept and its pill reacts")
	check((s.attacks.player_rng.state if s.attacks.get("player_rng") != null else 0) == rng_before, "no random stream moved")
	# every key of the cross reaches the selector through the screen
	for pair in [[KEY_J, Mode.RANDOM], [KEY_I, Mode.LOWEST_TIME], [KEY_K, Mode.ATTACKERS]]:
		root.push_input(key_event(pair[0]))
		await frames(2)
		check(s.player_target_mode == pair[1] and sel.mode == pair[1] and sel.opacity() == 1.0, "the %s key selects %s: the selector goes opaque on that frame" % [OS.get_keycode_string(pair[0]), BattleTargeting.mode_name(pair[1])])
	sc.select_target_mode(Mode.RANDOM)
	# the status strip: the eye counts who is aiming at the player; WATCH OUT! follows a bot's send
	var strip = sc.status_strip
	await frames(3)
	check(strip.eye == s.attackers_of(0).size() and strip.get_index() > sc.incoming_strip.get_index() - 1, "the eye counter is the number of opponents aiming at the player (%d)" % strip.eye)
	await frames(60 * 4)
	check(not strip.watch_out, "(WATCH OUT! is off while no bot is sending)")
	fixed_target(0)
	s.report_enemy_defeat(alive_bot(7), TYPES.Kind.KOOPA)
	await frames(3)
	check(strip.watch_out and sc.attack_view.watch_out(), "a bot sends an enemy at the player: WATCH OUT! shows")
	await frames(60 * 3)
	check(not strip.watch_out, "...and goes again about a second after the line has landed")
	fixed_target(alive_bot(9))
	s.report_enemy_defeat(0, TYPES.Kind.GOOMBA)
	await frames(10)
	check(not strip.watch_out, "the player's own send never shows it")
	# the incoming bar: phases and positions on the real screen
	fixed_target(0)
	var made = s.report_enemy_defeat(alive_bot(11), TYPES.Kind.GOOMBA)
	await frames(6)
	var bar = sc.incoming_strip
	var row: Dictionary = bar.rows[bar.rows.size() - 1]
	check(row.seq == made.seq and row.phase == BattleAttackPresentationPhase().QUEUED, "a new attack on the player is a QUEUED icon at the bar's right end")
	var xs: PackedFloat32Array = bar.place_all(bar.items, bar.size.x)
	check(xs[xs.size() - 1] > bar.size.x * 0.6, "...near the right end (x %.1f of %.1f)" % [xs[xs.size() - 1], bar.size.x])
	check(bar.size == sc.layout.strip_a.size and bar.position == sc.layout.strip_a.position, "the bar is the reference's strip A")
	# a power-up shows in the bar's player icon
	bar.set_power(2)
	check(bar.power == 2, "the bar's player icon follows the power state")
	bar.set_power(int(G.player_power_states[0]))

func BattleAttackPresentationPhase():
	return load("res://Scripts/Classes/Battle/BattleAttackPresentation.gd").Phase

# ---- a new round -----------------------------------------------------------------------------------------------------

func test_round_restart() -> void:
	print("-- a new round clears every visual")
	var sc = screen()
	var s = session()
	var old_view = sc.attack_view
	var old_session = s
	fixed_target(alive_bot(2))
	s.report_enemy_defeat(0, TYPES.Kind.GOOMBA) # a line is in the air when the round ends
	fixed_target(0)
	s.report_enemy_defeat(alive_bot(), TYPES.Kind.KOOPA)
	await frames(2)
	check(not old_view.flights.is_empty() and not sc.incoming_strip.rows.is_empty(), "(there are lines and icons on screen)")
	player().die()
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1500)
	check(sc.incoming_strip.rows.is_empty() and sc.incoming_strip.counts == Vector2i.ZERO, "when the player is out nothing is left aimed at them: the strip is empty")
	rnd().time_in_state = ROUND.RESULTS_MAX_SECONDS
	await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING and session() != old_session, 1800)
	await frames(5)
	var fresh = sc.attack_view
	check(fresh != null and fresh != old_view and fresh.session == session() and fresh.session != old_session, "the new round has a new presentation, on the new session")
	check(fresh.flights.is_empty() and fresh.records.is_empty() and fresh.marked_ids().is_empty() and fresh.signature() == "0:0", "with no lines, records, marks or history")
	check(sc.attack_layer.view == fresh and sc.incoming_strip.view == fresh and sc.incoming_strip.rows.is_empty() and sc.incoming_strip.counts == Vector2i.ZERO,
		"the layer and the strip follow it and show nothing")
	var clean := true
	for pane in sc.panes:
		if pane.incoming != Vector2i.ZERO:
			clean = false
	check(clean, "no pane keeps a marker")
	var tracks_clean := true
	for id in sc.driver.tracks:
		if not sc.driver.tracks[id].invaders.is_empty():
			tracks_clean = false
	check(tracks_clean and sc.driver.session == session(), "and no preview keeps an incoming enemy (its tracks are the new round's)")
	check(session().player_target_mode == BattleTargeting_Mode().RANDOM and sc.target_reticle.target == session().target_of(0) and sc.target_reticle.visible, "the new round starts in Random with the reticle on its own first target")
	check(sc.selector.mode == BattleTargeting_Mode().RANDOM and not sc.status_strip.watch_out and sc.status_strip.eye == session().attackers_of(0).size() and sc.incoming_strip.ghosts.is_empty(), "the selector, WATCH OUT!, the eye counter and the bar start the new round clean")
	var cards := 0
	for pane in sc.panes:
		if pane.marked or pane.ko or pane.is_animating():
			cards += 1
	check(cards == 0, "no KO card of the finished round survives into the new one")
	check(sc.badge_alive.value == "%d/35" % session().alive_count and sc.badge_alive.value == "35/35", "the alive badge reads 35/35 again")
	quiet_bots()

# ---- attacks off -----------------------------------------------------------------------------------------------------

func test_attacks_off() -> void:
	print("-- attacks off")
	SESSION.default_attacks_enabled = false
	var old_session = session()
	player().die()
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1500)
	rnd().time_in_state = ROUND.RESULTS_MAX_SECONDS
	await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING and session() != old_session, 1800)
	await frames(10)
	var sc = screen()
	check(not session().attacks.enabled and sc.attack_view == null, "with the attack loop off there is no attack presentation")
	check(not sc.target_reticle.visible and not sc.selector.visible and not session().set_player_target_mode(BattleTargeting_Mode().LOWEST_TIME), "...no reticle, no selector, and no mode to select")
	check(sc.incoming_strip.rows.is_empty() and sc.attack_layer.view == null, "and the strip and the layer show nothing")
	await frames(60 * 5)
	check(session().events.filter(func(e): return e.type >= SESSION.EventType.SENT).is_empty() and sc.attack_view == null, "five seconds of play produce no attack events and no visuals")
	SESSION.default_attacks_enabled = true

# ---- Classic ---------------------------------------------------------------------------------------------------------

func test_classic() -> void:
	print("-- Classic")
	var old_session = session()
	player().die()
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1500)
	var Handler = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	Handler.quit_battle()
	await wait_until(func(): return on_title(), 1800)
	await frames(10)
	G.current_campaign = "SMB1"
	G.current_game_mode = G.GameMode.CAMPAIGN
	G.clear_saved_values()
	G.world_num = 1
	G.level_num = 1
	G.reset_values()
	LV.first_load = true
	G.transition_to_scene(LEVEL_1_1)
	await wait_until(func(): return current_scene != null and current_scene.scene_file_path == LEVEL_1_1 and not G.transitioning_scene and player() != null, 900)
	await frames(30)
	check(not BS.is_active() and SESSION.current == null, "Classic: no Battle screen, no session")
	check(root.find_children("AttackLayer", "", true, false).is_empty() and root.find_children("IncomingStrip", "", true, false).is_empty(), "Classic: no attack layer or incoming strip exists anywhere")
	var goombas := enemies(GOOMBA_SCRIPT)
	goombas[0].stomped_on(player())
	goombas[1].die_from_object(player())
	await frames(5)
	check(SESSION.current == null and root.find_children("AttackLayer", "", true, false).is_empty(), "Classic defeats create no Battle state and no attack presentation")
	# a stale session object does not make Classic show anything either
	SESSION.begin(5)
	goombas[2].die_from_object(player())
	await frames(5)
	check(SESSION.current.events.is_empty() and root.find_children("AttackLayer", "", true, false).is_empty() and root.find_children("IncomingStrip", "", true, false).is_empty(),
		"even with a stale session around, Classic kills log nothing and draw nothing")
	SESSION.clear()
	G.transition_to_scene(TITLE)
	await wait_until(func(): return on_title(), 900)
	G.current_game_mode = G.GameMode.NONE
	old_session = null
