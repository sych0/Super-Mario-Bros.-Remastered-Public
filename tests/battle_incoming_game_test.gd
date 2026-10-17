extends SceneTree
## Physical incoming enemies in the real player's game (doc 46, milestone M6a), against the real project:
## an ACTIVE attack on the real player becomes exactly one real Goomba or Koopa in the real 1-1 inside the
## Battle GameViewport, at a safe spot, carrying its identity; its real fate resolves exactly that attack
## (stomp, pit, left behind, vanished, Koopa into shell; never a send); attacks wait rather than spawn
## unsafely; a pipe into the bonus room ends what was in the level and carries what never appeared; the
## player's KO and the round's end clear everything; the attack lines stop while the game is paused; and
## Classic has none of it.
##   godot --headless --fixed-fps 60 --path . -s tests/battle_incoming_game_test.gd
## Headless runs never render, so no VisibleOnScreenEnabler2D switches an enemy on: the test sets
## BattleIncomingSpawner.force_process, which switches each spawned enemy on as it arrives. Movement under a
## real renderer is checked in tests/battle_incoming_render_test.gd. Script classes that mention autoloads
## are only reached through load() (a `-s` script is compiled before the autoloads exist).

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const LEVEL_1_1A := "res://Scenes/Levels/SMB1/World1/1-1a.tscn"
const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const GOOMBA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/Goomba.gd"
const KOOPA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/KoopaTroopa.gd"
const SHELL_SCRIPT := "res://Scripts/Classes/Entities/ShellClass.gd"
const GOOMBA_PREFAB := "res://Scenes/Prefabs/Entities/Enemies/Goomba.tscn"
## Every attack goes to `target`; the target's own sends go to the first other contestant still in.
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
var target := 0
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
var BS
var SESSION
var ROUND
var TYPES
var ATTACK
var RES
var AT
var SRC
var SPAWNER
var PLACER
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

func physics_frames(n: int) -> void:
	for i in n:
		await physics_frame

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

func level_running(path := LEVEL_1_1) -> bool:
	return BS.is_active() and not G.transitioning_scene and is_instance_valid(G.current_level) \
		and G.current_level.scene_file_path == path and G.current_level.get_parent() == BS.instance.game_viewport and player() != null

func on_title() -> bool:
	return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene

func spawner():
	if not is_instance_valid(G.current_level):
		return null
	return G.current_level.get_node_or_null("BattleHandler/BattleIncomingSpawner")

func alive_bot(skip := 0) -> int:
	var seen := 0
	for id in range(1, 35):
		if session().contestants[id].alive:
			if seen == skip:
				return id
			seen += 1
	return -1

func aim_at_player() -> void:
	var p = FixedPolicy.new()
	p.target = 0
	session().attacks.targeting = p
	session().attacks.bots_send = false
	session().attacks.pressure_enabled = false

## Every node in the tree that carries a Battle-incoming identity.
func tagged_nodes() -> Array:
	var out := []
	for n in root.find_children("*", "", true, false):
		if n.has_meta(AT.ORIGIN_META) and not n.is_queued_for_deletion():
			out.append(n)
	return out

func node_for(seq: int):
	for n in tagged_nodes():
		var o: PackedInt64Array = AT.origin_of(n)
		if o.size() == 4 and o[0] == session().uid and o[1] == seq:
			return n
	return null

func sends_by_player() -> int:
	return session().events.filter(func(e): return e.type == SESSION.EventType.SENT and e.id == 0).size()

func view_rect() -> Rect2:
	return spawner().view_rect()

## Moves Mario without the camera reading the jump as a run (CameraHandler derives its speed from its last position).
func teleport(pos: Vector2) -> void:
	var p := player()
	var ch: Node = p.get_node("CameraHandler")
	p.global_position = pos
	p.velocity = Vector2.ZERO
	ch.last_position = pos
	ch.camera_position.x = pos.x
	p.reset_physics_interpolation()

## The first x at or after `x` where Mario can stand on open ground (no pipe or block in his body).
func clear_ground_from(x: float) -> float:
	var cx := int(floor(x / 16))
	for i in 64:
		var c := Vector2((cx + i) * 16 + 8, 0)
		var ok := solid_at(c + Vector2(0, 8)) and solid_at(c + Vector2(-16, 8)) and solid_at(c + Vector2(16, 8))
		for h in range(1, 4):
			ok = ok and not solid_at(c - Vector2(0, h * 16 - 8)) and not solid_at(c - Vector2(16, h * 16 - 8)) and not solid_at(c + Vector2(16, -(h * 16 - 8)))
		if ok:
			return c.x
	return x

