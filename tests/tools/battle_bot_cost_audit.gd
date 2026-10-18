extends SceneTree
## Doc 58's cost audit of real bot worlds: where a world's physics frame goes, measured in place by probe nodes (a probe
## records the time as the SceneTree reaches it; probes sit between the level's children and between Mario's children,
## so the time between two probes is what the nodes between them cost), plus a census of what a world is made of and
## micro-benchmarks of hot-path calls. Measurement only: probes change no game state. Prints AUDIT lines.
##   godot --headless --fixed-fps 60 --path . -s tests/tools/battle_bot_cost_audit.gd -- n=34 course=0 warm=2 window=480
##   (course=1 starts every world on 1-2, the heaviest course in the slice: 426 brick nodes)
##   xvfb-run godot --fixed-fps 60 --path . --rendering-driver opengl3 -s tests/tools/battle_bot_cost_audit.gd -- n=34 render=1
##   (render=1 also renders each world's screen as BattleBotDirector does, every=2 renders half the worlds each frame)

var n_worlds := 34
var course := 0
var warm := 4.0
var window := 480 ## frames measured
var seed_value := 7
var render := false
var every := 1 ## render each world every `every` frames (staggered), with render=1
var probe_script: GDScript = null

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("n="):
			n_worlds = int(a.substr(2))
		elif a.begins_with("course="):
			course = int(a.substr(7))
		elif a.begins_with("warm="):
			warm = float(a.substr(5))
		elif a.begins_with("window="):
			window = int(a.substr(7))
		elif a.begins_with("seed="):
			seed_value = int(a.substr(5))
		elif a == "render=1":
			render = true
		elif a.begins_with("every="):
			every = int(a.substr(6))
	probe_script = GDScript.new()
	probe_script.source_code = "extends Node\nvar t := 0\nfunc _physics_process(_d):\n\tt = Time.get_ticks_usec()\n"
	probe_script.reload()
	_run()

func _run() -> void:
	for i in 5:
		await process_frame
	var G = root.get_node("Global")
	G.current_game_mode = G.GameMode.BATTLE
	print("AUDIT engine physics_setting=%s rapier_class=%s separate_thread=%s cpus=%d" % [
		ProjectSettings.get_setting("physics/2d/physics_engine"), ClassDB.class_exists("RapierPhysicsServer2D"),
		ProjectSettings.get_setting("physics/2d/run_on_separate_thread"), OS.get_processor_count()])
	await _dispatch_bench()
	var S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var W = load("res://Scripts/Classes/Battle/BattleBotWorld.gd")
	var session = S.begin(seed_value)
	session.attacks.bots_send = false
	var worlds := []
	for i in n_worlds:
		session.set_world_driven(i + 1)
		var w = W.new(i + 1, session, seed_value)
		root.add_child(w)
		w.start(course)
		worlds.append(w)
	for f in int(warm * 60.0):
		await process_frame
		if f % 60 == 59:
			session.step()
	_census(worlds)
	_micro(worlds)
	await _probed(worlds, session)
	G.current_game_mode = G.GameMode.NONE
	quit()

# ---- what a world is made of ----------------------------------------------------------------------------------------------

