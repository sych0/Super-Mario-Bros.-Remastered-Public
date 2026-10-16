extends SceneTree
## How incoming enemies are PRESENTED in the real game (doc 48, milestone M6b), against the real project: the
## incoming strip's phases follow a real attack's life (queued, arriving, in the level, resolved) and always agree
## with the session; each physical spawn shows exactly one arrival effect (a sibling of the enemy, owned by the
## spawner), never a second one for the same attack, however the enemy ends; the effect never changes the enemy
## (same properties as a native one, and the very same physics with the effect on or off); several attacks stay
## readable (one effect at a time, in order); the pause holds the effect and the strip's fades; a pipe into the
## bonus room resolves what was in the level, carries what never appeared, and each attack still gets one effect
## in total; an incoming Koopa that is stomped (even during its effect) leaves a plain shell and a woken Koopa
## with no effect and no second send or resolve; and a win, a quit and a new round leave no effect anywhere.
##   godot --headless --fixed-fps 60 --path . -s tests/battle_arrival_game_test.gd
## Headless runs never render, so the test sets BattleIncomingSpawner.force_process (see
## tests/battle_incoming_game_test.gd). What the effect looks like on screen is checked in
## tests/battle_arrival_render_test.gd. Script classes that mention autoloads are only reached through load().

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const LEVEL_1_1A := "res://Scenes/Levels/SMB1/World1/1-1a.tscn"
const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const GOOMBA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/Goomba.gd"
const KOOPA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/KoopaTroopa.gd"
const SHELL_SCRIPT := "res://Scripts/Classes/Entities/ShellClass.gd"
const KOOPA_PREFAB := "res://Scenes/Prefabs/Entities/Enemies/GreenKoopaTroopa.tscn"
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
var ARRIVAL
var PRES
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



func solid_at(pos: Vector2) -> bool:
	var q := PhysicsPointQueryParameters2D.new()
	q.position = pos
	q.collision_mask = 2
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return not BS.instance.game_viewport.find_world_2d().direct_space_state.intersect_point(q, 1).is_empty()


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
	ARRIVAL = load("res://Scripts/Classes/Battle/BattleArrivalEffect.gd")
	PRES = load("res://Scripts/Classes/Battle/BattleAttackPresentation.gd")
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
	SPAWNER.show_arrival = true

	await start_battle()
	await test_wiring()
	await test_strip_phases_follow_real_attacks()
	await test_one_effect_per_spawn()
	await test_enemy_is_untouched()
	await test_physics_identical_with_and_without_the_effect()
	await test_several_at_once()
	await test_effect_ends_with_its_attack()
	await test_pause_holds_the_effect()
	await test_koopa()
	await test_bonus_room_transition()
	await test_round_cleanup()
	await test_quit_cleanup()

	SPAWNER.force_process = false
	SPAWNER.show_arrival = true
	ROUND.pre_round_override = -1.0
	for key in saved_video:
		settings.file.video[key] = saved_video[key]
	var settings_out := FileAccess.open(settings.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle arrival game test(s) failed" % failures)
	else:
		print("All Battle arrival game tests passed")
	quit(1 if failures > 0 else 0)

func start_battle() -> void:
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return on_title(), 900)
	current_scene.start_battle()
	var up: bool = await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING, 1500)
	await frames(5)
	check(up, "Battle is running World 1-1 with the real player")
	calm()

## Every attack goes to the real player, no bot sends on its own, and Mario cannot be hurt.
func calm() -> void:
	aim_at_player()
	player().can_hurt = false

# ---- helpers (this test) --------------------------------------------------------------------------------------

## The arrival effects owned by `sp` (not queued for deletion).
func effects_in(sp) -> Array:
	if sp == null or not is_instance_valid(sp):
		return []
	return sp.get_children().filter(func(n): return n.get_script() == ARRIVAL and not n.is_queued_for_deletion())

## Every arrival effect anywhere in the tree.
func all_effects() -> Array:
	return root.find_children("*", "Node2D", true, false).filter(func(n): return n.get_script() == ARRIVAL and not n.is_queued_for_deletion())

func strip():
	return BS.instance.incoming_strip

## (queued, arriving, in level) among the real player's unresolved attacks, from the session only.
func auth_triple() -> Vector3i:
	var out := Vector3i.ZERO
	for a in session().attacks.history:
		if a.target != 0 or a.state == ATTACK.State.RESOLVED:
			continue
		if a.state == ATTACK.State.QUEUED:
			out.x += 1
		elif a.spawned_tick < 0:
			out.y += 1
		else:
			out.z += 1
	return out

