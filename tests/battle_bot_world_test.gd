extends SceneTree
## Real bot worlds (doc 56): a Battle opponent plays the real game. Each world is the real level scene with its own real Mario,
## in its own World2D, driven through a pad by its brain; these tests check it against the requirements of the vertical slice:
##   - the world seam passes through to the real game's state when no bot world exists, and a bot world never touches it
##     (score, coins, lives, time, power states, current level, pause, sounds, camera limits, pipes, persistence);
##   - the real 1-1 is loaded, Mario is the real Player reading the bot's pad, he runs and jumps through real physics,
##     enemies wake when the bot's camera reaches them and sleep when it leaves them (no renderer: headless);
##   - deaths are the game's: a Goomba, a pit, the session's time-out; the KO is the session's at once, the card follows the animation;
##   - a flagpole clear is the session's LEVEL_CLEAR and the world really enters World 1-2 (its real scene);
##   - a bot's stomp sends an enemy like the player's, and an enemy sent to a bot becomes a real enemy in its level;
##   - runs are deterministic, and a world plays exactly the same whether or not other worlds run beside it.
##   godot --headless --fixed-fps 60 --path . -s tests/battle_bot_world_test.gd
## Script classes that mention autoloads are only reached through load() (a `-s` script is compiled before the autoloads exist).

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const LEVEL_1_2 := "res://Scenes/Levels/SMB1/World1/1-2.tscn"
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 2
func choose(session, sender, _draw) -> int:
	if sender != target:
		return target
	for c in session.contestants:
		if c.alive and c.id != sender:
			return c.id
	return -1
