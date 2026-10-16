extends SceneTree
## Development tool: what the visible attack loop costs. The standalone Battle screen (no level in the game
## window, so the previews, the attack lines, the strip and the chrome are measured) is run for `frames`
## frames in one of three modes:
##   none    attacks off: no attack presentation, no events (the baseline)
##   normal  a normal match: the bots' own sends, nothing else
##   stress  every contestant in the round defeats an enemy every Battle second, nothing hurts the bots, so
##           about 30 lines are in the air at all times and every opponent carries three incoming enemies
## Headless it prints the CPU per frame (the screen's _process, split into the preview driver and the attack
## presentation, plus the time spent recording draw commands for the previews and for the attack lines); under
## a display driver (gl=1) it adds wall-clock frame time and draw calls, which under Mesa software GL are
## inflated, so compare the modes with each other rather than with a GPU:
##   godot --headless --path . -s tests/tools/battle_attack_bench.gd -- mode=stress frames=1800 seed=5 speed=1
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 -s tests/tools/battle_attack_bench.gd -- mode=stress gl=1
## speed=N makes the Battle clock run N times faster (so normal traffic comes N times as often).

func frames(n: int) -> void:
	for i in n:
		await process_frame

func _initialize() -> void:
	_run()

func _percentile(sorted: Array, q: float) -> float:
	return sorted[mini(int(sorted.size() * q), sorted.size() - 1)] if not sorted.is_empty() else 0.0

func _run() -> void:
	await frames(5)
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var mode: String = args.get("mode", "normal")
	var n := int(args.get("frames", "1800"))
	var speed := int(args.get("speed", "1"))
	var gl: bool = args.get("gl", "0") == "1"
	var packs: Array = root.get_node("Settings").file.visuals.resource_packs
	var added_pack: String = args.get("pack", "")
	if added_pack != "":
		packs.insert(0, added_pack)
	var G = root.get_node("Global")
	var Session = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var Screen = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	var Handler = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	var Cell = load("res://Scripts/Classes/Battle/BattlePreviewCell.gd")
	var Layer = load("res://Scripts/Classes/Battle/BattleAttackLayer.gd")
	var Kind = load("res://Scripts/Classes/Battle/BattleEnemyType.gd").Kind
	G.current_game_mode = G.GameMode.BATTLE
	Session.default_attacks_enabled = mode != "none"
	var session = Session.begin(int(args.get("seed", "5")))
	if mode == "stress":
		session.attacks.pressure_enabled = false # every opponent stays in, so the load stays at its peak
	Engine.max_fps = 0
	if gl:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var screen = Screen.new()
	root.add_child(screen)
	await frames(30) # warm up: shader compile, texture upload
	screen.set_process(false) # the bench calls _process itself so it can be timed
	var dt := 1.0 / 60.0
	var alpha := 0.0
	var proc_us: Array = []
	var worst: Array = [] # [us, frame, preview driver us, presentation us] of the slowest frames
	var driver_us := 0
	var view_us := 0
	var wall_ms: Array = []
	var draw_calls := 0
	var flights_sum := 0
	var invaders_sum := 0
	var active_sum := 0
	var sends := 0
	var kinds := [Kind.GOOMBA, Kind.KOOPA]
	Cell.stat_live_us = 0
	Cell.stat_live_draws = 0
	Layer.stat_draw_us = 0
	Layer.stat_draws = 0
	var last := Time.get_ticks_usec()
	var ran := 0
	for i in n:
		ran += 1
		alpha += dt * speed
		while alpha >= 1.0 and not session.finished:
			alpha -= 1.0
			session.step()
			if mode == "stress":
				for id in range(0, 35):
					if session.report_enemy_defeat(id, kinds[(id + session.tick_count) % 2]) != null:
						sends += 1
		Handler.presentation_alpha = clampf(alpha, 0.0, 1.0)
		var t0 := Time.get_ticks_usec()
		screen._process(dt)
		var frame_us := Time.get_ticks_usec() - t0
		proc_us.append(frame_us)
		worst.append([frame_us, i, screen.driver.update_us if screen.driver != null else 0, screen.attack_view.update_us if screen.attack_view != null else 0])
		if worst.size() > 6:
			worst.sort_custom(func(a, b): return a[0] > b[0])
			worst.resize(3)
		if screen.driver != null:
			driver_us += screen.driver.update_us
			for track in screen.driver.tracks.values():
				invaders_sum += track.invaders.size()
		if screen.attack_view != null:
			view_us += screen.attack_view.update_us
			flights_sum += screen.attack_view.flights.size()
		active_sum += session.attacks.history.filter(func(a): return a.state == 1).size() if mode != "none" and i % 30 == 0 else 0
		await process_frame
		if gl:
			var now := Time.get_ticks_usec()
			wall_ms.append((now - last) / 1000.0)
			last = now
			draw_calls += int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		if session.finished:
			break
	var per := float(maxi(ran, 1))
	proc_us.sort()
	var sum_proc := 0
	for v in proc_us:
		sum_proc += v
	var sampled := maxi(ran / 30, 1)
	print("ATTACKBENCH mode=%s frames=%d speed=%d session_ticks=%d alive=%d sends=%d attacks_total=%d" % [mode, ran, speed, session.tick_count, session.alive_count, sends if mode == "stress" else session.attacks.history.size(), session.attacks.history.size()])
	print("ATTACKBENCH load: lines in the air %.1f | invaders shown %.1f | ACTIVE attacks %.1f (means per frame)" % [flights_sum / per, invaders_sum / per, float(active_sum) / sampled])
	print("ATTACKBENCH screen._process us/frame: mean=%.0f median=%.0f p95=%.0f max=%.0f (of which preview driver %.0f, attack presentation %.0f)" % [
		sum_proc / per, _percentile(proc_us, 0.5), _percentile(proc_us, 0.95), proc_us[proc_us.size() - 1], driver_us / per, view_us / per])
	worst.sort_custom(func(a, b): return a[0] > b[0])
	print("ATTACKBENCH slowest frames (us, frame no., preview driver us, presentation us): %s" % [worst.slice(0, 3)])
	print("ATTACKBENCH draw recording us/frame: previews %.0f (%.1f draws) | attack layer %.1f (%.2f draws)" % [
		Cell.stat_live_us / per, Cell.stat_live_draws / per, Layer.stat_draw_us / per, Layer.stat_draws / per])
	print("ATTACKBENCH total CPU us/frame (process + draw recording): %.0f" % ((sum_proc + Cell.stat_live_us + Cell.stat_placeholder_us + Layer.stat_draw_us) / per))
	if gl and not wall_ms.is_empty():
		wall_ms.sort()
		var wsum := 0.0
		for v in wall_ms:
			wsum += v
		print("ATTACKBENCH wall ms/frame (software GL): mean=%.2f median=%.2f p95=%.2f max=%.2f | draw calls/frame=%.0f" % [
			wsum / wall_ms.size(), _percentile(wall_ms, 0.5), _percentile(wall_ms, 0.95), wall_ms[wall_ms.size() - 1], draw_calls / per])
	Session.default_attacks_enabled = true
	if added_pack != "":
		packs.erase(added_pack)
	quit(0)