func row_of(seq: int):
	for r in strip().rows:
		if r.seq == seq:
			return r
	return null

## Ends every live incoming enemy and waits until nothing of the real player's is unresolved (arriving ones are
## delivered first, then ended), so each test starts from an empty strip.
func drain() -> void:
	for i in 60:
		if session().get_incoming(0).is_empty():
			break
		for n in tagged_nodes():
			if n.has_method("die_from_object"):
				n.die_from_object(player())
		await frames(20)
	await frames(45) # the fading icons and the last effect are gone

func props(n: Node) -> Dictionary:
	var spr: Node = n.get_node("Sprite")
	return {"modulate": n.modulate, "self_modulate": n.self_modulate, "visible": n.visible, "scale": n.scale, "rotation": n.rotation,
		"z_index": n.z_index, "material": n.material, "collision_layer": n.collision_layer, "collision_mask": n.collision_mask,
		"children": n.get_children().map(func(c): return c.name).filter(func(nm): return nm != &"LevelPersistance"), "light_mask": n.light_mask, "show_behind_parent": n.show_behind_parent,
		"sprite_modulate": spr.modulate, "sprite_self_modulate": spr.self_modulate, "sprite_visible": spr.visible, "sprite_material": spr.material,
		"sprite_scale": spr.scale, "sprite_z": spr.z_index}

## A native enemy of `prefab`, far away, added the way the level's own are. (`props` leaves out its LevelPersistance
## child: the factory's `block_item` meta makes that component free itself on incoming enemies, doc 46.)
func native_enemy(prefab: String) -> Node2D:
	var native: Node2D = load(prefab).instantiate()
	native.set_meta("no_persist", true)
	native.position = Vector2(-9000, -400)
	G.current_level.get_node("Enemies").add_child(native)
	return native

# ---- wiring ---------------------------------------------------------------------------------------------------

func test_wiring() -> void:
	print("-- wiring")
	var sp = spawner()
	check(SPAWNER.show_arrival and sp.arrivals.is_empty() and sp.arrival_log.is_empty() and effects_in(sp).is_empty(), "the spawner starts with no arrival effect and the effect switched on")
	check(strip() != null and strip().view == BS.instance.attack_view and strip().phases == Vector3i.ZERO and strip().rows.is_empty(), "the strip is bound to the screen's presentation and starts empty")

# ---- the strip follows real attacks ------------------------------------------------------------------------------

func test_strip_phases_follow_real_attacks() -> void:
	print("-- the strip's phases follow three real attacks, tick by tick")
	await drain()
	var s = session()
	var a = s.report_enemy_defeat(alive_bot(0), TYPES.Kind.GOOMBA)
	var b = s.report_enemy_defeat(alive_bot(1), TYPES.Kind.KOOPA)
	var c = s.report_enemy_defeat(alive_bot(2), TYPES.Kind.GOOMBA)
	var seen := {a.seq: [], b.seq: [], c.seq: []}
	var recent: Array = []
	var mismatches := 0
	var order_breaks := 0
	var checked := 0
	var transit_seen := false
	var all_spawned_for := 0 # frames recorded since the third enemy appeared
	for i in 60 * 12:
		await process_frame
		recent.append(auth_triple())
		if recent.size() > 4: # the screen reads the session in its own _process: at most a frame or two behind
			recent.pop_front()
		checked += 1
		if not recent.has(strip().phases):
			mismatches += 1
		var last := 99 # IN_LEVEL (2) first, then ARRIVING (1), then QUEUED (0)
		for r in strip().rows:
			if seen.has(r.seq) and (seen[r.seq].is_empty() or seen[r.seq][-1] != r.phase):
				seen[r.seq].append(r.phase)
			if r.phase > last:
				order_breaks += 1
			last = r.phase
			transit_seen = transit_seen or r.in_transit
		if a.spawned_tick >= 0 and b.spawned_tick >= 0 and c.spawned_tick >= 0:
			all_spawned_for += 1
			if all_spawned_for >= 6: # a few more frames: the strip catches up with the last spawn
				break
	check(a.spawned_tick >= 0 and b.spawned_tick >= 0 and c.spawned_tick >= 0, "all three attacks got their enemy")
	check(mismatches == 0, "the strip's phase counts equalled the session's at every frame (%d frames, %d mismatches)" % [checked, mismatches])
	check(order_breaks == 0, "in the strip, in-level icons always come before arriving ones, and those before queued ones")
	check(transit_seen, "(the strip showed the attacks in transit while their lines were in the air)")
	var p = PRES.Phase
	for sq in [a.seq, b.seq, c.seq]:
		var h: Array = seen[sq]
		var monotone: bool = h.size() >= 2 and h[0] == p.QUEUED and h[-1] == p.IN_LEVEL
		for i in range(1, h.size()):
			monotone = monotone and h[i] > h[i - 1]
		check(monotone, "attack %d went QUEUED -> ... -> IN_LEVEL, never backwards (%s)" % [sq, h.map(func(x): return PRES.phase_name(x))])
	check(seen[b.seq].has(p.ARRIVING) and seen[c.seq].has(p.ARRIVING), "the second and third were seen ARRIVING while they waited their gap")
	check(strip().phases == Vector3i(0, 0, 3) and strip().counts == Vector2i(0, 3), "at the end: 3 in level, 0 arriving, 0 queued (the session's `counts`: 3 ACTIVE)")
	# the player defeats the first: its icon fades green where it was; the others stay in the level
	var first = node_for(a.seq)
	first.stomped_on(player())
	await physics_frames(2)
	await frames(3)
	check(a.resolution == RES.DEFEATED_BY_PLAYER and strip().rows.size() == 2 and strip().phases == Vector3i(0, 0, 2), "defeated: two left in the level")
	check(strip().ghosts.size() == 1 and strip().ghosts[0].seq == a.seq and strip().ghosts[0].cause == RES.DEFEATED_BY_PLAYER and strip().ghosts[0].spawned, "its icon is fading in the strip, marked as defeated and as having been in the level")
	check(strip().items.size() == 3 and strip().items[0].get("ghost", false) and strip().items[0].seq == a.seq, "...in the slot it had (first)")
	await frames(40)
	check(strip().ghosts.is_empty() and strip().items.size() == 2, "...and it is gone half a second later")
	await drain()

