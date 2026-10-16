extends SceneTree
## PROTOTYPE, NOT PRODUCT CODE. Reproduces the evidence for docs/45-battle-incoming-enemies-architecture.md:
## whether the game's own Goomba / Koopa prefabs can be instantiated at runtime into the real player's
## Battle level (inside BattleScreen's 256x240 GameViewport) and then behave as real enemies, what a
## metadata tag survives (Koopa -> shell -> woken Koopa), what happens to such an enemy off screen and in
## a pit, whether the level's collision can be probed for a spawn point, and what extra enemies cost.
## Nothing here is wired into the game: the spike adds nodes from the outside, as a test would.
##
##   godot --headless --fixed-fps 60 --path . -s tests/tools/battle_incoming_spawn_spike.gd

const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const GOOMBA := "res://Scenes/Prefabs/Entities/Enemies/Goomba.tscn"
const KOOPA := "res://Scenes/Prefabs/Entities/Enemies/GreenKoopaTroopa.tscn"
const SHELL_SCRIPT := "res://Scripts/Classes/Entities/ShellClass.gd"
const KOOPA_SCRIPT := "res://Scripts/Classes/Entities/Enemies/KoopaTroopa.gd"
const TAG := "battle_incoming" ## the candidate tag: PackedInt64Array [session id, seq, sender]
const TERRAIN_MASK := 2 ## what the enemies' LedgeDetectionCast and floor collide with
const TILE := 16

var G
var BS
var SESSION
var ROUND
var notes: PackedStringArray = PackedStringArray()

func note(s: String) -> void:
	notes.append(s)
	print("spike: " + s)

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

func level() -> Node:
	return G.current_level

func level_running() -> bool:
	return BS.is_active() and not G.transitioning_scene and is_instance_valid(G.current_level) \
		and G.current_level.scene_file_path == LEVEL_1_1 and player() != null

## Moves Mario without the camera reading the jump as a run (CameraHandler derives its speed from
## last_position, so a raw teleport overshoots the camera by the distance moved).
func teleport(pos: Vector2) -> void:
	var p := player()
	var ch: Node = p.get_node("CameraHandler")
	p.global_position = pos
	p.velocity = Vector2.ZERO
	ch.last_position = pos
	ch.camera_position.x = pos.x
	p.reset_physics_interpolation()

func view_rect() -> Rect2:
	var cam: Camera2D = BS.instance.game_viewport.get_camera_2d()
	var c := cam.get_screen_center_position()
	return Rect2(c - Vector2(128, 120), Vector2(256, 240))

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	ROUND = load("res://Scripts/Classes/Battle/BattleRound.gd")
	ROUND.pre_round_override = 0.0
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene)
	current_scene.start_battle()
	var up: bool = await wait_until(func(): return level_running() and BS.instance.battle_round.state == ROUND.State.PLAYING, 1500)
	await frames(10)
	note("battle up: %s, level %s under %s" % [up, level().name, level().get_parent().name])
	SESSION.current.attacks.bots_send = false
	await spike_native_census()
	await spike_spawn_cost()
	await spike_cost()
	await spike_probe()
	await spike_walk()
	await spike_real_stomp()
	await spike_koopa_shell()
	await spike_offscreen()
	ROUND.pre_round_override = -1.0
	print("---- spike summary ----")
	for n in notes:
		print(n)
	quit(0)

# ---- helpers ----------------------------------------------------------------------------------------

var serial := 0

## The candidate factory recipe: the game's own prefab, the same metas a block / pipe generator sets on
## what it spawns (no level persistence), plus the Battle tag, added under the level's Enemies node.
func spawn(prefab: String, pos: Vector2, dir := -1) -> Node2D:
	var n: Node2D = load(prefab).instantiate()
	serial += 1
	n.set_meta("block_item", true)
	n.set_meta("no_persist", true)
	n.set_meta(TAG, PackedInt64Array([SESSION.current.get_instance_id(), 900 + serial, 7]))
	n.position = pos
	n.set("direction", dir)
	var parent: Node = level().get_node_or_null("Enemies")
	if parent == null:
		parent = level()
	parent.add_child(n)
	n.reset_physics_interpolation()
	return n