func _census(worlds: Array) -> void:
	var w = worlds[0]
	var by_script := {}
	var tot := {"nodes": 0, "phys_script": 0, "phys_internal": 0, "proc_script": 0, "proc_internal": 0, "can_process": 0,
		"canvas_items": 0, "visible_ci": 0, "collision_objects": 0, "areas": 0, "bodies": 0, "notifiers": 0, "resource_setters": 0,
		"raycasts": 0, "animated_sprites": 0, "anim_players": 0, "tilemap_layers": 0}
	for wd in worlds:
		var stack: Array[Node] = [wd.viewport]
		while not stack.is_empty():
			var nd: Node = stack.pop_back()
			for c in nd.get_children():
				stack.append(c)
			tot.nodes += 1
			var live := nd.can_process()
			tot.can_process += int(live)
			if live and nd.is_physics_processing():
				tot.phys_script += 1
				var s: Script = nd.get_script()
				var key := s.resource_path.get_file() if s != null else nd.get_class()
				by_script[key] = by_script.get(key, 0) + 1
			if live and nd.is_physics_processing_internal():
				tot.phys_internal += 1
			if live and nd.is_processing():
				tot.proc_script += 1
				var s2: Script = nd.get_script()
				var key2 := "(process) " + (s2.resource_path.get_file() if s2 != null else nd.get_class())
				by_script[key2] = by_script.get(key2, 0) + 1
			if live and nd.is_processing_internal():
				tot.proc_internal += 1
			if nd is CanvasItem:
				tot.canvas_items += 1
				tot.visible_ci += int((nd as CanvasItem).is_visible_in_tree())
			if nd is CollisionObject2D:
				tot.collision_objects += 1
			if nd is Area2D:
				tot.areas += 1
			if nd is PhysicsBody2D:
				tot.bodies += 1
			if nd is VisibleOnScreenNotifier2D:
				tot.notifiers += 1
			if nd is RayCast2D or nd is ShapeCast2D:
				tot.raycasts += 1
			if nd is AnimatedSprite2D:
				tot.animated_sprites += 1
			if nd is AnimationPlayer:
				tot.anim_players += 1
			if nd is TileMapLayer:
				tot.tilemap_layers += 1
			var sc: Script = nd.get_script()
			if sc != null and sc.resource_path.get_file() == "ResourceSetterNew.gd":
				tot.resource_setters += 1
	var nw := float(worlds.size())
	var parts := []
	for k in tot:
		parts.append("%s=%.0f" % [k, tot[k] / nw])
	print("AUDIT census course=%d per_world %s" % [course, " ".join(parts)])
	var keys := by_script.keys()
	keys.sort_custom(func(a, b): return by_script[a] > by_script[b])
	var top := []
	for k in keys.slice(0, 16):
		top.append("%s:%.1f" % [k, by_script[k] / nw])
	print("AUDIT census course=%d live per-frame callbacks per world: %s" % [course, ", ".join(top)])
	var p = w.player
	if p != null:
		var pn := [0, 0, 0]
		var stack2: Array[Node] = [p]
		while not stack2.is_empty():
			var nd2: Node = stack2.pop_back()
			for c in nd2.get_children():
				stack2.append(c)
			pn[0] += 1
			pn[1] += int(nd2.is_physics_processing() or nd2.is_processing())
			pn[2] += int(nd2.is_physics_processing_internal() or nd2.is_processing_internal())
		print("AUDIT census player_subtree nodes=%d script_callbacks=%d internal_callbacks=%d" % pn)

# ---- micro-benchmarks of hot-path calls ----------------------------------------------------------------------------------

func _time(label: String, reps: int, f: Callable) -> float:
	var t0 := Time.get_ticks_usec()
	for i in reps:
		f.call()
	var us := float(Time.get_ticks_usec() - t0) / reps
	print("AUDIT micro %s us=%.3f" % [label, us])
	return us

func _micro(worlds: Array) -> void:
	var p = worlds[0].player
	var GW = load("res://Scripts/Classes/GameWorld.gd")
	if p == null:
		return
	_time("empty_callable", 20000, func(): pass)
	_time("physics_params(MAX_FALL_SPEED)", 20000, func(): p.physics_params("MAX_FALL_SPEED"))
	_time("physics_params(WALK_SPEED)", 20000, func(): p.physics_params("WALK_SPEED"))
	_time("physics_params(PROJ_TYPE,POWER)", 20000, func(): p.physics_params("PROJ_TYPE", p.POWER_PARAMETERS))
	_time("GameWorld.bot_of", 20000, func(): GW.bot_of(p))
	_time("get_nodes_in_group(CollisionRays)", 20000, func(): p.get_tree().get_nodes_in_group("CollisionRays"))
	_time("GameWorld.group(Enemies) all worlds", 2000, func(): GW.group(p, &"Enemies"))
	var G = root.get_node("Global")
	_time("Global.player_action_pressed(bot)", 20000, func(): G.player_action_pressed("move_right", p.player_id))
	_time("handle_invincible_palette", 5000, func(): p.handle_invincible_palette())
	_time("handle_collision_shapes", 5000, func(): p.handle_collision_shapes())
	_time("world._update_screen", 2000, func(): worlds[0]._update_screen())
	_time("state_machine.is_state", 20000, func(): p.state_machine.is_state("FlagPole"))
	var c = worlds[0].controller
	print("AUDIT micro world.enemies size=%d notifiers=%d" % [worlds[0].enemies.size(), worlds[0]._notifiers.size()])
	_time("brain _foe_nodes", 2000, func(): c._foe_nodes())
	_time("brain _foes", 2000, func(): c._foes(p.global_position, false))
	var st := [0, 0]
	for w in worlds:
		var t0 := Time.get_ticks_usec()
		w._physics_process(1.0 / 60.0)
		st[0] += Time.get_ticks_usec() - t0
	for w in worlds:
		var t1 := Time.get_ticks_usec()
		w._update_screen()
		st[1] += Time.get_ticks_usec() - t1
	print("AUDIT micro one extra world step (all %d worlds): %.1f us per world, of which _update_screen %.1f us" % [worlds.size(), st[0] / float(worlds.size()), st[1] / float(worlds.size())])