func solid_at(pos: Vector2) -> bool:
	var q := PhysicsPointQueryParameters2D.new()
	q.position = pos
	q.collision_mask = 2
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return not BS.instance.game_viewport.find_world_2d().direct_space_state.intersect_point(q, 1).is_empty()

## Bodies on the enemy / shell layers overlapping `rect`, other than `except`.
func bodies_in(rect: Rect2, except: Node = null) -> Array:
	var shape := RectangleShape2D.new()
	shape.size = rect.size
	var q := PhysicsShapeQueryParameters2D.new()
	q.shape = shape
	q.transform = Transform2D(0.0, rect.get_center())
	q.collision_mask = 16 | 32
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var out := []
	for hit in BS.instance.game_viewport.find_world_2d().direct_space_state.intersect_shape(q, 16):
		if hit.collider != except:
			out.append(hit.collider)
	return out

## Sends one enemy of `kind` to the real player (from a bot) and waits until it has an enemy in the level.
func send_and_spawn(kind: int, max_frames := 60 * 8):
	var a = session().report_enemy_defeat(alive_bot(), kind)
	await wait_until(func(): return a.spawned_tick >= 0, max_frames)
	await physics_frames(2)
	return a

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	ROUND = load("res://Scripts/Classes/Battle/BattleRound.gd")
	TYPES = load("res://Scripts/Classes/Battle/BattleEnemyType.gd")
	ATTACK = load("res://Scripts/Classes/Battle/BattleAttack.gd")
	RES = ATTACK.Resolution
	AT = load("res://Scripts/Classes/Battle/BattleAttribution.gd")
	SRC = AT.Source
	SPAWNER = load("res://Scripts/Classes/Battle/BattleIncomingSpawner.gd")
	PLACER = load("res://Scripts/Classes/Battle/BattleSpawnPlacer.gd")
	LV = load("res://Scripts/Classes/LevelClass.gd")
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	var settings = root.get_node("Settings")
	var saved_video: Dictionary = settings.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(settings.SETTINGS_DIR)
	ROUND.pre_round_override = 0.0
	SPAWNER.force_process = true
	SPAWNER.enabled = true

	await start_battle()
	await test_wiring()
	await test_goomba()
	await test_koopa_and_shell()
	await test_three_in_order()
	await test_hold_without_placement()
	await test_despawn()
	await test_bonus_room()
	await test_pause_freezes_flights()
	await test_win_clears()
	await test_contact_death_clears()
	await test_classic()

	SPAWNER.force_process = false
	ROUND.pre_round_override = -1.0
	for key in saved_video:
		settings.file.video[key] = saved_video[key]
	var settings_out := FileAccess.open(settings.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle incoming game test(s) failed" % failures)
	else:
		print("All Battle incoming game tests passed")
	quit(1 if failures > 0 else 0)

func start_battle() -> void:
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return on_title(), 900)
	current_scene.start_battle()
	var up: bool = await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING, 1500)
	await frames(5)
	check(up, "Battle is running World 1-1 with the real player")
	aim_at_player()
	player().can_hurt = false # the enemies here walk into Mario; only the death test lets them hurt him

# ---- wiring ---------------------------------------------------------------------------------------------

func test_wiring() -> void:
	print("-- wiring")
	var sp = spawner()
	check(sp != null and sp.get_parent().name == "BattleHandler" and sp.session == session(), "the level's BattleHandler owns one BattleIncomingSpawner, bound to this round's session")
	check(load("res://Scripts/Classes/Battle/BattleEnemyFactory.gd").is_warm(TYPES.Kind.GOOMBA) and load("res://Scripts/Classes/Battle/BattleEnemyFactory.gd").is_warm(TYPES.Kind.KOOPA), "the Goomba and Koopa prefabs were loaded when the level started, not on a spawn frame")
	check(tagged_nodes().is_empty() and sp.live.is_empty(), "nothing is spawned while nothing is aimed at the player")
	check(sp.process_mode == Node.PROCESS_MODE_INHERIT and sp.can_process(), "it runs with the level (pausable)")

# ---- one Goomba ------------------------------------------------------------------------------------------