# ---- one effect per spawn ----------------------------------------------------------------------------------------

func test_one_effect_per_spawn() -> void:
	print("-- one arrival effect per physical spawn")
	await drain()
	var sp = spawner()
	var before: int = sp.arrival_log.size()
	var a = await send_and_spawn(TYPES.Kind.GOOMBA)
	var node = node_for(a.seq)
	var mine := effects_in(sp)
	check(mine.size() == 1 and sp.arrivals.size() == 1 and sp.arrival_log.size() == before + 1 and sp.arrival_log[-1].seq == a.seq, "a spawn made exactly one effect, and logged it once")
	if mine.is_empty() or node == null:
		return
	var fx = mine[0]
	check(fx.seq == a.seq and fx.kind == TYPES.Kind.GOOMBA and fx.target == node and sp.arrivals.get(a.seq) == fx, "it is for that attack's enemy, and the spawner maps the seq to it")
	check(fx.get_parent() == sp and not node.is_ancestor_of(fx) and fx.get_parent() != node.get_parent(), "the spawner owns it: it is not under the enemy and not under the level's Enemies node")
	check(not fx.is_in_group("Enemies") and not (fx is CollisionObject2D) and fx.get_child_count() == 0 and fx.get_script() == ARRIVAL, "it is not an enemy, not a physics body, and has no children")
	var gap: Vector2 = (fx.global_position - node.global_position).abs()
	check(gap.x <= 1.01 and gap.y <= 1.01, "it sits on the enemy's feet (%s apart)" % [gap])
	check(fx.elapsed > 0.0 and fx.elapsed < ARRIVAL.DURATION and not fx.finished(), "and is part way through its %.1f s" % ARRIVAL.DURATION)
	await frames(3)
	var row = row_of(a.seq)
	check(row != null and row.phase == PRES.Phase.IN_LEVEL and row.arrive > 0.0, "the strip shows the same attack IN_LEVEL, with its own arrival mark running")
	# asking again, while it runs and after it ended, does nothing
	sp._start_arrival(a.seq, TYPES.Kind.GOOMBA, node)
	check(effects_in(sp).size() == 1 and sp.arrival_log.size() == before + 1, "asking for a second effect for the same attack while it runs does nothing")
	await physics_frames(int(ARRIVAL.DURATION * 60.0) + 8)
	check(effects_in(sp).is_empty() and sp.arrivals.is_empty() and all_effects().is_empty(), "the effect ended by itself after %.1f s: no node left anywhere" % ARRIVAL.DURATION)
	check(sp.arrival_log.size() == before + 1 and is_instance_valid(node) and not node.is_queued_for_deletion() and sp.live.get(a.seq) == node, "(the log still has one entry; the enemy is alive and tracked)")
	sp._start_arrival(a.seq, TYPES.Kind.GOOMBA, node)
	await physics_frames(3)
	check(effects_in(sp).is_empty() and sp.arrival_log.size() == before + 1, "asking again after it ended does nothing either: one effect per attack, ever")
	await frames(120)
	check(effects_in(sp).is_empty() and sp.arrival_log.size() == before + 1 and row_of(a.seq).arrive == 0.0, "two more seconds: still no second effect, and the strip's mark is gone")
	node.die_from_object(player())
	await drain()