func solid_at(p: Vector2) -> bool:
	var q := PhysicsPointQueryParameters2D.new()
	q.position = p
	q.collision_mask = TERRAIN_MASK
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return not player().get_world_2d().direct_space_state.intersect_point(q, 1).is_empty()

## The visible screen as a 16x15 grid of terrain cells (the level's tiles are 16 px, origin-aligned).
func probe_screen() -> Array:
	var r := view_rect()
	var x0 := int(floor(r.position.x / TILE))
	var y0 := int(floor(r.position.y / TILE))
	var rows: Array = []
	for cy in range(y0, y0 + 16):
		var row := ""
		for cx in range(x0, x0 + 17):
			row += "#" if solid_at(Vector2(cx * TILE + 8, cy * TILE + 8)) else "."
		rows.append(row)
	return [x0, y0, rows]

func print_probe(label: String) -> void:
	var pr: Array = probe_screen()
	var p := player().global_position
	var r := view_rect()
	note("%s: view %s, cells from (%d,%d), Mario at %s" % [label, str(r), pr[0], pr[1], str(p)])
	var rows: Array = pr[2]
	for i in rows.size():
		var row: String = rows[i]
		var cy: int = pr[1] + i
		if int(floor((p.y - 8) / TILE)) == cy:
			var mx := int(floor(p.x / TILE)) - int(pr[0])
			if mx >= 0 and mx < row.length():
				row = row.substr(0, mx) + "M" + row.substr(mx + 1)
		note("   %4d %s" % [cy * TILE, row])

## The highest floor in column `cx` within the view: a solid cell with two empty cells above it.
func floor_in_column(cx: int) -> float:
	var r := view_rect()
	var top := int(floor(r.position.y / TILE)) + 2 # below the HUD band
	var bottom := int(floor(r.end.y / TILE))
	for cy in range(top, bottom + 1):
		var c := Vector2(cx * TILE + 8, cy * TILE + 8)
		if solid_at(c) and not solid_at(c - Vector2(0, TILE)) and not solid_at(c - Vector2(0, 2 * TILE)):
			return cy * TILE
	return INF

# ---- spikes -----------------------------------------------------------------------------------------