## What the SceneTree charges per node per frame for a GDScript callback, apart from any game: N plain nodes whose
## _physics_process does nothing, timed between two probes.
func _dispatch_bench() -> void:
	var gd := GDScript.new()
	gd.source_code = "extends Node2D\nfunc _physics_process(_d):\n\tpass\n"
	gd.reload()
	for kind in ["empty GDScript _physics_process", "plain Node2D, no callback"]:
		var holder := Node.new()
		root.add_child(holder)
		var a := _probe()
		holder.add_child(a)
		for i in 4000:
			var nd := Node2D.new()
			if kind.begins_with("empty"):
				nd.set_script(gd)
			holder.add_child(nd)
		var b := _probe()
		holder.add_child(b)
		var acc := 0
		for f in 5:
			await process_frame
		for f in 60:
			await process_frame
			acc += b.t - a.t
		print("AUDIT dispatch %s: %.3f us per node per frame" % [kind, acc / 60.0 / 4000.0])
		holder.free()

func _probe() -> Node:
	var p := Node.new()
	p.set_script(probe_script)
	p.name = "AuditProbe"
	return p

func _phys_avg(frames: int) -> float:
	for f in 5:
		await process_frame
	var acc := 0.0
	for f in frames:
		await process_frame
		acc += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	return acc * 1000.0 / frames

# ---- in-place timing by probes ------------------------------------------------------------------------------------------

## Inserts a probe before every child of `parent` (and one after the last); returns [[probe, child key], ...] + [end probe, ""].
func _bracket(parent: Node, prefix: String) -> Array:
	var out := []
	var kids := parent.get_children()
	for c in kids:
		var p := _probe()
		parent.add_child(p)
		parent.move_child(p, c.get_index())
		var key := prefix + String(c.name).rstrip("0123456789").rstrip("_ ")
		var sc: Script = c.get_script()
		if sc != null and sc.resource_path != "":
			key += " (" + sc.resource_path.get_file().get_basename() + ")"
		out.append([p, key])
	var e := _probe()
	parent.add_child(e)
	out.append([e, ""])
	return out