# ---- the enemy is untouched --------------------------------------------------------------------------------------

func test_enemy_is_untouched() -> void:
	print("-- the effect never changes the enemy")
	await drain()
	var sp = spawner()
	for kind in [TYPES.Kind.GOOMBA, TYPES.Kind.KOOPA]:
		var prefab: String = TYPES.prefab(kind)
		var native := native_enemy(prefab)
		await physics_frames(3)
		var a = await send_and_spawn(kind)
		var node = node_for(a.seq)
		var name_: String = TYPES.kind_name(kind)
		check(node != null and effects_in(sp).size() == 1, "%s: an incoming enemy with its effect running" % name_)
		if node == null:
			native.queue_free()
			continue
		var want := props(native)
		var got := props(node)
		var differs := []
		for key in want:
			if want[key] != got[key]:
				differs.append(key)
		check(differs.is_empty(), "%s: DURING the effect every visual property equals a native one's (modulate, self_modulate, visible, scale, z, material, collision, children, sprite) %s" % [name_, differs])
		check(node.get_children().all(func(ch): return ch.get_script() != ARRIVAL) and node.find_children("*", "Node", true, false).all(func(ch): return ch.get_script() != ARRIVAL), "%s: and it has no effect anywhere beneath it" % name_)
		var extra: Array = node.get_meta_list().filter(func(m): return not native.has_meta(m)).map(func(m): return String(m))
		extra.sort()
		check(extra == ["battle_incoming", "block_item"], "%s: beyond a native enemy's metas it has only the factory's block_item and its identity %s" % [name_, extra])
		await physics_frames(int(ARRIVAL.DURATION * 60.0) + 8)
		check(effects_in(sp).is_empty(), "%s: the effect is over" % name_)
		var got_after := props(node)
		var differs_after := []
		for key in want:
			if want[key] != got_after[key]:
				differs_after.append(key)
		check(differs_after.is_empty(), "%s: AFTER the effect it is, property for property, a native enemy %s" % [name_, differs_after])
		check(got_after == got, "%s: and it did not change at all between during and after" % name_)
		native.queue_free()
		node.die_from_object(player())
		await drain()

## The enemy's position on each physics frame since its spawn, for `count` frames (frame offset -> position).
func walk_after_spawn(kind: int, count: int) -> Dictionary:
	var sp = spawner()
	var a = await send_and_spawn(kind)
	var node = node_for(a.seq)
	var spawn_frame: int = sp.spawn_log[-1].frame
	var samples := {}
	for i in count:
		await physics_frame
		if is_instance_valid(node):
			samples[Engine.get_physics_frames() - spawn_frame] = node.global_position
	node.die_from_object(player())
	return {"seq": a.seq, "samples": samples, "spot": sp.spawn_log[-1].position, "direction": sp.spawn_log[-1].direction}

func test_physics_identical_with_and_without_the_effect() -> void:
	print("-- the enemy's physics is the same with the effect on and off")
	await drain()
	var sp = spawner()
	var p := player()
	var mario: Vector2 = p.global_position
	var log0: int = sp.arrival_log.size()
	SPAWNER.show_arrival = true
	var on := await walk_after_spawn(TYPES.Kind.GOOMBA, 90)
	check(sp.arrival_log.size() == log0 + 1, "(run 1: the effect was shown)")
	await drain()
	SPAWNER.show_arrival = false
	var off := await walk_after_spawn(TYPES.Kind.GOOMBA, 90)
	SPAWNER.show_arrival = true
	check(sp.arrival_log.size() == log0 + 1 and all_effects().is_empty(), "(run 2: with the effect off, none was made)")
	check(p.global_position == mario, "(Mario did not move between the runs)")
	check(on.spot == off.spot and on.direction == off.direction, "both runs spawned at the same spot, facing the same way (%s)" % [on.spot])
	var common := 0
	var same := 0
	var first_diff := ""
	for k in on.samples:
		if off.samples.has(k):
			common += 1
			if on.samples[k] == off.samples[k]:
				same += 1
			elif first_diff == "":
				first_diff = "frame +%d: %s vs %s" % [k, on.samples[k], off.samples[k]]
	check(common >= 80 and same == common, "its position is identical on all %d common physics frames since spawn, effect on or off %s" % [common, first_diff])
	var travelled: float = on.spot.x - on.samples[on.samples.keys()[-1]].x
	check(travelled > 30.0, "(and it really walked: %.0f px in 1.5 s)" % travelled)
	await drain()

