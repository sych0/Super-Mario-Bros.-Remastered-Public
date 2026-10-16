extends SceneTree
## The real game's side of the Battle attack loop: the real player defeating real enemies inside
## Battle (stomp, kick/fire/star kill, hammer, a Koopa stomped into its shell), who each kill is
## attributed to (only the real player's sends anything), exactly-once reporting, no reporting
## outside Battle, attacks aimed at the real player staying active until the game resolves them,
## the cleanup at a level transition and at the end of a round, and attack state not surviving into
## the next round. The session side only: BattleIncomingSpawner is switched off here, so no attack
## becomes a real enemy (physical incoming enemies are tests/battle_incoming_game_test.gd).
##   godot --headless --fixed-fps 60 --path . -s tests/battle_attack_game_test.gd
## Script classes that mention autoloads are only reached through load() (a `-s` script is compiled
## before the autoloads exist).

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const GOOMBA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/Goomba.gd"
const KOOPA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/KoopaTroopa.gd"
const SHELL_SCRIPT := "res://Scripts/Classes/Entities/ShellClass.gd"
const KOOPA_PREFAB := "res://Scenes/Prefabs/Entities/Enemies/GreenKoopaTroopa.tscn"
const GOOMBA_PREFAB := "res://Scenes/Prefabs/Entities/Enemies/Goomba.tscn"
const SHELL_PREFAB := "res://Scenes/Prefabs/Entities/Objects/GreenKoopaShell.tscn"
const SPIKE_PREFAB := "res://Scenes/Prefabs/Entities/SpikeBall.tscn"
const ICICLE_PREFAB := "res://Scenes/Prefabs/Entities/Enemies/Icicle.tscn"
const FIREBALL_PREFAB := "res://Scenes/Prefabs/Entities/Items/Fireball.tscn"
const BRICK_PREFAB := "res://Scenes/Prefabs/Blocks/BrickBlocks/BrickBlock.tscn"
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
func choose(_session, _sender, _draw) -> int:
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
var AT # BattleAttribution
var SRC # BattleAttribution.Source
var RES # BattleAttack.Resolution
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

## A bot that is still in the round (the simulated bots drop out as the test runs).
func alive_bot(skip := 0) -> int:
	for id in range(1 + skip, 35):
		if session().contestants[id].alive:
			return id
	return -1

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
	AT = load("res://Scripts/Classes/Battle/BattleAttribution.gd")
	SRC = AT.Source
	RES = load("res://Scripts/Classes/Battle/BattleAttack.gd").Resolution
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	var settings = root.get_node("Settings")
	var saved_video: Dictionary = settings.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(settings.SETTINGS_DIR)
	ROUND.pre_round_override = 0.0
	load("res://Scripts/Classes/Battle/BattleIncomingSpawner.gd").enabled = false

	await start_battle()
	await test_player_defeats()
	await test_incoming_to_player()
	await test_round_isolation()
	await test_targeting_modes()
	await test_classic()

	ROUND.pre_round_override = -1.0
	load("res://Scripts/Classes/Battle/BattleIncomingSpawner.gd").enabled = true
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
	check(ev.size() == 1 and ev[0].id == 0 and ev[0].a == TYPES.Kind.GOOMBA and ev[0].defeat == 0, "an ENEMY_DEFEATED event records it (defeat 0)")
	# exactly once
	goombas[0].report_battle_defeat(p)
	goombas[0].report_battle_defeat(p)
	await frames(10)
	check(sent() == 1 and session().attacks.defeats == 1 and session().attacks.defeat_sources == {SRC.PLAYER: 1}, "the same enemy reports once, however often its death code runs")
	# kicked / burned / star-struck: the shared base-class death, with the player as the cause
	goombas[1].die_from_object(p)
	check(sent() == 2, "an object kill by the player (star) creates a send")
	goombas[1].die_from_object(p)
	goombas[1].die()
	check(sent() == 2, "...and a second death call on the same Goomba does not")
	goombas[2].die_from_hammer(p)
	check(sent() == 3, "a hammer kill creates a send")
	goombas[3].damage(p)
	check(sent() == 4, "a hit by the player that kills creates a send")
	goombas[4].die()
	check(sent() == 4 and session().attacks.defeat_sources.get(SRC.UNKNOWN, 0) == 1, "the plain die() path says nothing about who killed it: UNKNOWN, no send")
	# a Koopa stomped into its shell
	var koopa = koopas[0]
	koopa.stomped_on(p)
	await frames(5)
	check(sent() == 5 and session().attacks.attack_history()[4].kind == TYPES.Kind.KOOPA, "stomping a Koopa into its shell creates one KOOPA send")
	var shells := enemies(SHELL_SCRIPT)
	check(shells.size() >= 1, "(the Koopa left a shell behind)")
	if shells.size() > 0:
		var shell = shells[0]
		check(shell.old_entity != null and not shell.old_entity._battle_defeat_reported, "the Koopa that will wake up from the shell has not been counted as defeated")
		shell.die_from_object(p)
		check(sent() == 5, "killing the shell is not another send (a shell is not a supported enemy)")
	# every send went out as an event pair, in order
	var all_sent: Array = session().events.filter(func(e): return e.type == SESSION.EventType.SENT)
	check(all_sent.size() == 5 and all_sent.map(func(e): return e.a) == [0, 1, 2, 3, 4] and all_sent.all(func(e): return e.id == 0 and e.b != 0), "five SENT events, in order, all from the player and none to the player themself")
	await test_attribution_matrix()
	# the player dies: no more sends
	var total := sent()
	var more := enemies(GOOMBA_SCRIPT)
	p.die()
	check(not session().get_player().alive, "the player has died")
	if more.size() > 0:
		more[0].die_from_object(p)
	check(sent() == total, "an enemy defeated after the player's death sends nothing")
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1500)

