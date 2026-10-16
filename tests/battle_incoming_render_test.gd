extends SceneTree
## Physical incoming enemies under a real GL renderer (doc 46, M6a): what a headless run cannot show.
## No test hook switches the enemy on here: the game's own VisibleOnScreenEnabler2D does, because the
## enemy appears inside the camera view. Covers: an ACTIVE attack's Goomba is drawn in the game window,
## wakes up by itself and walks toward Mario; a real physics stomp (Mario dropped on it) resolves its
## attack and sends nothing; an incoming Goomba the camera leaves behind is frozen by the game and still
## despawned by the bridge; and walking into small Mario it kills him like any Goomba (TARGET_OUT).
##
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 \
##     -s tests/battle_incoming_render_test.gd -- [out=/some/dir] [pack=SandboxStandIn]
## (pack= adds a resource pack for this run only, see tests/tools/make_standin_pack.py; out= saves the pictures it inspects)

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
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
var args := {}
var out := ""
var G
var S
var BS
var SESSION
var KIND
var RES
var AT
var FixedPolicy
var session

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

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	_run()

func player() -> Node2D:
	return get_first_node_in_group("Players") as Node2D

func level_running() -> bool:
	return current_scene != null and current_scene.get_script() == BS and not G.transitioning_scene \
		and is_instance_valid(G.current_level) and G.current_level.scene_file_path == LEVEL_1_1 \
		and G.current_level.get_parent() == current_scene.game_viewport and player() != null

func spawner():
	return G.current_level.get_node_or_null("BattleHandler/BattleIncomingSpawner")

func node_for(seq: int):
	for n in get_nodes_in_group("Enemies"):
		if is_instance_valid(n) and not n.is_queued_for_deletion():
			var o: PackedInt64Array = AT.origin_of(n)
			if o.size() == 4 and o[0] == session.uid and o[1] == seq:
				return n
	return null

func alive_bot() -> int:
	for id in range(1, 35):
		if session.contestants[id].alive:
			return id
	return -1

func sends_by_player() -> int:
	return session.events.filter(func(e): return e.type == SESSION.EventType.SENT and e.id == 0).size()

## The game window as the renderer drew it (256x240).
func game_image(name := "") -> Image:
	await RenderingServer.frame_post_draw
	var img: Image = current_scene.game_viewport.get_texture().get_image()
	if out != "" and name != "":
		DirAccess.make_dir_recursive_absolute(out)
		img.save_png(out.path_join(name + ".png"))
	return img

## Mean absolute colour difference between two images over `rect` (0..1).
func diff(a: Image, b: Image, rect: Rect2i) -> float:
	var total := 0.0
	var n := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if x < 0 or y < 0 or x >= a.get_width() or y >= a.get_height():
				continue
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return total / maxf(n, 1)

func solid_at(pos: Vector2) -> bool:
	var q := PhysicsPointQueryParameters2D.new()
	q.position = pos
	q.collision_mask = 2
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return not current_scene.game_viewport.find_world_2d().direct_space_state.intersect_point(q, 1).is_empty()

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

func teleport(pos: Vector2) -> void:
	var p := player()
	var ch: Node = p.get_node("CameraHandler")
	p.global_position = pos
	p.velocity = Vector2.ZERO
	ch.last_position = pos
	ch.camera_position.x = pos.x
	p.reset_physics_interpolation()

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	S = root.get_node("Settings")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	KIND = load("res://Scripts/Classes/Battle/BattleEnemyType.gd").Kind
	RES = load("res://Scripts/Classes/Battle/BattleAttack.gd").Resolution
	AT = load("res://Scripts/Classes/Battle/BattleAttribution.gd")
	load("res://Scripts/Classes/Battle/BattleRound.gd").pre_round_override = 0.0
	load("res://Scripts/Classes/Battle/BattleIncomingSpawner.gd").force_process = false
	FixedPolicy = GDScript.new()
	FixedPolicy.source_code = FIXED_SOURCE
	FixedPolicy.reload()
	out = args.get("out", "")
	var packs: Array = S.file.visuals.resource_packs
	var added_pack: String = args.get("pack", "")
	if added_pack != "":
		packs.insert(0, added_pack)
	var saved_video: Dictionary = S.file.video.duplicate(true)
	var saved_settings_file := FileAccess.get_file_as_string(S.SETTINGS_DIR)

	G.current_game_mode = G.GameMode.NONE
	load("res://Scripts/Classes/Battle/BattleHandler.gd").start_match()
	var up: bool = await wait_until(func(): return level_running(), 1500)
	await frames(10)
	check(up and DisplayServer.get_name() != "headless", "Battle runs 1-1 under a real renderer (%s)" % DisplayServer.get_name())
	session = SESSION.current
	session.attacks.bots_send = false
	session.attacks.pressure_enabled = false
	var policy = FixedPolicy.new()
	policy.target = 0
	session.attacks.targeting = policy
	player().can_hurt = false

	await test_walk_and_pixels()
	await test_real_stomp()
	await test_left_behind()
	await test_contact()

	if added_pack != "":
		packs.erase(added_pack)
	for key in saved_video:
		S.file.video[key] = saved_video[key]
	load("res://Scripts/Classes/Battle/BattleRound.gd").pre_round_override = -1.0
	var settings_out := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	if failures > 0:
		printerr("%d Battle incoming render test(s) failed" % failures)
	else:
		print("All Battle incoming render tests passed")
	quit(1 if failures > 0 else 0)