# ---- several at once ---------------------------------------------------------------------------------------------

func test_several_at_once() -> void:
	print("-- several attacks: one effect at a time, in order, each on its own enemy")
	await drain()
	var s = session()
	var sp = spawner()
	var before: int = sp.arrival_log.size()
	var atks := []
	for i in 5:
		atks.append(s.report_enemy_defeat(alive_bot(i), TYPES.Kind.GOOMBA if i % 2 == 0 else TYPES.Kind.KOOPA))
	var max_concurrent := 0
	var wrong_target := 0
	for i in 60 * 14:
		await physics_frame
		var now := effects_in(sp)
		max_concurrent = maxi(max_concurrent, now.size())
		for fx in now:
			var o: PackedInt64Array = AT.origin_of(fx.target) if is_instance_valid(fx.target) else PackedInt64Array()
			if o.size() != 4 or o[1] != fx.seq:
				wrong_target += 1
		if sp.live.size() >= 3 and now.is_empty():
			break
	var fresh: Array = sp.arrival_log.slice(before)
	check(fresh.size() == 3 and fresh.map(func(e): return e.seq) == [atks[0].seq, atks[1].seq, atks[2].seq], "three spawns, three effects, in send order")
	check(fresh.size() == 3 and fresh[1].frame - fresh[0].frame >= 60 and fresh[2].frame - fresh[1].frame >= 60, "a second apart (the accepted spacing): %s" % [fresh.map(func(e): return e.frame)])
	check(max_concurrent == 1, "never two effects on screen at once (the most: %d)" % max_concurrent)
	check(wrong_target == 0, "every effect followed the enemy of its own attack")
	check(node_for(atks[3].seq) == null and node_for(atks[4].seq) == null and atks[3].state == ATTACK.State.QUEUED and atks[4].state == ATTACK.State.QUEUED, "the fourth and fifth are queued: no enemy, no effect")
	await frames(4)
	check(strip().phases == Vector3i(2, 0, 3) and strip().counts == Vector2i(2, 3), "the strip: 3 in level, 2 queued")
	check(strip().rows.map(func(r): return r.phase) == [PRES.Phase.IN_LEVEL, PRES.Phase.IN_LEVEL, PRES.Phase.IN_LEVEL, PRES.Phase.QUEUED, PRES.Phase.QUEUED], "...in that order")
	# one ends: the fourth is activated and arrives with its own, single effect
	node_for(atks[0].seq).stomped_on(player())
	var came: bool = await wait_until(func(): return atks[3].spawned_tick >= 0, 60 * 8)
	await physics_frames(3)
	check(came and sp.arrival_log.size() == before + 4 and sp.arrival_log[-1].seq == atks[3].seq and effects_in(sp).size() == 1, "when a slot frees, the next attack arrives with exactly one effect of its own")
	check(node_for(atks[4].seq) == null, "(the fifth still waits)")
	await drain()

# ---- the effect ends with the attack -------------------------------------------------------------------------------

func test_effect_ends_with_its_attack() -> void:
	print("-- the effect ends with its attack, however that ends")
	await drain()
	var sp = spawner()
	var before: int = sp.arrival_log.size()
	var a = await send_and_spawn(TYPES.Kind.GOOMBA)
	var node = node_for(a.seq)
	check(effects_in(sp).size() == 1 and effects_in(sp)[0].elapsed < ARRIVAL.DURATION - 0.1, "(an effect is running)")
	node.stomped_on(player())
	await physics_frames(3)
	check(a.resolution == RES.DEFEATED_BY_PLAYER and effects_in(sp).is_empty() and sp.arrivals.is_empty(), "stomped during its effect: the effect is gone with the attack, not left to finish")
	check(sp.arrival_log.size() == before + 1, "(one effect was made for it)")
	await drain()
	var b = await send_and_spawn(TYPES.Kind.GOOMBA)
	var node_b = node_for(b.seq)
	check(effects_in(sp).size() == 1, "(another effect is running)")
	node_b.queue_free() # the enemy just vanishes: nothing reported it, the bridge notices
	await physics_frames(4)
	check(b.resolution == RES.DESPAWNED and effects_in(sp).is_empty() and sp.arrivals.is_empty(), "the enemy vanished during its effect: DESPAWNED, and the effect is gone with it")
	check(sp.arrival_log.size() == before + 2, "(and still one effect per attack)")
	await drain()

