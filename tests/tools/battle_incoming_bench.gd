extends SceneTree
## Measures what physical incoming enemies cost (doc 46): the frame with no incoming enemy, with 1 and with 3
## live ones, the spawn frame, the bridge's own per-frame cost and the node count. The enemies come through
## the real path (an ACTIVE attack on the player -> BattleIncomingSpawner), never added by hand.
## Headless (CPU only; the enemies are switched on with BattleIncomingSpawner.force_process, since nothing
## renders) or under xvfb GL (software rasterisation dominates the frame there):
##   godot --headless --fixed-fps 60 --path . -s tests/tools/battle_incoming_bench.gd
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 --fixed-fps 60 -s tests/tools/battle_incoming_bench.gd

const TITLE := "res://Scenes/Levels/TitleScreen.tscn"
const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"
const WINDOW := 180 ## frames per measurement (short enough that no enemy reaches Mario and walks off)
const FIXED_SOURCE := """extends "res://Scripts/Classes/Battle/BattleTargeting.gd"
func choose(_session, sender, _draw) -> int:
	return 0 if sender != 0 else 1
"""

var G
var BS
var SESSION
var SPAWNER
var KIND

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

func spawner():
	return G.current_level.get_node_or_null("BattleHandler/BattleIncomingSpawner")

func alive_bot() -> int:
	for id in range(1, 35):
		if SESSION.current.contestants[id].alive:
			return id
	return -1

func kill_all(s) -> void:
	for h in s.attacks.history:
		if h.target == 0 and h.state == 1:
			var n = spawner().live.get(h.seq)
			if n != null and is_instance_valid(n):
				n.die_from_object(player())
	await frames(60)

func _initialize() -> void:
	_run()

## Wall ms per frame, the bridge's mean µs per physics frame, and the node count, over WINDOW frames.
func measure() -> Dictionary:
	var sp = spawner()
	var bridge := 0
	var t := Time.get_ticks_usec()
	for i in WINDOW:
		await process_frame
		bridge += sp.tick_us
	var wall := float(Time.get_ticks_usec() - t) / WINDOW / 1000.0
	return {"wall_ms": wall, "bridge_us": float(bridge) / WINDOW, "nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), "live": sp.live.size()}

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	SESSION = load("res://Scripts/Classes/Battle/BattleSession.gd")
	SPAWNER = load("res://Scripts/Classes/Battle/BattleIncomingSpawner.gd")
	KIND = load("res://Scripts/Classes/Battle/BattleEnemyType.gd").Kind
	var headless := DisplayServer.get_name() == "headless"
	SPAWNER.force_process = headless
	load("res://Scripts/Classes/Battle/BattleRound.gd").pre_round_override = 0.0
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene)
	current_scene.start_battle()
	await wait_until(func(): return BS.is_active() and is_instance_valid(G.current_level) and G.current_level.scene_file_path == LEVEL_1_1 and player() != null and BS.instance.battle_round.state == load("res://Scripts/Classes/Battle/BattleRound.gd").State.PLAYING, 1500)
	await frames(120)
	var s = SESSION.current
	s.attacks.bots_send = false
	s.attacks.pressure_enabled = false
	var policy := GDScript.new()
	policy.source_code = FIXED_SOURCE
	policy.reload()
	s.attacks.targeting = policy.new()
	player().can_hurt = false
	var rows := []
	for run in 2:
		var none := await measure()
		var a = s.report_enemy_defeat(alive_bot(), KIND.GOOMBA)
		await wait_until(func(): return a.spawned_tick >= 0, 600)
		var spawn1: int = spawner().last_spawn_us
		await frames(10)
		var one := await measure()
		await kill_all(s)
		# three at once: they arrive 1 s apart; measured as soon as the third is in
		var made := []
		for k in [KIND.GOOMBA, KIND.KOOPA, KIND.GOOMBA]:
			made.append(s.report_enemy_defeat(alive_bot(), k))
		var spawn_us := []
		for m in made:
			await wait_until(func(): return m.spawned_tick >= 0, 600)
			spawn_us.append(spawner().last_spawn_us)
		await frames(10)
		var three := await measure()
		rows.append("run %d: none %.2f ms (bridge %.1f us, %d nodes) | 1 live %.2f ms (bridge %.1f us, %d nodes, %d live) | 3 live %.2f ms (bridge %.1f us, %d nodes, %d live) | spawn: Goomba %d us; then Goomba %d, Koopa %d, Goomba %d us" % [
			run, none.wall_ms, none.bridge_us, none.nodes, one.wall_ms, one.bridge_us, one.nodes, one.live, three.wall_ms, three.bridge_us, three.nodes, three.live, spawn1, spawn_us[0], spawn_us[1], spawn_us[2]])
		await kill_all(s)
	print("---- incoming bench on %s (%s) ----" % [DisplayServer.get_name(), "CPU only, enemies switched on by hand" if headless else "software GL"])
	for r in rows:
		print(r)
	SPAWNER.force_process = false
	load("res://Scripts/Classes/Battle/BattleRound.gd").pre_round_override = -1.0
	quit(0)