func test_goomba() -> void:
	print("-- an ACTIVE Goomba attack becomes one real Goomba")
	var s = session()
	var sp = spawner()
	var p := player()
	var before: Array = get_nodes_in_group("Enemies").map(func(n): return n.get_instance_id())
	var sender := alive_bot()
	var a = s.report_enemy_defeat(sender, TYPES.Kind.GOOMBA)
	await frames(60)
	check(a.state == ATTACK.State.QUEUED and tagged_nodes().is_empty(), "nothing appears while the attack is QUEUED")
	var spawned: bool = await wait_until(func(): return a.spawned_tick >= 0, 60 * 6)
	await physics_frames(1)
	check(spawned and a.state == ATTACK.State.ACTIVE, "once ACTIVE, its enemy is spawned")
	var nodes := tagged_nodes()
	var new_enemies: Array = get_nodes_in_group("Enemies").filter(func(n): return not before.has(n.get_instance_id()))
	check(nodes.size() == 1 and new_enemies.size() == 1 and nodes[0] == new_enemies[0], "exactly one new enemy in the level, and it is the tagged one")
	var g = nodes[0] if nodes.size() > 0 else null
	if g == null:
		return
	check((g.get_script() as Script).resource_path == GOOMBA_SCRIPT and g.scene_file_path == TYPES.prefab(TYPES.Kind.GOOMBA), "it is the game's own Goomba (Goomba.tscn)")
	check(AT.origin_of(g) == PackedInt64Array([s.uid, a.seq, sender, TYPES.Kind.GOOMBA]), "its identity: [session uid %d, seq %d, sender %d, GOOMBA]" % [s.uid, a.seq, sender])
	check(g.get_parent() == G.current_level.get_node("Enemies") and g.has_meta("block_item") and g.has_meta("no_persist"), "it lives under the level's Enemies node, with the game's spawned-entity metas (no level persistence)")
	check(sp.live.get(a.seq) == g and sp.spawn_log.size() >= 1 and sp.spawn_log[-1].seq == a.seq, "the spawner maps the seq to that node and logged the spawn")
	var ev: Array = s.events.filter(func(e): return e.type == SESSION.EventType.INCOMING_SPAWNED)
	check(ev.size() == 1 and ev[0].a == a.seq and ev[0].id == 0, "INCOMING_SPAWNED was logged once")
	# a safe spot
	var view: Rect2 = view_rect()
	var pos: Vector2 = sp.spawn_log[-1].position
	check(view.grow(-1).has_point(pos - Vector2(0, 1)) and pos.y >= view.position.y + PLACER.HUD_BAND + 32, "it appeared inside the visible game area, below the HUD (%s in %s)" % [pos, view])
	check(pos.x - p.global_position.x >= PLACER.MIN_AHEAD and sp.spawn_log[-1].side == "ahead" and g.direction == -1, "ahead of Mario by at least %d px (%.0f), facing him" % [PLACER.MIN_AHEAD, pos.x - p.global_position.x])
	check(solid_at(pos + Vector2(0, 8)) and not solid_at(pos + Vector2(0, -8)) and not solid_at(pos + Vector2(0, -24)), "on a real floor, with no terrain in its body")
	check(bodies_in(Rect2(pos + Vector2(-12, -22), Vector2(24, 20)), g).is_empty(), "no other enemy or shell body where it stands")
	check(not Rect2(pos + Vector2(-8, -16), Vector2(16, 16)).intersects(Rect2(p.global_position + Vector2(-8, -16), Vector2(16, 16))), "not on Mario")
	# a real enemy
	await physics_frames(30)
	var x0: float = g.global_position.x
	await physics_frames(60)
	var moved: float = x0 - g.global_position.x
	check(moved > 20.0 and moved < 45.0 and g.is_on_floor() and g.get_node("Sprite").animation == "Walk", "it walks toward Mario on the floor like any Goomba (%.1f px in 1 s)" % moved)
	check(a.state == ATTACK.State.ACTIVE and a.resolution == RES.NONE, "no timer touches it: still ACTIVE")
	# the player stomps it: exactly this attack resolves, and nothing is sent
	var sends := sends_by_player()
	var defeats: int = s.attacks.defeats
	g.stomped_on(p)
	await physics_frames(2)
	check(a.state == ATTACK.State.RESOLVED and a.resolution == RES.DEFEATED_BY_PLAYER, "stomping it resolves its attack: DEFEATED_BY_PLAYER")
	check(sends_by_player() == sends and s.attacks.defeats == defeats and s.attacks.defeat_sources.is_empty(), "and sends nothing: an incoming enemy's defeat is never a new send")
	check(s.attacks.incoming_kill_sources.get(SRC.PLAYER, 0) == 1, "(counted as the player's kill of an incoming enemy)")
	await physics_frames(2)
	check(sp.live.is_empty(), "the spawner forgets it (the squashed Goomba is residue)")
	await frames(40)
	check(tagged_nodes().is_empty(), "the squashed Goomba goes away after its animation, as usual")

# ---- Koopa, shell, wake ---------------------------------------------------------------------------------------