# ---- who each kill is attributed to ----------------------------------------------------------------------------

var spawned := 0

## A level object parked far from the action with its processing off, so only the calls a test makes
## happen. Every one gets its own position before it enters the level: the level's persistence frees an
## entity whose scene and position match one that was already defeated.
func spawn(prefab: String) -> Node2D:
	var n: Node2D = load(prefab).instantiate()
	spawned += 1
	n.position = Vector2(12000 + 24 * spawned, -600)
	G.current_level.add_child(n)
	n.process_mode = Node.PROCESS_MODE_DISABLED
	return n

func goomba() -> Node2D:
	return spawn(GOOMBA_PREFAB)

## `action` kills (or tries to kill) an enemy; it must count as `source`, and send an enemy only if `send`.
func expect(label: String, source: int, send: bool, action: Callable) -> void:
	var s = session()
	var before := sent()
	var defeats_before: int = s.attacks.defeats
	var counted_before: int = int(s.attacks.defeat_sources.get(source, 0))
	await action.call()
	await frames(4)
	var grew := sent() - before
	var counted: int = int(s.attacks.defeat_sources.get(source, 0)) - counted_before
	check(grew == (1 if send else 0) and counted == 1 and s.attacks.defeats - defeats_before == grew, "%s -> %s, %s" % [label, AT.name_of(source), "sends an enemy" if send else "sends nothing"])