# ---- pause ----------------------------------------------------------------------------------------------------------

func test_pause_holds_the_effect() -> void:
	print("-- the pause menu holds the effect, the enemy and the strip's arrival mark")
	await drain()
	var sp = spawner()
	var sc = BS.instance
	var a = await send_and_spawn(TYPES.Kind.GOOMBA)
	var node = node_for(a.seq)
	await frames(2)
	var fx = effects_in(sp)[0] if not effects_in(sp).is_empty() else null
	check(fx != null and fx.elapsed < ARRIVAL.DURATION - 0.15, "(an effect is running, early in its life)")
	if fx == null:
		return
	var hud: CanvasLayer = G.get_node("GameHUD")
	hud.activate_pause_menu()
	await frames(3)
	var e0: float = fx.elapsed
	var pos0: Vector2 = node.global_position
	var clock0: float = sc.attack_view.clock
	var arrive0: float = row_of(a.seq).arrive
	check(arrive0 > 0.0, "(the strip's arrival mark is running too: %.2f)" % arrive0)
	await frames(90)
	check(paused and sc.presentation_held(), "the game is paused")
	check(is_instance_valid(fx) and fx.elapsed == e0 and effects_in(sp).size() == 1 and sp.arrivals.size() == 1, "for 1.5 s the effect stands still, still showing (elapsed %.3f)" % e0)
	check(node.global_position == pos0, "and so does the enemy")
	check(sc.attack_view.clock == clock0 and row_of(a.seq).arrive == arrive0 and strip().rows.size() == 1, "and the strip's arrival mark holds at %.2f" % arrive0)
	hud.get_node("BattlePause").close()
	await frames(10)
	check(not paused and fx.elapsed > e0 and node.global_position != pos0, "closing the menu resumes both from where they stood")
	await frames(45)
	check(effects_in(sp).is_empty() and row_of(a.seq).arrive == 0.0, "and the effect and the mark then finish normally")
	await drain()

# ---- Koopa ----------------------------------------------------------------------------------------------------------

func test_koopa() -> void:
	print("-- an incoming Koopa: the effect, the stomp, the shell, the woken Koopa")
	await drain()
	var s = session()
	var p := player()
	var sp = spawner()
	var before: int = sp.arrival_log.size()
	var ka = await send_and_spawn(TYPES.Kind.KOOPA)
	var k = node_for(ka.seq)
	var kfx := effects_in(sp)
	check(k != null and kfx.size() == 1 and kfx[0].kind == TYPES.Kind.KOOPA and kfx[0].seq == ka.seq and ARRIVAL.body_height(TYPES.Kind.KOOPA) == 24.0, "a Koopa gets one effect, the height of a Koopa")
	if k == null:
		return
	check(sp.arrival_log.size() == before + 1 and kfx[0].elapsed < ARRIVAL.DURATION, "(and it is still running)")
	var sends := sends_by_player()
	var tag: PackedInt64Array = AT.origin_of(k)
	var native_koopa := native_enemy(KOOPA_PREFAB)
	await physics_frames(2)
	k.stomped_on(p) # during its effect: the game copies the Koopa (`duplicate()`) to bring it back after its shell
	await physics_frames(3)
	await frames(2)
	check(ka.resolution == RES.DEFEATED_BY_PLAYER and sends_by_player() == sends, "the stomp resolves the attack, once, and sends nothing")
	check(effects_in(sp).is_empty() and sp.arrivals.is_empty() and all_effects().is_empty(), "the effect ended with the attack")
	check(strip().ghosts.size() == 1 and strip().ghosts[0].seq == ka.seq and strip().ghosts[0].cause == RES.DEFEATED_BY_PLAYER, "the strip fades its icon once, as defeated")
	var shell = null
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and not n.is_queued_for_deletion() and (n.get_script() as Script).resource_path == SHELL_SCRIPT:
			shell = n
	check(shell != null and not AT.is_incoming(shell), "the shell is an ordinary untagged shell")
	if shell == null:
		return
	check(shell.find_children("*", "Node", true, false).all(func(ch): return ch.get_script() != ARRIVAL), "the shell has no effect on it")
	shell.process_mode = Node.PROCESS_MODE_INHERIT # headless: the shell's on-screen enabler never switches it on
	shell.wake_meter = 6.95
	await physics_frames(10)
	var woken = null
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and not n.is_queued_for_deletion() and (n.get_script() as Script).resource_path == KOOPA_SCRIPT and AT.origin_of(n) == tag:
			woken = n
	check(woken != null, "the Koopa woke from its shell, carrying the same identity")
	if woken == null:
		return
	var want := props(native_koopa)
	var got := props(woken)
	var differs := []
	for key in want:
		if want[key] != got[key]:
			differs.append(key)
	check(differs.is_empty(), "the woken Koopa looks and is built exactly like a native one (the game's copy carried no effect) %s" % [differs])
	check(woken.find_children("*", "Node", true, false).all(func(ch): return ch.get_script() != ARRIVAL) and all_effects().is_empty(), "no effect on it, and none anywhere in the tree")
	check(sp.arrival_log.size() == before + 1 and effects_in(sp).is_empty() and sp.arrivals.is_empty(), "waking made no new effect: still the one arrival of the first appearance")
	check(sp.live.is_empty() and strip().rows.is_empty() and strip().phases == Vector3i.ZERO, "the spawner does not take it back and the strip has no row for it")
	await frames(45)
	check(strip().ghosts.is_empty(), "(the first icon's fade is over)")
	woken.stomped_on(p)
	await physics_frames(3)
	await frames(3)
	check(sends_by_player() == sends and strip().ghosts.is_empty() and strip().rows.is_empty() and sp.arrival_log.size() == before + 1 and all_effects().is_empty(), "stomping the woken Koopa changes nothing: no send, no row, no fading icon, no effect")
	check(s.events.filter(func(e): return e.type == SESSION.EventType.INCOMING_SPAWNED and e.a == ka.seq).size() == 1, "(one spawn event for the Koopa, ever)")
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and (n.get_script() as Script).resource_path == SHELL_SCRIPT:
			n.queue_free()
	native_koopa.queue_free()
	await drain()

