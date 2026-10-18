extends SceneTree
## Doc 58 s4: where a bot world's level load goes (scene load, instantiate, entering the tree, first frames), cold and warm,
## whether instancing can move to a worker thread, and the frame cost of a real course cut while other worlds play.
## Measurement only. Prints LOAD lines.
##   godot --headless --fixed-fps 60 --path . -s tests/tools/battle_bot_load_probe.gd -- others=33

var others := 33 ## worlds playing 1-1 while one world cuts to 1-2
var seed_value := 7

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("others="):
			others = int(a.substr(7))
	_run()

func _frame_us() -> int:
	var t := Time.get_ticks_usec()
	await process_frame
	return Time.get_ticks_usec() - t

func _run() -> void:
	for i in 5:
		await process_frame
	var G = root.get_node("Global")
	G.current_game_mode = G.GameMode.BATTLE
	var S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var W = load("res://Scripts/Classes/Battle/BattleBotWorld.gd")
	var C = load("res://Scripts/Classes/Battle/BattleCourse.gd")
	var session = S.begin(seed_value)
	session.attacks.bots_send = false
	var id := 1
	var ps := GDScript.new()
	ps.source_code = "extends Node\nvar t := 0\nfunc _physics_process(_d):\n\tt = Time.get_ticks_usec()\n"
	ps.reload()
	var probe := Node.new()
	probe.set_script(ps)
	probe.process_physics_priority = 1000
	root.add_child(probe)
	# ---- creation breakdown, cold then warm, per course ----
	for course in [0, 1]:
		var path: String = C.scene_path(course)
		for attempt in ["cold", "warm", "warm"]:
			session.set_world_driven(id)
			var w = W.new(id, session, seed_value)
			id += 1
			root.add_child(w)
			w.world_num = C.world_of(course)
			w.level_num = C.level_of(course)
			var t0 := Time.get_ticks_usec()
			var packed: PackedScene = W.packed_scene(path)
			var t1 := Time.get_ticks_usec()
			var lvl = packed.instantiate()
			var t2 := Time.get_ticks_usec()
			w._prepare(lvl)
			w.level = lvl
			var saved = w.push_skin()
			w.viewport.add_child(lvl)
			W.pop_skin(saved)
			var t3 := Time.get_ticks_usec()
			w.player = W._find_player(lvl)
			w._find_goal()
			w.controller.on_level(lvl, w.player, path)
			var tb := [0]
			var cb := func(): tb[0] = Time.get_ticks_usec()
			physics_frame.connect(cb)
			var ta0 := Time.get_ticks_usec()
			var f1: int = await _frame_us()
			var td := Time.get_ticks_usec()
			physics_frame.disconnect(cb)
			var pc: int = probe.t
			var f2: int = await _frame_us()
			var f3: int = await _frame_us()
			var nodes := 0
			var stack: Array[Node] = [lvl]
			while not stack.is_empty():
				var nd: Node = stack.pop_back()
				nodes += 1
				for c in nd.get_children():
					stack.append(c)
			print("LOAD course=%s %s nodes=%d scene_load_ms=%.1f instantiate_ms=%.1f enter_tree_ready_ms=%.1f first_frames_ms=%.1f,%.1f,%.1f" % [
				C.text(course), attempt, nodes, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (t3 - t2) / 1000.0, f1 / 1000.0, f2 / 1000.0, f3 / 1000.0])
			print("LOAD course=%s %s first frame: before physics nodes %.1f ms (input, area/body queries), physics nodes %.1f ms, physics post %.1f ms (server step, deferred calls); the next frame (holding frame 1's idle) %.1f ms" % [
				C.text(course), attempt, (tb[0] - ta0) / 1000.0, (pc - tb[0]) / 1000.0, (td - pc) / 1000.0, f2 / 1000.0])
			root.remove_child(w)
			w.free()
			for i in 3:
				await process_frame
	# ---- instancing on a worker thread ----
	var p12: PackedScene = W.packed_scene(C.scene_path(1))
	var box := [null]
	var tw0 := Time.get_ticks_usec()
	# (Blocking the main thread in WorkerThreadPool.wait_for_task_completion while the worker instantiates deadlocks in this
	# project - measured, doc 58 s4 - so the main thread keeps running frames and polls, as a real preloader would.)
	var task := WorkerThreadPool.add_task(func(): box[0] = p12.instantiate())
	var polled := 0
	var main_frames_us := 0
	while not WorkerThreadPool.is_task_completed(task) and polled < 900:
		main_frames_us += await _frame_us()
		polled += 1
	var tw1 := Time.get_ticks_usec()
	if WorkerThreadPool.is_task_completed(task):
		WorkerThreadPool.wait_for_task_completion(task)
	print("LOAD threaded instantiate 1-2 (main thread polling): done=%s after %d frames, %.1f ms wall, main frames meanwhile avg %.2f ms, result %s" % [
		box[0] != null, polled, (tw1 - tw0) / 1000.0, main_frames_us / 1000.0 / maxf(polled, 1), box[0]])
	if box[0] != null:
		session.set_world_driven(id)
		var wt = W.new(id, session, seed_value)
		id += 1
		root.add_child(wt)
		wt.world_num = 1
		wt.level_num = 2
		var lvl2 = box[0]
		wt._prepare(lvl2)
		wt.level = lvl2
		var ta := Time.get_ticks_usec()
		var saved2 = wt.push_skin()
		wt.viewport.add_child(lvl2)
		W.pop_skin(saved2)
		print("LOAD threaded-instanced 1-2 entered the tree on the main thread in %.1f ms" % [(Time.get_ticks_usec() - ta) / 1000.0])
		root.remove_child(wt)
		wt.free()
	# ---- a real cut while `others` worlds play ----
	var worlds := []
	for i in others + 1:
		session.set_world_driven(id)
		var w2 = W.new(id, session, seed_value)
		id += 1
		root.add_child(w2)
		w2.start(0)
		worlds.append(w2)
	for f in 120:
		await process_frame
	var base := 0
	for f in 30:
		base += await _frame_us()
	base /= 30
	var cutter = worlds[0]
	var tc := Time.get_ticks_usec()
	cutter._finish_course()
	var cut_us := Time.get_ticks_usec() - tc
	var after := []
	for f in 4:
		after.append((await _frame_us()) / 1000.0)
	print("LOAD cut 1-1 -> 1-2 with %d other worlds playing: base frame %.1f ms; the cut itself (free + instantiate + enter tree) %.1f ms (load_us %.1f); next frames %s ms" % [
		others, base / 1000.0, cut_us / 1000.0, cutter.load_us / 1000.0, str(after)])
	# a second world cutting (1-2 warm now)
	var tc2 := Time.get_ticks_usec()
	worlds[1]._finish_course()
	var cut2 := Time.get_ticks_usec() - tc2
	var after2 := []
	for f in 4:
		after2.append((await _frame_us()) / 1000.0)
	print("LOAD second cut (1-2 warm): the cut %.1f ms; next frames %s ms" % [cut2 / 1000.0, str(after2)])
	G.current_game_mode = G.GameMode.NONE
	quit()