func test_koopa_and_shell() -> void:
	print("-- an incoming Koopa: the stomp resolves it, the shell and the woken Koopa are residue")
	var s = session()
	var p := player()
	var k_attack = await send_and_spawn(TYPES.Kind.KOOPA)
	var k = node_for(k_attack.seq)
	check(k != null and (k.get_script() as Script).resource_path == KOOPA_SCRIPT and tagged_nodes().size() == 1, "an ACTIVE Koopa attack becomes exactly one real Koopa (GreenKoopaTroopa.tscn)")
	if k == null:
		return
	var sends := sends_by_player()
	var tag: PackedInt64Array = AT.origin_of(k)
	k.stomped_on(p)
	await physics_frames(3)
	check(k_attack.resolution == RES.DEFEATED_BY_PLAYER and s.events.filter(func(e): return e.type == SESSION.EventType.INCOMING_RESOLVED and e.a == k_attack.seq).size() == 1, "the stomp into a shell resolves the attack, once")
	check(sends_by_player() == sends, "and sends nothing")
	var shell = null
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and not n.is_queued_for_deletion() and (n.get_script() as Script).resource_path == SHELL_SCRIPT:
			shell = n
	check(shell != null and not AT.is_incoming(shell), "the shell is an ordinary, untagged shell")
	check(not spawner().live.has(k_attack.seq), "and nothing in the spawner tracks it")
	if shell == null:
		return
	# the shell kicked by the player into a native Goomba: a native send, by the existing attribution
	var native: Node2D = load(GOOMBA_PREFAB).instantiate()
	native.set_meta("no_persist", true)
	native.position = Vector2(-9000, -400)
	G.current_level.get_node("Enemies").add_child(native)
	await physics_frames(8)
	shell.on_player_stomped_on(p) # the player kicks it
	var sends2 := sends_by_player()
	native.get_node("ShellDetection").moving_shell_entered.emit(shell)
	await physics_frames(2)
	check(sends_by_player() == sends2 + 1, "the shell the player kicked kills a native Goomba: that is a native send, as before")
	# ...into an incoming Goomba: that one resolves, no send
	var g_attack = await send_and_spawn(TYPES.Kind.GOOMBA)
	var g = node_for(g_attack.seq)
	var sends3 := sends_by_player()
	if g != null:
		g.get_node("ShellDetection").moving_shell_entered.emit(shell)
	await physics_frames(2)
	check(g_attack.resolution == RES.DEFEATED_BY_PLAYER and sends_by_player() == sends3, "into an incoming Goomba: that attack resolves (the player's kick), and nothing is sent")
	# wake: a second incoming Koopa, stomped and left alone; the Koopa that comes back out of its shell
	# carries the tag, and can never resolve or send anything
	var k2_attack = await send_and_spawn(TYPES.Kind.KOOPA)
	var k2 = node_for(k2_attack.seq)
	tag = AT.origin_of(k2) if k2 != null else PackedInt64Array()
	var shells_before: Array = get_nodes_in_group("Enemies").filter(func(n): return is_instance_valid(n) and (n.get_script() as Script).resource_path == SHELL_SCRIPT)
	if k2 != null:
		k2.stomped_on(p)
	await physics_frames(3)
	check(k2_attack.resolution == RES.DEFEATED_BY_PLAYER, "(the second incoming Koopa was stomped: its attack resolved)")
	var shell2 = null
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and not n.is_queued_for_deletion() and (n.get_script() as Script).resource_path == SHELL_SCRIPT and not shells_before.has(n):
			shell2 = n
	if shell2 == null:
		check(false, "(its shell exists)")
		return
	shell2.process_mode = Node.PROCESS_MODE_INHERIT # headless: the shell's own on-screen enabler never switches it on
	shell2.wake_meter = 6.95
	await physics_frames(10)
	var woken = null
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and not n.is_queued_for_deletion() and (n.get_script() as Script).resource_path == KOOPA_SCRIPT and AT.origin_of(n) == tag:
			woken = n
	check(woken != null and woken.is_inside_tree(), "the woken Koopa is back in the level, carrying the same identity")
	if woken == null:
		return
	var snap = s.attacks.snapshot()
	var incoming_kills: int = s.attacks.incoming_kill_sources.get(SRC.PLAYER, 0)
	woken.stomped_on(p)
	await physics_frames(3)
	check(s.attacks.snapshot().history == snap.history and sends_by_player() == sends3, "stomping the woken Koopa resolves nothing and sends nothing (its attack already ended)")
	check(s.attacks.incoming_kill_sources.get(SRC.PLAYER, 0) == incoming_kills + 1, "(it is counted as residue)")
	check(not spawner().live.has(k_attack.seq) and spawner().live.is_empty(), "and the spawner never takes it back")
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and (n.get_script() as Script).resource_path == SHELL_SCRIPT:
			n.queue_free()
	if is_instance_valid(native):
		native.queue_free()
	await frames(3)