# ---- transitions -----------------------------------------------------------------------------------------------------

func test_bonus_room_transition() -> void:
	print("-- a pipe into the bonus room and back: resolve what was in the level, carry what was not, one effect per attack")
	await drain()
	var s = session()
	var sp = spawner()
	var pipe: Node2D = G.current_level.get_node("PipeArea")
	await physics_frames(30)
	var a = s.report_enemy_defeat(alive_bot(), TYPES.Kind.GOOMBA)
	var b = s.report_enemy_defeat(alive_bot(1), TYPES.Kind.KOOPA)
	await wait_until(func(): return a.spawned_tick >= 0, 60 * 6)
	await physics_frames(2)
	check(a.spawned_tick >= 0 and b.state == ATTACK.State.ACTIVE and b.spawned_tick < 0, "(one is in the level, the other is ACTIVE and still arriving)")
	await frames(3)
	check(row_of(a.seq).phase == PRES.Phase.IN_LEVEL and row_of(b.seq).phase == PRES.Phase.ARRIVING and strip().phases == Vector3i(0, 1, 1), "the strip shows one IN_LEVEL and one ARRIVING")
	var old_log: Array = sp.arrival_log.duplicate()
	check(old_log.filter(func(e): return e.seq == b.seq).is_empty() and old_log.filter(func(e): return e.seq == a.seq).size() == 1, "(1-1's spawner made an effect for the first and none for the one that never appeared)")
	player().enter_pipe(pipe)
	var in_room: bool = await wait_until(func(): return level_running(LEVEL_1_1A), 60 * 6)
	await physics_frames(2)
	await frames(2)
	check(in_room and a.resolution == RES.LEVEL_TRANSITION, "in the bonus room: the enemy that was in 1-1 ended with it (LEVEL_TRANSITION)")
	var ghosts: Array = strip().ghosts
	check(ghosts.size() == 1 and ghosts[0].seq == a.seq and ghosts[0].cause == RES.LEVEL_TRANSITION, "its strip icon fades as ended by the level change (not as defeated)")
	check(b.state == ATTACK.State.ACTIVE and b.spawned_tick < 0, "the attack that never appeared is still ACTIVE: carried")
	check(all_effects().filter(func(e): return e.seq == a.seq).is_empty(), "no effect of 1-1 survived into the bonus room")
	var room_spawner = spawner()
	check(room_spawner != sp and room_spawner.arrival_log.filter(func(e): return e.seq == a.seq).is_empty(), "the bonus room's spawner never made an effect for the attack that already ended")
	var delivered: bool = await wait_until(func(): return b.spawned_tick >= 0, 60 * 8)
	await physics_frames(2)
	if delivered:
		var room_log: Array = room_spawner.arrival_log.filter(func(e): return e.seq == b.seq)
		check(room_log.size() == 1 and effects_in(room_spawner).size() == 1 and effects_in(room_spawner)[0].seq == b.seq, "the carried attack is delivered in the room with exactly one effect")
		check(old_log.filter(func(e): return e.seq == b.seq).is_empty(), "(in total, one effect for it: the first level never made one)")
		await frames(3)
		check(row_of(b.seq).phase == PRES.Phase.IN_LEVEL, "the strip now shows it IN_LEVEL")
	else:
		await frames(3)
		check(room_spawner.plan.holding() and room_spawner.arrival_log.is_empty() and all_effects().is_empty() and row_of(b.seq).phase == PRES.Phase.ARRIVING, "no safe spot in the room: the attack is held ARRIVING, with no effect (an effect only ever follows a spawn)")
	var exit_pipe: Node2D = G.current_level.get_node("PipeArea")
	player().enter_pipe(exit_pipe)
	var back: bool = await wait_until(func(): return level_running(LEVEL_1_1), 60 * 8)
	await physics_frames(2)
	await frames(2)
	check(back, "back in 1-1")
	if delivered:
		check(b.resolution == RES.LEVEL_TRANSITION and all_effects().is_empty(), "what was spawned in the room ended with it, and no effect is left")
		check(strip().ghosts.any(func(g): return g.seq == b.seq and g.cause == RES.LEVEL_TRANSITION), "...its icon fades as ended by the level change")
	else:
		check(b.state == ATTACK.State.ACTIVE and all_effects().is_empty(), "the held attack was carried back out, still without an effect")
	check(s.attacks.history.filter(func(h): return h.target == 0 and h.resolution == RES.LEVEL_TRANSITION and h.spawned_tick < 0).is_empty(), "no attack that never appeared was ever ended by a transition")
	calm() # Mario was re-created by the level
	await drain()