func test_attribution_matrix() -> void:
	print("-- kill attribution on the real kill paths")
	var p := player()
	var block := spawn(BRICK_PREFAB)
	var other_block := spawn(BRICK_PREFAB)
	AT.tag_block_bump(block, p) # as Player.handle_block_collision_detection does when it bumps one from below
	var made: Array = [block, other_block]
	# --- the real player
	var g := goomba()
	await expect("stomping a Goomba", SRC.PLAYER, true, func(): g.stomped_on(p))
	g = goomba()
	await expect("a star-powered touch (die_from_object by the player)", SRC.PLAYER, true, func(): g.die_from_object(p))
	g = goomba()
	await expect("the hammer", SRC.PLAYER, true, func(): g.die_from_hammer(p))
	g = goomba()
	var fireball := spawn(FIREBALL_PREFAB)
	fireball.set_meta("IsPlayerProjectile", "true") # exactly what Player.throw_projectile adds
	fireball.is_friendly = true
	made.append(fireball)
	await expect("the player's fireball (through the Goomba's FireballDetection)", SRC.PLAYER, true, func(): g.get_node("FireballDetection").fireball_hit.emit(fireball))
	g = goomba()
	var shell := spawn(SHELL_PREFAB)
	made.append(shell)
	await frames(8)
	shell.on_player_stomped_on(p) # the player kicks it: the shell now knows who
	await expect("a shell the player kicked", SRC.PLAYER, true, func(): g.get_node("ShellDetection").moving_shell_entered.emit(shell))
	g = goomba()
	await expect("a block the player bumped from below", SRC.PLAYER, true, func(): g.get_node("BlockBouncingDetection").block_bounced.emit(block))
	var k := spawn(KOOPA_PREFAB)
	await expect("stomping a Koopa", SRC.PLAYER, true, func(): k.stomped_on(p))
	k = spawn(KOOPA_PREFAB)
	k.get_node("BlockBouncingDetection").last_block = block
	AT.tag_block_bump(block, p) # a bump only counts for half a second: bump it again
	await expect("a Koopa bounced off a block the player bumped", SRC.PLAYER, true, func(): k.block_bounced())
	check(session().attacks.attack_history().slice(-2).all(func(d): return d.kind == TYPES.Kind.KOOPA), "(the last two sends were KOOPAs)")
	# --- not the player
	g = goomba()
	var killer := goomba()
	made.append(killer)
	await expect("another enemy", SRC.ENEMY, false, func(): g.die_from_object(killer))
	g = goomba()
	var spike := spawn(SPIKE_PREFAB)
	made.append(spike)
	await expect("a spike ball", SRC.ENVIRONMENT, false, func(): g.die_from_object(spike))
	g = goomba()
	var icicle := spawn(ICICLE_PREFAB)
	made.append(icicle)
	await expect("a falling icicle (through the Goomba's IcicleDetection)", SRC.ENVIRONMENT, false, func(): g.get_node("IcicleDetection").icicle_detected.emit(icicle))
	g = goomba()
	await expect("nothing known (die)", SRC.UNKNOWN, false, func(): g.die())
	g = goomba()
	var rock := Node2D.new()
	G.current_level.add_child(rock)
	rock.position = Vector2(11000, -600)
	made.append(rock)
	await expect("an object nobody knows", SRC.UNKNOWN, false, func(): g.die_from_object(rock))
	g = goomba()
	var enemy_fireball := spawn(FIREBALL_PREFAB)
	made.append(enemy_fireball)
	await expect("a projectile that is not the player's (it is an enemy's)", SRC.ENEMY, false, func(): g.get_node("FireballDetection").fireball_hit.emit(enemy_fireball))
	g = goomba()
	var loose_shell := spawn(SHELL_PREFAB)
	made.append(loose_shell)
	await expect("a shell nobody kicked", SRC.UNKNOWN, false, func(): g.get_node("ShellDetection").moving_shell_entered.emit(loose_shell))
	g = goomba()
	await expect("a block nobody was seen bumping", SRC.UNKNOWN, false, func(): g.get_node("BlockBouncingDetection").block_bounced.emit(other_block))
	k = spawn(KOOPA_PREFAB)
	k.get_node("BlockBouncingDetection").last_block = other_block
	await expect("a Koopa bounced off a block nobody bumped", SRC.UNKNOWN, false, func(): k.block_bounced())
	k = spawn(KOOPA_PREFAB)
	await expect("a Koopa bounced with no block known", SRC.UNKNOWN, false, func(): k.block_bounced())
	k = spawn(KOOPA_PREFAB)
	await expect("a Koopa killed by another enemy", SRC.ENEMY, false, func(): k.die_from_object(killer))
	# the player's side of a block bump: it tags the block just before it tells it it was hit, in Battle only
	var player_src := FileAccess.get_file_as_string("res://Scripts/Classes/Entities/Player.gd")
	var fn_at := player_src.find("func handle_block_collision_detection()")
	var body := player_src.substr(fn_at, player_src.find("\nfunc ", fn_at + 10) - fn_at)
	var tag_at := body.find("BattleAttribution.tag_block_bump(i, self)")
	check(tag_at > 0 and tag_at < body.find("player_block_hit.emit(self)") and body.substr(0, tag_at).contains("GameMode.BATTLE"), "Player.handle_block_collision_detection tags the block (Battle only) before it emits player_block_hit")
	# an old bump no longer counts
	g = goomba()
	block.set_meta(AT.BUMP_META, [p, Engine.get_physics_frames() - AT.BUMP_FRAMES - 5])
	await expect("a block the player bumped a while ago", SRC.UNKNOWN, false, func(): g.get_node("BlockBouncingDetection").block_bounced.emit(block))
	# one defeat, one report: the first report wins, whatever follows
	g = goomba()
	var counted_before: int = session().attacks.defeats
	var sent_before := sent()
	g.die()
	g.stomped_on(p)
	g.die_from_object(p)
	await frames(4)
	check(sent() == sent_before and session().attacks.defeats == counted_before, "an enemy first killed with no known cause cannot then be claimed by the player: one defeat is one report")
	g = goomba()
	sent_before = sent()
	g.stomped_on(p)
	g.die()
	g.die_from_hammer(p)
	g.damage(p)
	await frames(4)
	check(sent() == sent_before + 1, "an enemy the player stomped sends exactly one enemy however many death paths then run")
	check(session().get_incoming(0).is_empty() or session().get_incoming(0).all(func(d): return d.sender != 0), "(nothing the player defeated was sent to the player)")
	for n in made:
		if is_instance_valid(n):
			n.queue_free()
	await frames(3)