# ---- several, in order ----------------------------------------------------------------------------------------------

func test_three_in_order() -> void:
	print("-- several attacks: strict order, spaced")
	var s = session()
	var sp = spawner()
	var log_start: int = sp.spawn_log.size()
	var made := []
	for i in 4:
		made.append(s.report_enemy_defeat(alive_bot(i), [TYPES.Kind.KOOPA, TYPES.Kind.GOOMBA, TYPES.Kind.KOOPA, TYPES.Kind.GOOMBA][i]))
	await wait_until(func(): return sp.spawn_log.size() >= log_start + 3, 60 * 10)
	await physics_frames(2)
	var logs: Array = sp.spawn_log.slice(log_start)
	check(logs.size() == 3 and logs.map(func(l): return l.seq) == [made[0].seq, made[1].seq, made[2].seq], "three ACTIVE attacks become three enemies, in seq order")
	check(logs.size() == 3 and logs[1].frame - logs[0].frame >= 60 and logs[2].frame - logs[1].frame >= 60, "at least 1 s (60 physics frames) apart (%s)" % str(logs.map(func(l): return l.frame)))
	var kinds_ok := true
	for i in logs.size():
		var n = node_for(logs[i].seq)
		if n == null or (n.get_script() as Script).resource_path != TYPES.DATA[made[i].kind].script:
			kinds_ok = false
	check(kinds_ok, "each is the right kind")
	check(logs.size() == 3 and logs[0].position != logs[1].position or logs[0].frame != logs[1].frame, "(they do not appear on top of each other)")
	check(made[3].state == ATTACK.State.QUEUED and sp.live.size() == 3 and tagged_nodes().size() == 3, "the fourth stays QUEUED: at most 3 (the session's cap) are ever live")
	await frames(60 * 4)
	check(made[3].spawned_tick < 0 and sp.max_live <= 3, "and it does not appear while three are live")
	# free a slot: the fourth activates and arrives, a gap after the last spawn
	var first = node_for(made[0].seq)
	first.die_from_object(player())
	await wait_until(func(): return made[3].spawned_tick >= 0, 60 * 6)
	await physics_frames(1)
	var last: Dictionary = sp.spawn_log[-1]
	check(made[0].resolution == RES.DEFEATED_BY_PLAYER and last.seq == made[3].seq and last.frame - logs[2].frame >= 60, "killing one frees its slot; the fourth activates and arrives (in order, spaced)")
	for a in made:
		var n = node_for(a.seq)
		if n != null and a.state == ATTACK.State.ACTIVE:
			n.die_from_hammer(player())
	await physics_frames(3)
	check(made.all(func(a): return a.resolution == RES.DEFEATED_BY_PLAYER) and sp.live.is_empty(), "(cleanup: all four defeated by the player)")
	await frames(40)

# ---- no safe spot: hold, never drop ------------------------------------------------------------------------------

func test_hold_without_placement() -> void:
	print("-- no safe spot: the attack waits")
	var sp = spawner()
	var view: Rect2 = view_rect()
	var mario: Vector2 = player().global_position
	# stand an enemy body on the floor of every column in view
	var blockers := []
	for cx in range(int(floor(view.position.x / 16)), int(floor(view.end.x / 16))):
		var y: float = PLACER.floor_in(cx, view, mario.y, sp._solid)
		if y == INF:
			continue
		var body := StaticBody2D.new()
		body.collision_layer = 16
		body.collision_mask = 0
		var cs := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		shape.size = Vector2(14, 14)
		cs.shape = shape
		body.add_child(cs)
		body.position = Vector2(cx * 16 + 8, y - 8)
		G.current_level.add_child(body)
		blockers.append(body)
	await physics_frames(2)
	var fails0: int = sp.fail_log.size()
	var a = session().report_enemy_defeat(alive_bot(), TYPES.Kind.GOOMBA)
	await frames(60 * 6)
	check(a.state == ATTACK.State.ACTIVE and a.spawned_tick < 0 and tagged_nodes().is_empty(), "with every floor occupied nothing is forced in: the attack stays ACTIVE and unspawned")
	check(sp.fail_log.size() > fails0 and sp.plan.holding() and sp.plan.pending == [a.seq], "the spawner keeps trying (%d failed placements: %s)" % [sp.fail_log.size() - fails0, sp.fail_log[-1].reason if sp.fail_log.size() > 0 else ""])
	for b in blockers:
		b.queue_free()
	var arrived: bool = await wait_until(func(): return a.spawned_tick >= 0, 60 * 3)
	check(arrived and node_for(a.seq) != null, "once there is room it arrives: nothing was dropped")
	await physics_frames(2)
	var n = node_for(a.seq)
	if n != null:
		n.die_from_object(player())
	await frames(40)

