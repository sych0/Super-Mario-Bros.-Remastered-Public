extends SceneTree
## Doc 58 s2 spike: can whole bot worlds run on Godot's worker threads? Runs N worlds on 1-1 with each BattleBotWorld in
## its own processing thread group (`process_thread_group = SUB_THREAD`, so its subtree's _process/_physics_process run
## on the WorkerThreadPool), and the same N on the main thread, same seed; prints frame times and whether each world's
## Mario trace is identical between the two runs. Errors the engine raises (thread guards) go to stderr: count them
## from the run's output. Measurement only.
##   godot --headless --fixed-fps 60 --path . -s tests/tools/battle_bot_thread_spike.gd -- n=8 seconds=5 mode=thread
##   (mode=main | thread; run each and compare THREADSPIKE lines)

var n_worlds := 8
var seconds := 5.0
var mode := "thread"
var seed_value := 7

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("n="):
			n_worlds = int(a.substr(2))
		elif a.begins_with("seconds="):
			seconds = float(a.substr(8))
		elif a.begins_with("mode="):
			mode = a.substr(5)
	_run()

func _run() -> void:
	for i in 5:
		await process_frame
	var G = root.get_node("Global")
	G.current_game_mode = G.GameMode.BATTLE
	var S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var W = load("res://Scripts/Classes/Battle/BattleBotWorld.gd")
	var session = S.begin(seed_value)
	session.attacks.bots_send = false
	var worlds := []
	for i in n_worlds:
		session.set_world_driven(i + 1)
		var w = W.new(i + 1, session, seed_value)
		if mode == "thread":
			w.process_thread_group = Node.PROCESS_THREAD_GROUP_SUB_THREAD
			w.process_thread_group_order = i
		w.record_trace = true
		root.add_child(w)
		w.start(0)
		worlds.append(w)
	var frames := int(seconds * 60.0)
	var t_prev := Time.get_ticks_usec()
	var total := 0
	var worst := 0
	for f in frames:
		await process_frame
		var t := Time.get_ticks_usec()
		total += t - t_prev
		worst = maxi(worst, t - t_prev)
		t_prev = t
		if f % 60 == 59:
			session.step()
	var sig := []
	for w in worlds:
		sig.append("%d:%d:%s" % [w.contestant_id, w.trace.size(), str(hash(w.trace))])
	print("THREADSPIKE mode=%s n=%d frame_ms=%.2f worst_ms=%.1f alive=%d" % [mode, n_worlds, total / 1000.0 / frames, worst / 1000.0,
		worlds.filter(func(w): return w.phase == 0).size()])
	print("THREADSPIKE traces %s" % " ".join(sig))
	G.current_game_mode = G.GameMode.NONE
	quit()