# ---- attacks aimed at the real player ----------------------------------------------------------------------------

func test_incoming_to_player() -> void:
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
	var power_before: String = player().power_state.name if player().get("power_state") != null else ""
	for i in 3:
		s.report_enemy_defeat(alive_bot(i), TYPES.Kind.KOOPA)
	check(s.get_incoming(0).size() == 3, "three attacks are recorded in the real player's queue")
	await frames(60 * 12) # twelve Battle seconds: they activate after 3, and the longest bot timer is 7
	var inc: Array = s.get_incoming(0)
	check(inc.size() == 3 and inc.all(func(d): return d.state == 1), "they are ACTIVE and still ACTIVE twelve seconds later: no timer resolves an attack on the real player")
	check(s.events.filter(func(e): return e.type == SESSION.EventType.INCOMING_RESOLVED).is_empty(), "...and nothing was resolved")
	check(get_nodes_in_group("Enemies").size() == enemy_count, "no enemy was spawned into the player's level (%d enemies before and after)" % enemy_count)
	check(not player().is_dead and s.get_player().alive and (player().power_state.name if player().get("power_state") != null else "") == power_before, "the real player was not hurt, shrunk or killed by them")
	check(s.events.filter(func(e): return e.type == SESSION.EventType.INCOMING_ACTIVATED and e.id == 0).size() == 3, "INCOMING_ACTIVATED was logged for each, for a future UI")
	# a fourth waits for a free slot
	var fourth = s.report_enemy_defeat(alive_bot(), TYPES.Kind.GOOMBA)
	await frames(60 * 4)
	check(fourth.state == 0, "a fourth attack waits QUEUED while three are active")
	# the game resolves one by its sequence id
	var first: int = inc[0].seq
	check(s.resolve_player_incoming(first, RES.DEFEATED_BY_PLAYER), "the game resolves one specific attack by its id")
	check(not s.resolve_player_incoming(first, RES.DEFEATED_BY_PLAYER), "a duplicate report is refused")
	await frames(60 * 2)
	check(fourth.state == 1 and s.attacks.history[first].resolution == RES.DEFEATED_BY_PLAYER, "the freed slot lets the waiting attack in, and the resolved one keeps its cause")
	# leaving the level (the BattleHandler going away with it) ends what was active in it
	var handler = G.current_level.get_node("BattleHandler")
	var active_ids: Array = s.get_incoming(0).filter(func(d): return d.state == 1).map(func(d): return d.seq)
	check(active_ids.size() == 3 and s.report_player_incoming_spawned(active_ids[0]), "(one of the three is reported spawned, as if its enemy were in this level)")
	handler.get_parent().remove_child(handler)
	handler.queue_free()
	check(s.attacks.history[active_ids[0]].resolution == RES.LEVEL_TRANSITION, "a level transition resolves an ACTIVE attack whose enemy was in the level as LEVEL_TRANSITION")
	check(active_ids.slice(1).all(func(q): return s.attacks.history[q].state == 1 and s.attacks.history[q].spawned_tick < 0) and s.get_incoming(0).size() == 2, "...and the two whose enemy never appeared stay ACTIVE, carried to the next level")
	# the round ends (the player wins): whatever is left is closed with ROUND_ENDED
	var late_a = s.report_enemy_defeat(alive_bot(), TYPES.Kind.KOOPA)
	var late_b = s.report_enemy_defeat(alive_bot(1), TYPES.Kind.GOOMBA)
	for id in range(1, 35):
		s.report_ko(id, SESSION.KoCause.HAZARD)
	check(s.finished and s.winner_id == 0 and late_a.resolution == RES.ROUND_ENDED and late_b.resolution == RES.ROUND_ENDED, "when the round ends, attacks still aimed at the player end with ROUND_ENDED")
	check(s.attacks.history.all(func(d): return d.state == 2 and d.resolution != RES.NONE) and s.attacks.round_ended, "...and nothing in the round is left unresolved")
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1500)
	rnd().time_in_state = ROUND.RESULTS_MAX_SECONDS
	await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING and rnd().round_number >= 3, 1800)
	await frames(5)