# ---- leaving play without a kill ---------------------------------------------------------------------------------

func test_despawn() -> void:
	print("-- out of play: despawned by the bridge, from camera geometry")
	var s = session()
	var sp = spawner()
	# left behind: Mario runs on, the camera follows, the enemy stays behind the left edge
	var a = await send_and_spawn(TYPES.Kind.GOOMBA)
	var g = node_for(a.seq)
	teleport(Vector2(clear_ground_from(player().global_position.x + 380), -1))
	var gone: bool = await wait_until(func(): return a.state == ATTACK.State.RESOLVED, 60 * 3)
	check(gone and a.resolution == RES.DESPAWNED and sp.resolve_log[-1].why == "left behind", "an incoming Goomba left behind by the camera resolves DESPAWNED (%s)" % (sp.resolve_log[-1].why if sp.resolve_log.size() > 0 else "-"))
	await frames(2)
	check(not is_instance_valid(g) or g.is_queued_for_deletion(), "and the bridge removes it (the game never frees an off-screen Goomba)")
	# a pit: drop a live incoming Goomba into 1-1's first gap
	var gap_x := -1
	for x in range(900, 1700, 8):
		if not solid_at(Vector2(x, 8)) and not solid_at(Vector2(x, 24)):
			gap_x = x
			break
	check(gap_x > 0, "(1-1's first gap is at x=%d)" % gap_x)
	teleport(Vector2(gap_x - 60, -8))
	await physics_frames(90)
	var b = await send_and_spawn(TYPES.Kind.GOOMBA)
	var pit_goomba = node_for(b.seq)
	if pit_goomba != null:
		pit_goomba.global_position = Vector2(gap_x + 24, -40)
		pit_goomba.direction = 1
		pit_goomba.reset_physics_interpolation()
	var fell: bool = await wait_until(func(): return b.state == ATTACK.State.RESOLVED, 60 * 3)
	check(fell and b.resolution == RES.DESPAWNED and sp.resolve_log[-1].why == "pit", "an incoming Goomba that falls into a pit resolves DESPAWNED (%s)" % (sp.resolve_log[-1].why if sp.resolve_log.size() > 0 else "-"))
	# vanished without any kill report
	var c = await send_and_spawn(TYPES.Kind.KOOPA)
	var v = node_for(c.seq)
	if v != null:
		v.queue_free()
	var vanished: bool = await wait_until(func(): return c.state == ATTACK.State.RESOLVED, 30)
	check(vanished and c.resolution == RES.DESPAWNED and sp.resolve_log[-1].why == "vanished", "one that disappears without a kill report resolves DESPAWNED too")
	check(sp.live.is_empty() and sends_by_player() == 1, "nothing is left, and none of it sent anything")
	check(s.attacks.history.filter(func(h): return h.target == 0 and h.state == ATTACK.State.RESOLVED and h.resolution == RES.NONE).is_empty(), "(every resolved attack has a cause)")

# ---- a pipe: the bonus room -----------------------------------------------------------------------------------------

