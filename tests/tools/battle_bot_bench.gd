extends SceneTree
## Measures real bot worlds (doc 56): what N opponents' real games cost per frame, in memory and to load, and what rendering
## their screens for the panes adds. Prints BOTBENCH lines.
##   godot --headless --fixed-fps 60 --path . -s tests/tools/battle_bot_bench.gd -- n=1,2,4,8,16,34 seconds=20
##   xvfb-run godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility -s tests/tools/battle_bot_bench.gd -- n=4,34 seconds=10 render=1
## Without --fixed-fps, frames are timed as they come; the numbers that matter are the per-frame CPU times measured inside
## the frame (physics + process), which do not depend on it.

var counts := [1, 2, 4, 8]
var seconds := 20.0
var render := false
var seed_value := 7

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("n="):
			counts = Array(a.substr(2).split(",")).map(func(x): return int(x))
		elif a.begins_with("seconds="):
			seconds = float(a.substr(8))
		elif a == "render=1":
			render = true
		elif a.begins_with("seed="):
			seed_value = int(a.substr(5))
	_run()

func _run() -> void:
	for i in 5:
		await process_frame
	var G = root.get_node("Global")
	G.current_game_mode = G.GameMode.BATTLE
	var base := await _frames_cost([], 2.0)
	print("BOTBENCH baseline frame_ms=%.3f (no world)" % base.frame_ms)
	for n in counts:
		await _bench(n, base)
	G.current_game_mode = G.GameMode.NONE
	quit()

## Times `frames` physics frames: the wall time of each frame, its worst, and the engine's own physics/process time.
func _frames_cost(worlds: Array, secs: float) -> Dictionary:
	var n := int(secs * 60.0)
	var t_prev := Time.get_ticks_usec()
	var total := 0
	var worst := 0
	var phys := 0.0
	var proc := 0.0
	var step := 0
	for f in n:
		if render:
			for w in worlds:
				if w.viewport != null and w.phase != 4:
					w.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await process_frame
		var t := Time.get_ticks_usec()
		var dt := t - t_prev
		t_prev = t
		total += dt
		worst = maxi(worst, dt)
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		proc += Performance.get_monitor(Performance.TIME_PROCESS)
		for w in worlds:
			step += w.step_us
	return {"frame_ms": total / 1000.0 / n, "worst_ms": worst / 1000.0, "phys_ms": phys * 1000.0 / n, "proc_ms": proc * 1000.0 / n,
		"brain_ms": step / 1000.0 / n}

func _bench(n: int, base: Dictionary) -> void:
	var S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var W = load("res://Scripts/Classes/Battle/BattleBotWorld.gd")
	var session = S.begin(seed_value)
	session.attacks.bots_send = false # (the simulated bots' sends add enemies at random: measured apart)
	var mem0 := Performance.get_monitor(Performance.MEMORY_STATIC)
	var nodes0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var worlds := []
	var t0 := Time.get_ticks_usec()
	var loads := []
	for i in n:
		session.set_world_driven(i + 1)
		var w = W.new(i + 1, session, seed_value)
		root.add_child(w)
		var tl := Time.get_ticks_usec()
		w.start(0)
		loads.append(Time.get_ticks_usec() - tl)
		worlds.append(w)
	var create_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var t1 := Time.get_ticks_usec()
	await process_frame
	var first_frame_ms := (Time.get_ticks_usec() - t1) / 1000.0
	for i in 60:
		await process_frame
	var mem1 := Performance.get_monitor(Performance.MEMORY_STATIC)
	var nodes1 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	# Play, stepping the session's clock (the transitions to 1-2 happen inside this window for the fast bots).
	var acc := 0.0
	var worst_load := 0
	var transitions := 0
	var courses := {}
	for w in worlds:
		courses[w] = w.course
	var cost := {"frame_ms": 0.0, "worst_ms": 0.0, "phys_ms": 0.0, "proc_ms": 0.0, "brain_ms": 0.0}
	var chunks := int(seconds)
	for c in chunks:
		var part := await _frames_cost(worlds, 1.0)
		for k in cost:
			cost[k] = maxf(cost[k], part[k]) if k == "worst_ms" else cost[k] + part[k] / chunks
		session.step()
		for w in worlds:
			if w.course != courses[w]:
				courses[w] = w.course
				transitions += 1
				worst_load = maxi(worst_load, w.load_us)
	var plans := 0
	var plan_us := 0
	var alive := 0
	var cleared := 0
	for w in worlds:
		plans += w.controller.plans
		plan_us += w.controller.plan_us
		alive += int(session.contestants[w.contestant_id].alive)
		cleared += session.contestants[w.contestant_id].levels_cleared
	var per_world: float = (cost.frame_ms - base.frame_ms) / n
	print("BOTBENCH n=%d render=%s frame_ms=%.3f (+%.3f over baseline, %.3f per world) worst_ms=%.1f phys_ms=%.3f proc_ms=%.3f brain_ms=%.3f (%.3f per world) plan_us_avg=%.0f" % [
		n, render, cost.frame_ms, cost.frame_ms - base.frame_ms, per_world, cost.worst_ms, cost.phys_ms, cost.proc_ms, cost.brain_ms, cost.brain_ms / n, float(plan_us) / maxf(plans, 1)])
	print("BOTBENCH n=%d memory_MB=%.1f (%.2f per world) nodes=%d (%d per world) create_ms=%.1f (first world %.1f, later %.1f avg) first_frame_ms=%.1f" % [
		n, (mem1 - mem0) / 1048576.0, (mem1 - mem0) / 1048576.0 / n, int(nodes1 - nodes0), int((nodes1 - nodes0) / n), create_ms, loads[0] / 1000.0,
		(create_ms - loads[0] / 1000.0) / maxf(n - 1, 1), first_frame_ms])
	print("BOTBENCH n=%d played=%ds alive=%d cleared_courses=%d transitions=%d worst_transition_load_ms=%.1f" % [n, chunks, alive, cleared, transitions, worst_load / 1000.0])
	for w in worlds:
		root.remove_child(w)
		w.free()
	S.clear()
	for i in 30:
		await process_frame