func _probed(worlds: Array, session) -> void:
	var t_frame := [0]
	physics_frame.connect(func(): t_frame[0] = Time.get_ticks_usec())
	var first := _probe()
	first.process_physics_priority = -1000
	root.add_child(first)
	var last := _probe()
	last.process_physics_priority = 1000
	root.add_child(last)
	# Mario's own script runs at physics priority 1 (Player.tscn), after every priority-0 node: bracket that band.
	var p1_start := _probe()
	p1_start.process_physics_priority = 1
	root.add_child(p1_start)
	root.move_child(p1_start, 0)
	var p1_end := _probe()
	p1_end.process_physics_priority = 2
	root.add_child(p1_end)
	var prio1 := 0
	# _process band: probes timing every node's _process (and internal process: AnimationPlayer, AnimatedSprite2D).
	var pp_script := GDScript.new()
	pp_script.source_code = "extends Node\nvar t := 0\nfunc _process(_d):\n\tt = Time.get_ticks_usec()\n"
	pp_script.reload()
	var proc_first := Node.new()
	proc_first.set_script(pp_script)
	proc_first.process_priority = -1000
	root.add_child(proc_first)
	var proc_last := Node.new()
	proc_last.set_script(pp_script)
	proc_last.process_priority = 1000
	root.add_child(proc_last)
	var proc_part := 0
	var post_part := 0
	var self_us := 0
	var plans0 := 0
	var plan_us0 := 0
	for w in worlds:
		plans0 += w.controller.plans
		plan_us0 += w.controller.plan_us
	var brackets := []
	var level_starts := []
	var player_pairs := []
	var player_own := 0
	for w in worlds:
		var b := []
		if is_instance_valid(w.level):
			b = _bracket(w.level, "")
			if is_instance_valid(w.player):
				var before_player = null
				for e in b:
					if e[1].begins_with("Player"):
						before_player = e[0]
				var mb := _bracket(w.player, "Mario/")
				player_pairs.append([before_player, mb[0][0]])
				b.append_array(mb)
		brackets.append(b)
		level_starts.append(b[0][0] if not b.is_empty() else null)
	# Probe overhead: two adjacent probes.
	var pa := _probe()
	var pb := _probe()
	root.add_child(pa)
	root.add_child(pb)
	var seg := {}
	var own := 0
	var tree_part := 0
	var phys_total := 0.0
	var wall := 0
	var lvl_total := 0
	var bot_worlds_part := 0
	var probe_cost := 0
	var alive_frames := 0
	var draw := 0
	var draw_calls := 0
	var t_pre := [0]
	var t_post := [0]
	if render:
		RenderingServer.frame_pre_draw.connect(func(): t_pre[0] = Time.get_ticks_usec())
		RenderingServer.frame_post_draw.connect(func(): t_post[0] = Time.get_ticks_usec())
	var t_prev := Time.get_ticks_usec()
	for f in window:
		if render:
			for i in worlds.size():
				var w = worlds[i]
				if w.viewport != null and w.phase != 4 and (i + f) % every == 0:
					w.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await process_frame
		var t := Time.get_ticks_usec()
		wall += t - t_prev
		t_prev = t
		var loop_t0 := Time.get_ticks_usec()
		if f % 60 == 59:
			session.step()
		# t (now) is the start of this frame's idle step: the physics step ran before it.
		phys_total += (t - t_frame[0]) / 1000000.0
		tree_part += last.t - t_frame[0]
		post_part += t - last.t
		if f > 0:
			proc_part += proc_last.t - proc_first.t
		probe_cost += pb.t - pa.t
		if render and f > 0:
			draw += t_post[0] - t_pre[0]
			draw_calls += int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		prio1 += p1_end.t - p1_start.t
		for pp in player_pairs:
			if is_instance_valid(pp[0]) and is_instance_valid(pp[1]):
				player_own += pp[1].t - pp[0].t
		for i in worlds.size():
			var w = worlds[i]
			own += w.step_us
			alive_frames += int(w.phase == 0)
			var b: Array = brackets[i]
			if b.is_empty() or not is_instance_valid(b[0][0]):
				continue
			for j in b.size() - 1:
				var key: String = b[j][1]
				if key == "" or b[j + 1][1] == "" and j + 1 == b.size() - 1 and false:
					continue
				var d: int = b[j + 1][0].t - b[j][0].t
				if b[j][1] != "" :
					seg[key] = seg.get(key, 0) + d
			# the whole level: from its first probe to the next world's first probe (runtime-added nodes included)
			var nxt = level_starts[i + 1] if i + 1 < worlds.size() else last
			if is_instance_valid(nxt):
				lvl_total += nxt.t - b[0][0].t
		self_us += Time.get_ticks_usec() - loop_t0
	var nw := float(worlds.size())
	var fr := float(window)
	var pc := probe_cost / fr
	print("AUDIT probed course=%d n=%d frames=%d avg_worlds_playing=%.1f probe_overhead_us=%.2f" % [course, worlds.size(), window, alive_frames / fr, pc])
	print("AUDIT probed frame wall_ms=%.2f = physics nodes %.2f + physics post %.2f (server step, deferred calls, physics timers, transform notifications, frees) + idle %.2f (of which _process callbacks %.2f; the rest: area/body query callbacks, rendering, input)" % [
		wall / 1000.0 / fr, tree_part / 1000.0 / fr, post_part / 1000.0 / fr, (wall - phys_total * 1000000.0) / 1000.0 / fr, proc_part / 1000.0 / (fr - 1)])
	print("AUDIT probed levels_ms=%.2f (%.3f per world) bot_world_own_ms=%.2f (%.3f per world: brain + screen + reports)" % [
		lvl_total / 1000.0 / fr, lvl_total / 1000.0 / fr / nw, own / 1000.0 / fr, own / 1000.0 / fr / nw])
	var plans1 := 0
	var plan_us1 := 0
	for w in worlds:
		plans1 += w.controller.plans
		plan_us1 += w.controller.plan_us
	print("AUDIT probed (this tool's own per-frame bookkeeping, inside idle: %.2f ms)" % (self_us / 1000.0 / fr))
	print("AUDIT brain plans=%.2f per world-frame, %.0f us per plan -> planning %.1f us per world-frame" % [
		(plans1 - plans0) / fr / nw, float(plan_us1 - plan_us0) / maxf(plans1 - plans0, 1), (plan_us1 - plan_us0) / fr / nw])
	print("AUDIT probed Player.gd own _physics_process (the priority-1 band: every Mario's own script) %.1f us per world-frame" % (prio1 / fr / nw))
	print("AUDIT physics2d active_objects=%d collision_pairs=%d islands=%d (all worlds, last frame)" % [
		Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS), Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS),
		Performance.get_monitor(Performance.PHYSICS_2D_ISLAND_COUNT)])
	# The part outside node callbacks with the physics server's step switched off for a short window (a measurement only:
	# areas stop reporting for 60 frames, so the games may play those frames differently).
	var outside_on := 0.0
	var outside_off := 0.0
	for phase_i in 2:
		PhysicsServer2D.set_active(phase_i == 0)
		for f in 5:
			await process_frame
		var acc := 0.0
		for f in 60:
			await process_frame
			acc += (Time.get_ticks_usec() - last.t) / 1000.0
		if phase_i == 0:
			outside_on = acc / 60.0
		else:
			outside_off = acc / 60.0
	PhysicsServer2D.set_active(true)
	print("AUDIT physics post server_active=%.2f ms server_inactive=%.2f ms -> physics server step ~%.2f ms (%.3f per world)" % [
		outside_on, outside_off, outside_on - outside_off, (outside_on - outside_off) / nw])
	# Every world frozen as a KO'd world is (BattleBotWorld._go_out freezes the level): what such a world still costs.
	var tw0 := Time.get_ticks_usec()
	for f in 60:
		await process_frame
	var running_ms := (Time.get_ticks_usec() - tw0) / 1000.0 / 60.0
	var still := 0
	for w in worlds:
		w.set_frozen(true)
	for f in 5:
		await process_frame
	var tw1 := Time.get_ticks_usec()
	var still_proc := 0
	for f in 60:
		await process_frame
	var frozen_ms := (Time.get_ticks_usec() - tw1) / 1000.0 / 60.0
	for w in worlds:
		if is_instance_valid(w.level):
			var stack: Array[Node] = [w.level]
			while not stack.is_empty():
				var nd: Node = stack.pop_back()
				for c in nd.get_children():
					stack.append(c)
				still += int(nd.can_process() and (nd.is_processing() or nd.is_physics_processing() or nd.is_processing_internal()))
	var gizmos: int = get_nodes_in_group(&"Gizmos").size()
	print("AUDIT frozen all worlds frozen (as KO'd): frame %.2f ms vs %.2f running; nodes still processing per frozen world=%.0f; 'Gizmos' group members=%d (all worlds)" % [
		frozen_ms, running_ms, still / nw, gizmos])
	for w in worlds:
		w.set_frozen(false)
	if render:
		print("AUDIT probed render every=%d draw_ms=%.2f (pre->post draw, CPU wall) draw_calls=%.0f" % [every, draw / 1000.0 / (fr - 1), draw_calls / (fr - 1)])
	var keys := seg.keys()
	keys.sort_custom(func(a, b): return seg[a] > seg[b])
	for k in keys:
		var per_world_us: float = seg[k] / fr / nw - pc
		if per_world_us > 0.5:
			print("AUDIT segment %-60s %8.1f us per world-frame" % [k, per_world_us])