func test_bonus_room() -> void:
	print("-- a pipe into the bonus room and back")
	var s = session()
	var sp = spawner()
	# the pipe into 1-1a (the real pipe path is taken from wherever Mario stands)
	var pipe: Node2D = G.current_level.get_node("PipeArea")
	await physics_frames(30)
	# two attacks activate together: the first appears at once, the second is due a gap later
	var a = s.report_enemy_defeat(alive_bot(), TYPES.Kind.GOOMBA)
	var b = s.report_enemy_defeat(alive_bot(1), TYPES.Kind.KOOPA)
	await wait_until(func(): return a.spawned_tick >= 0, 60 * 6)
	await physics_frames(2)
	check(a.spawned_tick >= 0 and b.state == ATTACK.State.ACTIVE and b.spawned_tick < 0, "(one is in the level, the other is ACTIVE and still arriving)")
	var old_level = G.current_level
	player().enter_pipe(pipe) # the real pipe path: one second, then the bonus room
	var in_room: bool = await wait_until(func(): return level_running(LEVEL_1_1A), 60 * 6)
	await physics_frames(2)
	check(in_room and not is_instance_valid(old_level), "the pipe took Mario into 1-1a (a separate scene: the 1-1 level is gone)")
	check(a.state == ATTACK.State.RESOLVED and a.resolution == RES.LEVEL_TRANSITION, "the enemy that was in 1-1 ended with it: LEVEL_TRANSITION")
	check(b.state == ATTACK.State.ACTIVE and b.spawned_tick < 0, "the attack that never appeared is still ACTIVE: it was carried, not erased")
	check(tagged_nodes().is_empty(), "no incoming enemy came through the pipe")
	var room_spawner = spawner()
	check(room_spawner != null and room_spawner != sp and room_spawner.session == s, "the bonus room has its own spawner, bound to the same session")
	var delivered: bool = await wait_until(func(): return b.spawned_tick >= 0, 60 * 8)
	await physics_frames(2)
	if delivered:
		var n = node_for(b.seq)
		var pos: Vector2 = room_spawner.spawn_log[-1].position
		var in_the_room: bool = n != null and G.current_level.is_ancestor_of(n)
		var in_view: bool = room_spawner.view_rect().has_point(pos - Vector2(0, 1))
		var on_floor: bool = solid_at(pos + Vector2(0, 8)) and not solid_at(pos + Vector2(0, -8))
		check(in_the_room and in_view and on_floor, "the carried attack is delivered in the bonus room, on a real floor in view (%s, %s; in room %s, in view %s %s, floor %s)" % [pos, room_spawner.spawn_log[-1].side, in_the_room, in_view, room_spawner.view_rect(), on_floor])
		check(room_spawner.spawn_log[-1].frame >= 0 and node_for(b.seq) != null and tagged_nodes().size() == 1, "exactly one enemy for it")
	else:
		check(b.state == ATTACK.State.ACTIVE and room_spawner.plan.holding(), "no safe spot in the bonus room: the attack is held there (%s)" % (room_spawner.fail_log[-1].reason if room_spawner.fail_log.size() > 0 else "not tried"))
	# back out through the exit pipe: what was spawned in the room ends with it
	var exit_pipe: Node2D = G.current_level.get_node("PipeArea")
	player().enter_pipe(exit_pipe)
	var back: bool = await wait_until(func(): return level_running(LEVEL_1_1), 60 * 8)
	await physics_frames(2)
	check(back, "the exit pipe brings Mario back to 1-1")
	if delivered:
		check(b.resolution == RES.LEVEL_TRANSITION and tagged_nodes().is_empty(), "the enemy spawned in the bonus room ended with the room: LEVEL_TRANSITION")
	else:
		check(b.state == ATTACK.State.ACTIVE, "the held attack was carried back out")
	check(s.attacks.history.filter(func(h): return h.target == 0 and h.resolution == RES.LEVEL_TRANSITION and h.spawned_tick < 0).is_empty(), "no attack that never appeared was ever ended by a transition")
	# clean up anything still arriving
	await frames(60 * 3)
	for h in s.attacks.history:
		if h.target == 0 and h.state == ATTACK.State.ACTIVE:
			var n = node_for(h.seq)
			if n != null:
				n.die_from_object(player())
	await frames(40)

# ---- pause ------------------------------------------------------------------------------------------------------------

func test_pause_freezes_flights() -> void:
	print("-- the pause menu holds the attack lines")
	var sc = BS.instance
	var s = session()
	var p = FixedPolicy.new()
	p.target = alive_bot(3)
	s.attacks.targeting = p
	var a = s.report_enemy_defeat(0, TYPES.Kind.GOOMBA) # the player's send: the reticle's flight (BattleSendStyle.SECONDS)
	await frames(6)
	var flight = sc.attack_view.flight_of(a.seq)
	check(flight != null, "(a reticle flight is in the air)")
	var hud: CanvasLayer = G.get_node("GameHUD")
	hud.activate_pause_menu()
	await frames(3)
	var clock0: float = sc.attack_view.clock
	var travel0: float = flight.travel(clock0) if flight != null else -1.0
	var tick0: int = s.tick_count
	await frames(90)
	check(paused and sc.presentation_held(), "the game is paused")
	check(sc.attack_view.clock == clock0 and flight != null and flight.travel(sc.attack_view.clock) == travel0 and s.tick_count == tick0 and not sc.target_reticle.flying.is_empty(), "for 1.5 s the flight, the presentation clock and the Battle clock stand still (clock %.3f)" % clock0)
	hud.get_node("BattlePause").close()
	await frames(20)
	check(not paused and sc.attack_view.clock > clock0 and flight.travel(sc.attack_view.clock) > travel0, "closing the menu resumes the flight from where it stood")
	aim_at_player()