func test_walk_and_pixels() -> void:
	print("-- an incoming Goomba is drawn, wakes by itself and walks")
	var before := await game_image("incoming_00_before")
	var a = session.report_enemy_defeat(alive_bot(), KIND.GOOMBA)
	var spawned: bool = await wait_until(func(): return a.spawned_tick >= 0, 60 * 8)
	await physics_frames(3)
	var g = node_for(a.seq)
	check(spawned and g != null, "the ACTIVE attack's Goomba is in the level")
	if g == null:
		return
	check(g.can_process() and g.on_screen_enabler.is_on_screen(), "the game's own on-screen enabler switched it on (no test hook)")
	var view: Rect2 = spawner().view_rect()
	var after := await game_image("incoming_01_spawned")
	var sx := int(g.global_position.x - view.position.x)
	var sy := int(g.global_position.y - view.position.y)
	var d := diff(before, after, Rect2i(sx - 8, sy - 16, 16, 16))
	check(d > 0.08, "it is drawn in the game window where it stands (mean colour change %.3f over its 16x16 cell at %d,%d)" % [d, sx, sy])
	var x0: float = g.global_position.x
	await physics_frames(60)
	var moved: float = x0 - g.global_position.x
	check(moved > 20.0 and moved < 45.0 and g.is_on_floor(), "it walks toward Mario on the floor (%.1f px in 1 s)" % moved)

func test_real_stomp() -> void:
	print("-- a real physics stomp")
	var a = null
	for h in session.attacks.history:
		if h.target == 0 and h.state == 1:
			a = h
	var g = node_for(a.seq) if a != null else null
	if g == null:
		check(false, "(an incoming Goomba is live)")
		return
	var p := player()
	var sends := sends_by_player()
	teleport(g.global_position + Vector2(0, -40)) # straight above it, the camera told (a raw jump throws it off)
	var stomped: bool = await wait_until(func(): return a.state == 2, 120)
	check(stomped and a.resolution == RES.DEFEATED_BY_PLAYER, "Mario dropped onto it stomps it through the game's physics: DEFEATED_BY_PLAYER")
	check(sends_by_player() == sends, "and that sends nothing")
	await frames(60)

func test_left_behind() -> void:
	print("-- left behind: the game freezes it, the bridge despawns it")
	var a = session.report_enemy_defeat(alive_bot(), KIND.GOOMBA)
	await wait_until(func(): return a.spawned_tick >= 0, 60 * 8)
	await physics_frames(5)
	var g = node_for(a.seq)
	var p := player()
	teleport(Vector2(clear_ground_from(g.global_position.x + 330), -1))
	var frozen := false
	for i in 60 * 3:
		await physics_frame
		if is_instance_valid(g) and not g.can_process():
			frozen = true
		if a.state == 2:
			break
	check(frozen or a.state == 2, "off screen behind the camera the game switches it off")
	check(a.state == 2 and a.resolution == RES.DESPAWNED, "the bridge still resolves it DESPAWNED")
	await frames(3)
	check(not is_instance_valid(g) or g.is_queued_for_deletion(), "and removes it")

func test_contact() -> void:
	print("-- contact hurts like a native Goomba")
	var p := player()
	p.can_hurt = true
	var a = session.report_enemy_defeat(alive_bot(), KIND.GOOMBA)
	await wait_until(func(): return a.spawned_tick >= 0, 60 * 8)
	await physics_frames(3)
	var g = node_for(a.seq)
	if g != null:
		g.global_position = p.global_position + Vector2(20, 0)
		g.reset_physics_interpolation()
	var died: bool = await wait_until(func(): return not session.get_player().alive, 60 * 5)
	await game_image("incoming_02_contact")
	check(died and p.is_dead, "it walks into small Mario and kills him")
	check(a.resolution == RES.TARGET_OUT, "his KO ends its attack: TARGET_OUT")
