extends SceneTree
## The real game's side of the Battle attack loop: the real player defeating real enemies inside
## Battle (stomp, kick/fire/star kill, hammer, a Koopa stomped into its shell), exactly-once
## reporting, no reporting outside Battle, attacks aimed at the real player being recorded but never
## spawned into the level, and attack state not surviving into the next round.
##   godot --headless --fixed-fps 60 --path . -s tests/battle_attack_game_test.gd
## Script classes that mention autoloads are only reached through load() (a `-s` script is compiled
## before the autoloads exist).

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const GOOMBA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/Goomba.gd"
const KOOPA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/KoopaTroopa.gd"
const SHELL_SCRIPT := "res://Scripts/Classes/Entities/ShellClass.gd"
const KOOPA_PREFAB := "res://Scenes/Prefabs/Entities/Enemies/GreenKoopaTroopa.tscn"
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(_session, _sender, _rng) -> int:
	return target
"""

var failures := 0
var G
var BS
var HANDLER
var SESSION
var ROUND
var TYPES
var LV
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

func rnd():
	return BS.instance.battle_round

func level_running() -> bool:
	return BS.is_active() and not G.transitioning_scene and is_instance_valid(G.current_level) \
		and G.current_level.scene_file_path == LEVEL_1_1 and G.current_level.get_parent() == BS.instance.game_viewport and player() != null

func on_title() -> bool:
	return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene

## Enemies in the level whose script is `script_path`, left to right.
func enemies(script_path: String) -> Array:
	var out := []
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and not n.is_queued_for_deletion() and (n.get_script() as Script).resource_path == script_path:
			out.append(n)
	out.sort_custom(func(a, b): return a.global_position.x < b.global_position.x)
	return out

func sent() -> int:
	return session().attacks.history.size()

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	ROUND = load("res://Scripts/Classes/Battle/BattleRound.gd")
	TYPES = load("res://Scripts/Classes/Battle/BattleEnemyType.gd")
	LV = load("res://Scripts/Classes/LevelClass.gd")
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	var settings = root.get_node("Settings")
	var saved_video: Dictionary = settings.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(settings.SETTINGS_DIR)
	ROUND.pre_round_override = 0.0

	await start_battle()
	await test_player_defeats()
	await test_incoming_to_player_not_spawned()
	await test_round_isolation()
	await test_classic()

	ROUND.pre_round_override = -1.0
	for key in saved_video:
		settings.file.video[key] = saved_video[key]
	var settings_out := FileAccess.open(settings.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle attack game test(s) failed" % failures)
	else:
		print("All Battle attack game tests passed")
	quit(1 if failures > 0 else 0)

func start_battle() -> void:
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return on_title(), 900)
	current_scene.start_battle()
	var up: bool = await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING, 1500)
	await frames(5)
	check(up, "Battle is running World 1-1 with the real player")
	# only the real player sends in these tests: the bots stay quiet so every count is exact
	session().attacks.bots_send = false

# ---- the real player's kills ---------------------------------------------------------------------------------

func test_player_defeats() -> void:
	print("-- the real player defeats real enemies")
	var p := player()
	var goombas := enemies(GOOMBA_SCRIPT)
	var koopas := enemies(KOOPA_SCRIPT)
	check(goombas.size() >= 5 and koopas.size() >= 1, "1-1 has Goombas (%d) and a Koopa (%d)" % [goombas.size(), koopas.size()])
	check(sent() == 0, "nothing has been sent yet")
	# stomp
	goombas[0].stomped_on(p)
	check(sent() == 1, "stomping a Goomba creates one send")
	var a: Dictionary = session().attacks.attack_history()[0]
	check(a.sender == 0 and a.kind == TYPES.Kind.GOOMBA and a.target >= 1 and a.state == 0 and a.sent_tick == session().tick_count, "...from the player, a GOOMBA, to an opponent, QUEUED (%s)" % str(a))
	var ev: Array = session().events.filter(func(e): return e.type == SESSION.EventType.ENEMY_DEFEATED)
	check(ev.size() == 1 and ev[0].id == 0 and ev[0].a == TYPES.Kind.GOOMBA, "an ENEMY_DEFEATED event records it")
	# exactly once
	goombas[0].report_battle_defeat()
	goombas[0].report_battle_defeat()
	await frames(10)
	check(sent() == 1 and session().attacks.defeats == 1, "the same enemy reports once, however often its death code runs")
	# kicked / burned / star-struck: the shared base-class death
	goombas[1].die_from_object(p)
	check(sent() == 2, "an object kill (shell, fireball, star) creates a send")
	goombas[1].die_from_object(p)
	goombas[1].die()
	check(sent() == 2, "...and a second death call on the same Goomba does not")
	goombas[2].die_from_hammer(p)
	check(sent() == 3, "a hammer kill creates a send")
	goombas[3].damage(p)
	check(sent() == 4, "a fireball-style hit that kills creates a send")
	goombas[4].die()
	check(sent() == 5, "the plain die() path creates a send")
	# a Koopa stomped into its shell
	var koopa = koopas[0]
	koopa.stomped_on(p)
	await frames(5)
	check(sent() == 6 and session().attacks.attack_history()[5].kind == TYPES.Kind.KOOPA, "stomping a Koopa into its shell creates one KOOPA send")
	var shells := enemies(SHELL_SCRIPT)
	check(shells.size() >= 1, "(the Koopa left a shell behind)")
	if shells.size() > 0:
		var shell = shells[0]
		check(shell.old_entity != null and not shell.old_entity._battle_defeat_reported, "the Koopa that will wake up from the shell has not been counted as defeated")
		shell.die_from_object(p)
		check(sent() == 6, "killing the shell is not another send (a shell is not a supported enemy)")
	# a Koopa bumped from below
	var bumped = load(KOOPA_PREFAB).instantiate()
	G.current_level.add_child(bumped)
	bumped.global_position = p.global_position + Vector2(40, 0)
	await frames(3)
	bumped.block_bounced()
	await frames(3)
	check(sent() == 7 and session().attacks.attack_history()[6].kind == TYPES.Kind.KOOPA, "a Koopa knocked into its shell from below creates a send")
	# every send went out as an event pair, in order
	var all_sent: Array = session().events.filter(func(e): return e.type == SESSION.EventType.SENT)
	check(all_sent.size() == 7 and all_sent.map(func(e): return e.a) == [0, 1, 2, 3, 4, 5, 6] and all_sent.all(func(e): return e.id == 0 and e.b != 0), "seven SENT events, in order, all from the player and none to the player themself")
	# the player dies: no more sends
	var more := enemies(GOOMBA_SCRIPT)
	p.die()
	check(not session().get_player().alive, "the player has died")
	if more.size() > 0:
		more[0].die_from_object(p)
	check(sent() == 7, "an enemy defeated after the player's death sends nothing")
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1500)

# ---- attacks aimed at the real player ----------------------------------------------------------------------------

func test_incoming_to_player_not_spawned() -> void:
	print("-- incoming attacks on the real player")
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1500)
	rnd().time_in_state = ROUND.RESULTS_MAX_SECONDS
	await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING and rnd().round_number >= 2, 1800)
	await frames(5)
	var s = session()
	s.attacks.bots_send = false
	var fixed = FixedPolicy.new()
	fixed.target = 0
	s.attacks.targeting = fixed
	var enemy_count := get_nodes_in_group("Enemies").size()
	var nodes_before := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var power_before: String = player().power_state.name if player().get("power_state") != null else ""
	for i in 3:
		s.report_enemy_defeat(4 + i, TYPES.Kind.KOOPA)
	check(s.get_incoming(0).size() == 3, "three attacks are recorded in the real player's queue")
	await frames(60 * 12) # twelve Battle seconds: they activate (3 s delay) and resolve (7 s active)
	var states := {}
	for d in s.attacks.attack_history():
		states[d.state] = true
	check(states.has(2) and s.get_incoming(0).is_empty(), "...they activated and resolved in session state (%s)" % str(states.keys()))
	check(get_nodes_in_group("Enemies").size() == enemy_count, "no enemy was spawned into the player's level (%d enemies before and after)" % enemy_count)
	check(not player().is_dead and session().get_player().alive and (player().power_state.name if player().get("power_state") != null else "") == power_before, "the real player was not hurt, shrunk or killed by them")
	check(session().events.filter(func(e): return e.type == SESSION.EventType.INCOMING_ACTIVATED and e.id == 0).size() == 3, "INCOMING_ACTIVATED was logged for each, for a future UI")

# ---- the next round starts clean -----------------------------------------------------------------------------------

func test_round_isolation() -> void:
	print("-- attack state does not survive into the next round")
	var old = session()
	old.attacks.bots_send = true
	old.report_enemy_defeat(0, TYPES.Kind.GOOMBA)
	var old_seed: int = old.seed_value
	check(old.attacks.history.size() >= 1 and old.attacks.next_seq >= 1 and not old.events.is_empty(), "this round has attack state")
	player().die()
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1500)
	rnd().time_in_state = ROUND.RESULTS_MAX_SECONDS
	await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING and session() != old, 1800)
	await frames(3)
	var fresh = session()
	var clean: bool = fresh.attacks.history.is_empty() and fresh.attacks.next_seq == 0 and fresh.attacks.defeats == 0 and fresh.events.size() < 5
	for id in 35:
		if not fresh.get_incoming(id).is_empty() or fresh.attacks.pressure(id) != 0.0:
			clean = false
	check(clean and fresh.seed_value != old_seed, "the new round has no queues, active attacks, sequence numbers or attack history")
	check(fresh.attacks.enabled and fresh.attacks.bots_send and fresh.attacks.targeting != old.attacks.targeting, "...and its own, default attack system")
	old = null

# ---- Classic is untouched --------------------------------------------------------------------------------------------

func test_classic() -> void:
	print("-- Classic enemy defeats")
	HANDLER.quit_battle()
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
	var goombas := enemies(GOOMBA_SCRIPT)
	goombas[0].stomped_on(player())
	goombas[1].die_from_object(player())
	check(SESSION.current == null, "Classic Goomba defeats work and create no Battle state")
	# even with a stale Battle session lying around, a Classic kill must not touch it
	SESSION.begin(5)
	goombas[2].die_from_object(player())
	goombas[3].die_from_hammer(player())
	var marked: bool = goombas[2]._battle_defeat_reported or goombas[3]._battle_defeat_reported
	check(SESSION.current.attacks.history.is_empty() and SESSION.current.attacks.defeats == 0 and SESSION.current.events.is_empty(), "a Classic defeat never reports to Battle, even if a session object exists")
	var koopas := enemies(KOOPA_SCRIPT)
	koopas[0].stomped_on(player())
	await frames(5)
	check(SESSION.current.attacks.history.is_empty() and SESSION.current.events.is_empty(), "...nor does a Classic Koopa stomp")
	check(not marked, "(the enemies were not even marked as reported)")
	SESSION.clear()
	G.transition_to_scene(TITLE)
	await wait_until(func(): return on_title(), 900)
	G.current_game_mode = G.GameMode.NONE