# ---- the round ends --------------------------------------------------------------------------------------------------

func test_win_clears() -> void:
	print("-- a win ends everything, and the next round starts clean")
	var s = session()
	var a = await send_and_spawn(TYPES.Kind.GOOMBA)
	var b = s.report_enemy_defeat(alive_bot(), TYPES.Kind.KOOPA)
	check(a.spawned_tick >= 0 and node_for(a.seq) != null, "(an incoming Goomba is live)")
	var old_uid: int = s.uid
	for id in range(1, 35):
		s.report_ko(id, SESSION.KoCause.HAZARD)
	check(s.finished and s.winner_id == 0 and a.resolution == RES.ROUND_ENDED and b.resolution == RES.ROUND_ENDED, "the player wins: the live and the queued attack end as ROUND_ENDED")
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1500)
	rnd().time_in_state = ROUND.RESULTS_MAX_SECONDS
	await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING and session() != s, 1800)
	await frames(5)
	var leftovers := tagged_nodes().filter(func(n): return AT.origin_of(n)[0] == old_uid)
	check(leftovers.is_empty() and tagged_nodes().is_empty(), "the next round has no incoming enemy of the old round anywhere in the tree")
	check(spawner() != null and spawner().session == session() and spawner().live.is_empty() and session().uid != old_uid, "a new spawner for the new session (new uid), with nothing mapped")
	aim_at_player()

func test_contact_death_clears() -> void:
	print("-- an incoming enemy hurts Mario like any enemy; his KO ends everything")
	var s = session()
	var p := player()
	p.can_hurt = true
	var a = await send_and_spawn(TYPES.Kind.GOOMBA)
	var b = s.report_enemy_defeat(alive_bot(), TYPES.Kind.KOOPA)
	var g = node_for(a.seq)
	check(g != null, "(an incoming Goomba is live)")
	if g != null:
		g.global_position = p.global_position + Vector2(18, -1) # right in front of him, walking his way
		g.direction = -1
		g.reset_physics_interpolation()
	var died: bool = await wait_until(func(): return not s.get_player().alive, 60 * 5)
	check(died and p.is_dead, "walking into small Mario, it kills him (the game's own contact damage)")
	check(a.resolution == RES.TARGET_OUT and b.resolution == RES.TARGET_OUT, "his KO ends every attack aimed at him: TARGET_OUT")
	var old_uid: int = s.uid
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1800)
	rnd().time_in_state = ROUND.RESULTS_MAX_SECONDS
	await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING and session() != s, 1800)
	await frames(5)
	check(tagged_nodes().filter(func(n): return AT.origin_of(n)[0] == old_uid).is_empty() and tagged_nodes().is_empty(), "the next round has none of the old round's incoming enemies")
	check(s.attacks.history.all(func(h): return h.state == ATTACK.State.RESOLVED), "the old round has nothing unresolved")

# ---- Classic ---------------------------------------------------------------------------------------------------------------

func test_classic() -> void:
	print("-- Classic has no incoming enemies")
	load("res://Scripts/Classes/Battle/BattleHandler.gd").quit_battle()
	await wait_until(func(): return on_title(), 1800)
	await frames(10)
	check(SESSION.current == null and tagged_nodes().is_empty(), "Quit leaves no session and no incoming enemy")
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
	var native_count := get_nodes_in_group("Enemies").size()
	check(root.find_children("BattleIncomingSpawner", "", true, false).is_empty() and current_scene.get_node_or_null("BattleHandler") == null, "a Classic level has no BattleHandler and no spawner")
	# a stale session and a hand-tagged Goomba: still nothing
	SESSION.begin(5)
	var stale = SESSION.current
	var g = get_nodes_in_group("Enemies").filter(func(n): return (n.get_script() as Script).resource_path == GOOMBA_SCRIPT)[0]
	AT.tag_incoming(g, stale.uid, 0, 3, TYPES.Kind.GOOMBA)
	g.die_from_object(player())
	await frames(30)
	check(stale.events.is_empty() and stale.attacks.incoming_kill_sources.is_empty() and stale.attacks.defeat_sources.is_empty(), "a Classic kill of a hand-tagged Goomba reports nothing, even with a session object around")
	check(get_nodes_in_group("Enemies").size() <= native_count, "and no enemy appears in Classic")
	SESSION.clear()
	G.transition_to_scene(TITLE)
	await wait_until(func(): return on_title(), 900)
	G.current_game_mode = G.GameMode.NONE