"""

var failures := 0
var G
var AM
var SESSION
var WORLD
var GW
var PAD
var ATTACK
var TYPES
var FixedPolicy

func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + msg)
	else:
		print("ok:   " + msg)

func physics_frames(n: int) -> void:
	for i in n:
		await physics_frame

## Runs `worlds` for `seconds`, stepping `session` once a second like BattleHandler does. Stops early when `until` is true.
func run(session, seconds: float, until := Callable()) -> void:
	var acc := 0.0
	for f in int(seconds * 60.0):
		await physics_frame
		acc += 1.0 / 60.0
		if acc >= 1.0 - 1e-6:
			acc -= 1.0
			session.step()
		if until.is_valid() and until.call():
			return

func make_world(session, id: int, seed_value: int):
	session.set_world_driven(id)
	var w = WORLD.new(id, session, seed_value)
	root.add_child(w)
	w.start(0)
	return w

func free_worlds(worlds: Array) -> void:
	for w in worlds:
		if is_instance_valid(w):
			root.remove_child(w)
			w.free()
	await physics_frames(2)

## Everything a bot world must never change in the real player's game.
func globals() -> Dictionary:
	var pl = load("res://Scripts/Classes/Entities/Player.gd")
	var cam = load("res://Scripts/Parts/CameraHandler.gd")
	var pipe = load("res://Scripts/Classes/Entities/PipeArea.gd")
	var lp = load("res://Scripts/Classes/Components/LevelPersistance.gd")
	var cp = load("res://Scripts/Parts/Checkpoint.gd")
	return {"score": G.score, "coins": G.coins, "lives": G.lives, "time": G.time, "power": G.player_power_states,
		"level": G.current_level, "theme": G.level_theme, "time_of_day": G.theme_time, "can_pause": G.can_pause,
		"can_time_tick": G.can_time_tick, "death_load": G.death_load, "world": G.world_num, "level_num": G.level_num,
		"paused": paused, "sfx": AM.active_sfxs.size(), "override": AM.current_music_override,
		"cam_limit": pl.camera_right_limit, "cam_locked": cam.cam_locked, "pipe_id": pipe.exiting_pipe_id,
		"pipes_open": pipe.can_enter, "persist": str(lp.active_nodes), "checkpoints": str(cp.passed_checkpoints)}

func _initialize() -> void:
	_run()

func _run() -> void:
	for i in 5:
		await process_frame
	G = root.get_node("Global")
	AM = root.get_node("AudioManager")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	WORLD = load("res://Scripts/Classes/Battle/BattleBotWorld.gd")
	GW = load("res://Scripts/Classes/GameWorld.gd")
	PAD = load("res://Scripts/Classes/Battle/BattleBotPad.gd")
	ATTACK = load("res://Scripts/Classes/Battle/BattleAttack.gd")
	TYPES = load("res://Scripts/Classes/Battle/BattleEnemyType.gd")
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	G.current_game_mode = G.GameMode.BATTLE

	test_seam_without_bots()
	await test_boot_and_isolation()
	await test_enemy_death()
	await test_pit_death()
	await test_time_out()
	await test_clear_and_next_course()
	await test_sends_and_incoming()
	await test_determinism_and_independence()

	G.current_game_mode = G.GameMode.NONE
	if failures > 0:
		printerr("%d Battle bot world test(s) failed" % failures)
	else:
		print("All Battle bot world tests passed")
	quit(1 if failures > 0 else 0)

# ---- the seam ---------------------------------------------------------------------------------------------------------------

func test_seam_without_bots() -> void:
	print("-- the world seam with no bot world")
	var n := Node2D.new()
	root.add_child(n)
	check(GW.bot_worlds == 0 and GW.bot_of(n) == null and not GW.is_bot(n), "no bot world: every node is in the real game's world")
	check(GW.level(n) == G.current_level and GW.owns_globals(n), "the real game's level and state are its own")
	check(not PAD.claims(0) and not PAD.claims(3) and not PAD.claims(100), "no pad is claimed: every player id reads the InputMap")
	n.free()

# ---- a real game, isolated --------------------------------------------------------------------------------------------------

func test_boot_and_isolation() -> void:
	print("-- the real 1-1 in its own world, isolated from the real player's game")
	var before := globals()
	var session = SESSION.new(4242)
	session.attacks.bots_send = false
	var w = make_world(session, 1, 4242)
	await physics_frames(3)
	check(w.level != null and w.level.scene_file_path == LEVEL_1_1, "the world runs the real World 1-1 scene")
	check(w.player != null and w.player.get_script().resource_path.ends_with("Player.gd"), "its Mario is the real Player")
	check(w.player.player_id == PAD.ID_BASE + 1 and PAD.claims(w.player.player_id), "Mario reads this opponent's pad (player id %d)" % w.player.player_id)
	check(w.viewport.world_2d != root.world_2d and w.viewport.world_2d.space != root.world_2d.space, "the world has its own World2D and physics space")
	check(GW.bot_of(w.player) == w and GW.level(w.player) == w.level and G.current_level == before.level, "the seam finds Mario's own world and level; Global.current_level is untouched")
	check(w.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "the world never renders by itself")
	var start_x: float = w.player.global_position.x
	var jumps := 0
	var run_frames := 0
	var was_jumping := false
	var woke := false
	for f in 360:
		await physics_frame
		if f % 60 == 59:
			session.step()
		run_frames += int(w.pad.pressed("run"))
		var j: bool = w.pad.pressed("jump")
		if j and not was_jumping:
			jumps += 1
		was_jumping = j
		for e in w.enemies:
			if is_instance_valid(e) and e.can_process():
				woke = true
	var x: float = w.player.global_position.x
	check(x > start_x + 300.0, "in 6 s Mario is %.0f px further on, moved by the real physics from the pad's buttons" % (x - start_x))
	check(jumps >= 1 and run_frames > 0, "the brain used the jump (%d presses) and run (%d frames) buttons" % [jumps, run_frames])
	check(woke, "an enemy woke as the bot's camera reached it (no renderer: the world works its own screen out)")
	var asleep_behind := false
	for e in w.enemies:
		if is_instance_valid(e) and e.global_position.x < w.view_rect().position.x - 64.0 and not e.can_process():
			asleep_behind = true
	var asleep_ahead := false
	for e in w.enemies:
		if is_instance_valid(e) and e.global_position.x > w.view_rect().end.x + 64.0 and not e.can_process():
			asleep_ahead = true
	check(asleep_ahead, "enemies far ahead of the bot's screen are still asleep")
	check(session.contestants[1].progress > 0.05, "the session hears the bot's live progress (%.2f)" % session.contestants[1].progress)
	var after := globals()
	var changed := []
	for k in before:
		if str(before[k]) != str(after[k]):
			changed.append("%s: %s -> %s" % [k, before[k], after[k]])
	check(changed.is_empty(), "nothing of the real player's game changed: %s" % (str(changed) if not changed.is_empty() else "score, coins, lives, time, power, level, theme, pause, sounds, music, camera limits, pipes, persistence"))
	await free_worlds([w])
	check(GW.bot_worlds == 0 and not PAD.claims(PAD.ID_BASE + 1), "a freed world leaves no bot world and no pad behind")

# ---- deaths are the game's -------------------------------------------------------------------------------------------------

func test_enemy_death() -> void:
	print("-- a Goomba kills the bot (it only holds right)")
	var session = SESSION.new(77)
	session.attacks.bots_send = false
	var w = make_world(session, 1, 77)
	w.script_buttons = func(_w) -> Dictionary: return {"move_right": true, "run": true}
	await run(session, 12.0, func(): return not session.contestants[1].alive)
	check(not session.contestants[1].alive and session.contestants[1].ko_cause == SESSION.KoCause.HAZARD, "the session KO'd the bot (HAZARD) the moment the game killed its Mario")
	check(w.death.has("pit") and not w.death.pit and String(w.death.near).begins_with("Goomba"), "the game's own enemy collision killed him: %s" % str(w.death))
	check(w.player.is_dead and w.player.state_machine.is_state("Dead"), "his Mario is in the game's Dead state")
	check(not w.ko_shown, "the KO card waits for the death animation")
	await run(session, 3.0, func(): return w.ko_shown)
	check(w.ko_shown and w.phase == WORLD.Phase.OUT, "after the animation the pane may show the card; the world has stopped")
	check(not paused, "the real game was never paused by the bot's death")
	await free_worlds([w])

func test_pit_death() -> void:
	print("-- the game's pit rule kills the bot's Mario")
	var session = SESSION.new(78)
	session.attacks.bots_send = false
	var w = make_world(session, 1, 78)
	w.script_buttons = func(_w) -> Dictionary: return {}
	await physics_frames(10)
	w.player.global_position.y = 70.0 # (a test shortcut into the pit: below the level's death line)
	await physics_frames(3)
	check(not session.contestants[1].alive and w.death.get("pit", false), "Normal.handle_death_pits killed him in his own level (pit), the session KO'd him")
	await free_worlds([w])

func test_time_out() -> void:
	print("-- the session's time-out is a real death in the bot's game")
	var session = SESSION.new(79)
	session.attacks.bots_send = false
	var w = make_world(session, 1, 79)
	session.contestants[1].time_left = 2
	await run(session, 3.0, func(): return w.player.is_dead)
	check(not session.contestants[1].alive and session.contestants[1].ko_cause == SESSION.KoCause.TIME, "the session KO'd the bot on time")
	check(w.player.is_dead, "and its Mario died in its game (Player.time_up), as the real player's does")
	await free_worlds([w])

# ---- a clear, and the real next course -------------------------------------------------------------------------------------

func test_clear_and_next_course() -> void:
	print("-- a bot clears 1-1 at the flagpole and enters the real 1-2")
	SESSION.default_attacks_enabled = false
	var session = SESSION.new(11)
	SESSION.default_attacks_enabled = true
	var worlds := []
	for id in range(1, 9):
		worlds.append(make_world(session, id, 11))
	var cleared = null
	var flag_seen := false
	for f in 75 * 60:
		await physics_frame
		if f % 60 == 59:
			session.step()
		for w in worlds:
			if w.phase == WORLD.Phase.CLEARING:
				flag_seen = true
			if cleared == null and w.course == 1:
				cleared = w
		if cleared != null:
			break
	check(cleared != null, "one of 8 bots cleared the real 1-1 within 75 s")
	if cleared == null:
		await free_worlds(worlds)
		return
	var id: int = cleared.contestant_id
	check(flag_seen, "its Mario rode the real flagpole (the FlagPole state) before the cut")
	var clears: Array = session.events.filter(func(e): return e.id == id and e.type == SESSION.EventType.LEVEL_CLEAR)
	check(clears.size() == 1 and session.contestants[id].levels_cleared == 1, "the session logged its LEVEL_CLEAR and counts 1 course")
	check(cleared.scene_path == LEVEL_1_2 and cleared.level.scene_file_path == LEVEL_1_2, "its world now runs the real World 1-2 scene")
	check(cleared.player != null and cleared.player.is_inside_tree() and cleared.player.get_parent() == cleared.level, "a fresh real Mario in the new level")
	check(cleared.theme == "Underground" and cleared.world_num == 1 and cleared.level_num == 2, "1-2 is skinned as its own underground level, not as the real player's")
	var x0: float = cleared.player.global_position.x
	await run(session, 3.0)
	check(cleared.phase == WORLD.Phase.PLAYING and cleared.player.global_position.x > x0 + 40.0, "and plays on in 1-2 (x %.0f -> %.0f)" % [x0, cleared.player.global_position.x])
	check(G.current_level == null and G.level_num == 1 and G.score == 0, "the real game's level, level number and score are untouched")
	await free_worlds(worlds)

# ---- sends ----------------------------------------------------------------------------------------------------------------

func test_sends_and_incoming() -> void:
	print("-- a bot's stomp sends an enemy; an enemy sent to a bot arrives in its real level")
	var session = SESSION.begin(4242) # (the game's kill path reports to the current session)
	session.attacks.bots_send = false
	var policy = FixedPolicy.new()
	policy.target = 2
	session.attacks.targeting = policy
	var a = make_world(session, 1, 4242)
	a.traits.stomp_bias = 1.0 # (this bot always goes for the stomp)
	var b = make_world(session, 2, 4242)
	b.script_buttons = func(_w) -> Dictionary: return {} # (bot 2 waits at the start for what comes)
	await physics_frames(2)
	b.player.can_hurt = false # (and is not hurt, so it is still in when the enemy arrives)
	var sent: Dictionary = {}
	var spawned := false
	for f in 40 * 60:
		await physics_frame
		if f % 60 == 59:
			session.step()
		for e in session.events:
			if e.type == SESSION.EventType.SENT and e.id == 1:
				sent = e
			if e.type == SESSION.EventType.INCOMING_SPAWNED and e.id == 2:
				spawned = true
		if spawned:
			break
	check(not sent.is_empty(), "a real stomp in bot 1's game sent an enemy (SENT from contestant 1)")
	var defeats: Array = session.events.filter(func(e): return e.type == SESSION.EventType.ENEMY_DEFEATED and e.id == 1)
	check(not defeats.is_empty() and session.attacks.player_defeats == 0, "it is bot 1's defeat, never the real player's")
	check(spawned, "the attack on bot 2 became a real enemy in bot 2's level (INCOMING_SPAWNED for 2)")
	if spawned:
		var spawner = b.level.get_node_or_null("BattleIncomingSpawner")
		check(spawner != null and spawner.target == 2 and not spawner.spawn_log.is_empty(), "bot 2's own spawner put it there, from its own camera and physics")
	await free_worlds([a, b])
	SESSION.clear()

# ---- determinism ----------------------------------------------------------------------------------------------------------

func trace_of(ids: Array, seed_value: int, frames: int) -> PackedVector3Array:
	SESSION.default_attacks_enabled = false
	var session = SESSION.new(seed_value)
	SESSION.default_attacks_enabled = true
	var worlds := []
	for id in ids:
		var w = make_world(session, id, seed_value)
		w.record_trace = true
		worlds.append(w)
	await run(session, frames / 60.0)
	var t: PackedVector3Array = worlds[0].trace.duplicate()
	await free_worlds(worlds)
	return t

func test_determinism_and_independence() -> void:
	print("-- the same seed plays the same game, with or without other worlds beside it")
	var alone_1: PackedVector3Array = await trace_of([3], 99, 600)
	var alone_2: PackedVector3Array = await trace_of([3], 99, 600)
	var with_others: PackedVector3Array = await trace_of([3, 4, 5], 99, 600)
	check(alone_1.size() >= 590, "a 10 s trace of bot 3 (Mario's x, y and the buttons, every tick): %d ticks" % alone_1.size())
	check(alone_1 == alone_2, "two runs of the same seed are identical, tick for tick")
	check(alone_1 == with_others, "bot 3 plays exactly the same with bots 4 and 5 running beside it: the worlds are independent")
	var other: PackedVector3Array = await trace_of([3], 100, 600)
	check(other != alone_1, "another round's seed plays differently")