# ---- round cleanup ---------------------------------------------------------------------------------------------------

func test_round_cleanup() -> void:
	print("-- a win: the effect goes with the attack, nothing fades, the next round is clean")
	await drain()
	var s = session()
	var a = await send_and_spawn(TYPES.Kind.GOOMBA)
	check(effects_in(spawner()).size() == 1, "(an effect is running when the round ends)")
	var old_view = BS.instance.attack_view
	for id in range(1, 35):
		s.report_ko(id, SESSION.KoCause.HAZARD)
	check(s.finished and a.resolution == RES.ROUND_ENDED, "the player wins: the live attack ends as ROUND_ENDED")
	await physics_frames(3)
	await frames(3)
	check(effects_in(spawner()).is_empty() and spawner().arrivals.is_empty(), "the effect ended with it")
	check(strip().rows.is_empty() and strip().ghosts.is_empty() and strip().phases == Vector3i.ZERO, "the strip is empty and nothing fades: the round is over")
	await wait_until(func(): return rnd().state == ROUND.State.RESULTS, 1500)
	rnd().time_in_state = ROUND.RESULTS_MAX_SECONDS
	await wait_until(func(): return level_running() and rnd().state == ROUND.State.PLAYING and session() != s, 1800)
	await frames(5)
	check(all_effects().is_empty() and spawner() != null and spawner().arrival_log.is_empty() and spawner().arrivals.is_empty() and spawner()._arrived.is_empty(), "the next round has no effect anywhere and a spawner that never made one")
	var view = BS.instance.attack_view
	check(view != old_view and view.session == session() and view.records.is_empty() and view.player_resolved().is_empty() and view.player_phase_counts() == Vector3i.ZERO, "and a new presentation with no records, no fading icon and no phase count")
	check(strip().view == view and strip().rows.is_empty() and strip().ghosts.is_empty() and strip().items.is_empty() and strip().phases == Vector3i.ZERO, "the strip is bound to it and empty")
	calm()

func test_quit_cleanup() -> void:
	print("-- Quit with an effect running leaves nothing")
	var a = await send_and_spawn(TYPES.Kind.KOOPA)
	check(effects_in(spawner()).size() == 1 and a.spawned_tick >= 0, "(an effect is running when the player quits)")
	load("res://Scripts/Classes/Battle/BattleHandler.gd").quit_battle()
	await wait_until(func(): return on_title(), 1800)
	await frames(10)
	check(SESSION.current == null and all_effects().is_empty() and tagged_nodes().is_empty(), "Quit leaves no session, no effect and no incoming enemy")
	G.current_game_mode = G.GameMode.NONE