func spike_native_census() -> void:
	var enemies := get_nodes_in_group("Enemies")
	var nodes := 0
	for e in enemies:
		nodes += 1 + e.get_child_count(true) + _descendants(e)
	note("native: %d nodes in group Enemies in 1-1 (%d nodes including their components); OBJECT_NODE_COUNT=%d" % [enemies.size(), nodes, Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	var g: Node = load(GOOMBA).instantiate()
	var k: Node = load(KOOPA).instantiate()
	note("one Goomba instance = %d nodes, one Koopa = %d nodes" % [1 + _descendants(g), 1 + _descendants(k)])
	g.free()
	k.free()

func _descendants(n: Node) -> int:
	var c := 0
	for ch in n.get_children(true):
		c += 1 + _descendants(ch)
	return c

## What one spawn costs on the frame it happens: the scene load (first time / cached) and instantiate + add.
func spike_spawn_cost() -> void:
	var out: Array = []
	for prefab in [GOOMBA, KOOPA]:
		var t0 := Time.get_ticks_usec()
		var packed: PackedScene = load(prefab)
		var load_us := Time.get_ticks_usec() - t0
		var t1 := Time.get_ticks_usec()
		load(prefab)
		var reload_us := Time.get_ticks_usec() - t1
		var r := view_rect()
		var times: Array = []
		for i in 8:
			var t := Time.get_ticks_usec()
			var n: Node2D = packed.instantiate()
			n.set_meta("block_item", true)
			n.set_meta("no_persist", true)
			n.position = Vector2(r.position.x + 120 + i * 10, 0)
			level().get_node("Enemies").add_child(n)
			times.append(Time.get_ticks_usec() - t)
			await physics_frames(1)
			n.queue_free()
		await frames(2)
		times.sort()
		out.append("%s: first load() %d us, a second load() %d us, instantiate+add median %d us, max %d us" % [prefab.get_file(), load_us, reload_us, times[4], times[7]])
	note("spawn-frame cost: " + "; ".join(out))

func spike_probe() -> void:
	print_probe("probe at start")

func spike_walk() -> void:
	var r := view_rect()
	var cx := int(floor((r.end.x - 24) / TILE))
	var fy := floor_in_column(cx)
	var g := spawn(GOOMBA, Vector2(cx * TILE + 8, fy), -1)
	var x0 := g.global_position.x
	await physics_frames(60)
	var moved := g.global_position.x - x0
	note("runtime Goomba at the right edge (x=%d, floor y=%d): after 1 s moved %.1f px, on floor %s, anim %s, processing %s, on screen %s, tag %s" % [
		cx * TILE + 8, fy, moved, g.is_on_floor(), g.get_node("Sprite").animation, g.can_process(), g.on_screen_enabler.is_on_screen(), str(g.get_meta(TAG))])
	g.queue_free()
	await frames(2)

func spike_real_stomp() -> void:
	var p := player()
	var r := view_rect()
	var cx := int(floor((p.global_position.x + 56) / TILE))
	var fy := floor_in_column(cx)
	var g := spawn(GOOMBA, Vector2(cx * TILE + 8, fy), -1)
	await physics_frames(10)
	var sent_before: int = SESSION.current.attacks.history.size()
	p.global_position = g.global_position + Vector2(0, -40) # a short hop straight up: the camera does not care
	p.velocity = Vector2(0, 0)
	p.reset_physics_interpolation()
	var stomped: bool = await wait_until(func(): return not is_instance_valid(g) or g.get_node("Sprite").animation == "Stomped", 120)
	note("real physics stomp on a tagged runtime Goomba: stomped %s, reported %s, a send was made %s (today a tagged kill still sends: the routing does not exist yet)" % [
		stomped, is_instance_valid(g) and g._battle_defeat_reported, SESSION.current.attacks.history.size() > sent_before])
	await frames(40)
	note("...stomped Goomba freed after its squish: %s" % (not is_instance_valid(g)))

var exits := 0

func spike_koopa_shell() -> void:
	var p := player()
	var cx := int(floor((p.global_position.x + 72) / TILE))
	var fy := floor_in_column(cx)
	var k := spawn(KOOPA, Vector2(cx * TILE + 8, fy), -1)
	k.tree_exiting.connect(func(): exits += 1) # a plain runtime connection, like a bridge would make
	await physics_frames(10)
	var tag: PackedInt64Array = k.get_meta(TAG)
	k.stomped_on(p)
	await physics_frames(4)
	var shell: Node = null
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and (n.get_script() as Script).resource_path == SHELL_SCRIPT and not n.is_queued_for_deletion():
			shell = n
	if shell == null:
		note("koopa: no shell found")
		return
	var old: Node = shell.old_entity
	note("koopa stomped: koopa freed %s, tree_exiting fired %d; shell tagged %s; shell.old_entity tagged %s (same value %s), block_item %s, no_persist %s, _battle_defeat_reported %s, runtime tree_exiting connections copied %d" % [
		not is_instance_valid(k) or k.is_queued_for_deletion(), exits, shell.has_meta(TAG), old.has_meta(TAG), old.has_meta(TAG) and old.get_meta(TAG) == tag,
		old.has_meta("block_item"), old.has_meta("no_persist"), old._battle_defeat_reported, old.tree_exiting.get_connections().size()])
	shell.wake_meter = 6.95
	await physics_frames(10)
	var woken: Node = null
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and (n.get_script() as Script).resource_path == KOOPA_SCRIPT and n.has_meta(TAG) and n.get_meta(TAG) == tag:
			woken = n
	note("shell woke: shell gone %s, woken Koopa in tree %s and carries the attack tag %s" % [not is_instance_valid(shell) or shell.is_queued_for_deletion(), woken != null and woken.is_inside_tree(), woken != null])
	if woken != null:
		var before: int = SESSION.current.attacks.history.size()
		woken.stomped_on(p)
		await physics_frames(4)
		note("...stomping the woken Koopa again reports again and today sends again: %s (the residue must be told apart)" % (SESSION.current.attacks.history.size() > before))
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and n.has_meta(TAG):
			n.queue_free()
	await frames(3)

func spike_offscreen() -> void:
	var r := view_rect()
	# 1. walking off the left edge of the screen
	var cx := int(floor((r.position.x + 20) / TILE))
	var fy := floor_in_column(cx)
	var g := spawn(GOOMBA, Vector2(cx * TILE + 8, fy), -1)
	await physics_frames(120)
	note("Goomba walked off the LEFT edge: still exists %s, in tree %s, can_process %s, on screen %s, x=%.1f (view left %.1f)" % [
		is_instance_valid(g), is_instance_valid(g) and g.is_inside_tree(), is_instance_valid(g) and g.can_process(), is_instance_valid(g) and g.on_screen_enabler.is_on_screen(), g.global_position.x if is_instance_valid(g) else -1.0, r.position.x])
	# 2. spawned beyond the right edge
	var cx2 := int(floor((r.end.x + 40) / TILE))
	var g2 := spawn(GOOMBA, Vector2(cx2 * TILE + 8, fy), -1)
	var x2 := g2.global_position.x
	await physics_frames(60)
	note("Goomba spawned 40 px BEYOND the right edge: moved %.1f px in 1 s, can_process %s (frozen until the camera reaches it)" % [g2.global_position.x - x2, g2.can_process()])
	# 3. a pit: teleport Mario next to 1-1's first gap and drop a Goomba into it
	var p := player()
	var gap_x := -1
	for x in range(900, 1700, 8):
		if not solid_at(Vector2(x, 8)) and not solid_at(Vector2(x, 24)):
			gap_x = x
			break
	if gap_x < 0:
		note("no gap found")
		return
	teleport(Vector2(gap_x - 40, -8))
	await physics_frames(90)
	var r2 := view_rect()
	print_probe("probe at the first pit")
	var g3 := spawn(GOOMBA, Vector2(gap_x + 24, -40), 1) # the middle of the gap, walking away from Mario
	var ys: Array = []
	for i in 8:
		await physics_frames(15)
		ys.append("%.0f%s" % [g3.global_position.y if is_instance_valid(g3) else -1.0, "" if is_instance_valid(g3) and g3.can_process() else "(frozen)"])
	note("Goomba dropped into the pit at x=%d (view bottom %.0f, tree paused %s): y every 0.25 s %s; exists %s, in tree %s" % [gap_x + 24, r2.end.y, paused, ", ".join(ys), is_instance_valid(g3), is_instance_valid(g3) and g3.is_inside_tree()])
	for n in [g, g2, g3]:
		if is_instance_valid(n):
			n.queue_free()
	await frames(3)

func spike_cost() -> void:
	var p := player()
	p.can_hurt = false # the extra enemies walk into Mario; nothing here may pause the tree
	var rows: Array = []
	for extra in [0, 3, 10, 30, 0, 3]:
		rows.append("+%d %s" % [extra, await _measure(extra)])
	p.can_hurt = true
	note("frame cost on %s, World 1-1 start screen (wall ms per frame over 300 frames%s): %s" % [
		DisplayServer.get_name(), "; headless = CPU only, enemies switched on by hand" if DisplayServer.get_name() == "headless" else "; software GL, rendering dominates", " | ".join(rows)])

func _measure(extra: int) -> String:
	var spawned: Array = []
	var r := view_rect()
	for i in extra:
		spawned.append(spawn(GOOMBA, Vector2(r.position.x + 96 + i * 5, 0), -1 if i % 2 == 0 else 1))
	await physics_frames(2)
	if DisplayServer.get_name() == "headless":
		# no rendering, so no visibility notifier ever enables them: switch them on by hand to measure their CPU cost
		for s in spawned:
			s.process_mode = Node.PROCESS_MODE_INHERIT
	await physics_frames(30)
	var n := 300
	var t := Time.get_ticks_usec()
	for i in n:
		await process_frame
	var wall := float(Time.get_ticks_usec() - t) / n / 1000.0
	var running := 0
	for s in spawned:
		if is_instance_valid(s) and s.can_process() and s.is_inside_tree():
			running += 1
	for s in spawned:
		if is_instance_valid(s):
			s.queue_free()
	await frames(3)
	return "%.2f (%d running)" % [wall, running]