# ---- the next round starts clean -----------------------------------------------------------------------------------

func test_round_isolation() -> void:
	print("-- attack state does not survive into the next round")
	var old = session()
	old.attacks.bots_send = true
	old.report_enemy_defeat(0, TYPES.Kind.GOOMBA)
	var old_seed: int = old.seed_value
	check(old.attacks.history.size() >= 1 and old.attacks.next_seq >= 1 and not old.events.is_empty(), "this round has attack state")
	var fixed = FixedPolicy.new()
	fixed.target = 0
	old.attacks.targeting = fixed
	old.attacks.bots_send = false
	var aimed = old.report_enemy_defeat(alive_bot(), TYPES.Kind.KOOPA)
	await frames(60 * 4)
	check(aimed.state == 1, "(an attack is ACTIVE against the player when they die)")
	player().die()
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1500)
	check(aimed.resolution == RES.TARGET_OUT and old.attacks.history.all(func(d): return d.state == 2) and old.finished, "the player's death resolves what was active against them (TARGET_OUT) and the round finishes with nothing unresolved")
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

# ---- the player's targeting mode, on real kills (doc 47 M-T1) ------------------------------------------------------

func test_targeting_modes() -> void:
	print("-- real kills are sent to the selected target")
	var s = session()
	var mode = load("res://Scripts/Classes/Battle/BattleTargeting.gd").Mode
	s.attacks.bots_send = false
	s.attacks.pressure_enabled = false
	var p := player()
	var goombas := enemies(GOOMBA_SCRIPT)
	check(s.player_target_mode == mode.RANDOM and goombas.size() >= 4, "a fresh round is in Random mode, with Goombas to stomp")
	for id in range(1, 35):
		s.contestants[id].time_left = 580
	var low := alive_bot(14)
	s.contestants[low].time_left = 120
	check(BS.instance.select_target_mode(mode.LOWEST_TIME) and s.player_target_mode == mode.LOWEST_TIME and s.target_of(0) == low, "selecting Lowest Time aims at the lowest-time opponent (#%d)" % low)
	await frames(60)
	check(s.player_target_mode == mode.LOWEST_TIME and BS.instance.target_reticle.target == low, "the mode and the reticle hold while the game runs")
	var sent_before: int = s.attacks.history.size()
	goombas[0].stomped_on(p)
	check(s.attacks.history.size() == sent_before + 1 and s.attacks.history[-1].sender == 0 and s.attacks.history[-1].target == low and s.target_of(0) == low, "a real stomp sends its enemy to that opponent, and the target stays")
	goombas[1].die_from_object(p)
	check(s.attacks.history[-1].target == low and s.attacks.history.size() == sent_before + 2, "so does the next kill")
	# Attackers: an opponent that aims at the player
	var attacker := alive_bot(6)
	s.contestants[attacker].target_id = 0
	check(BS.instance.select_target_mode(mode.ATTACKERS) and s.attackers_of(0).has(attacker), "an opponent aiming at the player becomes an attacker")
	await frames(70) # a Battle second passes: the target catches up
	check(s.target_of(0) == s.attackers_of(0)[0], "Attackers aims at an actual attacker (#%d)" % s.target_of(0))
	var aimed: int = s.target_of(0)
	goombas[2].die_from_hammer(p)
	check(s.attacks.history[-1].target == aimed, "a kill goes to the attacker")
	# Random again
	check(BS.instance.select_target_mode(mode.RANDOM), "back to Random")
	goombas[3].damage(p)
	var last = s.attacks.history[-1]
	check(last.target == s.target_of(0) and last.target >= 1 and last.target != 0 and s.contestants[last.target].alive, "a Random send goes to a living opponent and becomes the target")
	check(BS.instance.select_target_mode(mode.MOST_COINS) == false and s.player_target_mode == mode.RANDOM, "Most Coins is refused: there is no coin data yet")
	await frames(60)
	check(s.attacks.history.all(func(h): return h.sender != 0 or h.target != 0), "no send of the player's ever went to the player")

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
