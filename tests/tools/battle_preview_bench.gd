extends SceneTree
## Development tool: measures the cost of the Battle opponent previews. Run headless (CPU cost
## of the preview logic + recording every window's draw commands; the GPU is not exercised) or
## under a display driver:
##   godot --headless --path . -s tests/tools/battle_preview_bench.gd -- frames=1200 seed=5
## All 34 opponents are live on World 1-1. live=0 turns the previews off entirely (placeholder
## baseline); speed=N is the battle sim speed.
## Prints per-frame CPU: the HUD's process (incl. the preview driver) and the time spent recording each window's draw commands (renderer draw() only; GPU not measured).

func frames(n: int) -> void:
	for i in n:
		await process_frame

func _initialize() -> void:
	_run()

func _run() -> void:
	await frames(5)
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var n := int(args.get("frames", "1200"))
	var seed_value := int(args.get("seed", "5"))
	var packs: Array = root.get_node("Settings").file.visuals.resource_packs
	var added_pack: String = args.get("pack", "")
	if added_pack != "":
		packs.insert(0, added_pack)
	var G = root.get_node("Global")
	var Session = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var Hud = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	var Handler = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	G.current_game_mode = G.GameMode.BATTLE
	var session = Session.begin(seed_value)
	Engine.max_fps = 0
	Hud.live_previews = args.get("live", "1") != "0" # live=0: every window stays on the placeholder (baseline)
	var hud = Hud.new() # the Battle screen without a level: only the previews are measured
	root.add_child(hud)
	await frames(3)
	var live := 0
	for s in hud.cells:
		if s.is_live():
			live += 1
	var sim_speed := int(args.get("speed", "1"))
	var dt := 1.0 / 60.0
	var alpha := 0.0
	var hud_us := 0
	var update_us := 0
	var frames_run := 0
	var Surface = load("res://Scripts/Classes/Battle/BattlePreviewCell.gd")
	hud.set_process(false) # we call its _process ourselves so it can be timed
	Surface.stat_live_us = 0
	Surface.stat_live_draws = 0
	Surface.stat_placeholder_us = 0
	Surface.stat_placeholder_draws = 0
	for i in n:
		frames_run += 1
		alpha += dt * sim_speed
		while alpha >= 1.0 and not session.finished:
			alpha -= 1.0
			session.step()
		Handler.presentation_alpha = clampf(alpha, 0.0, 1.0)
		var t0 := Time.get_ticks_usec()
		hud._process(dt)
		hud_us += Time.get_ticks_usec() - t0
		if hud.driver != null:
			update_us += hud.driver.update_us
		await process_frame
		if session.finished:
			break
	var per := float(maxi(frames_run, 1))
	print("BENCH live_windows=%d frames=%d session_ticks=%d" % [live, frames_run, session.tick_count])
	print("BENCH per frame: hud_process_us=%.0f (of which preview driver update=%.0f) | live draws=%.1f at %.0f us each = %.0f us | placeholder draws=%.1f at %.0f us each = %.0f us" % [
		hud_us / per, update_us / per,
		Surface.stat_live_draws / per, float(Surface.stat_live_us) / maxi(Surface.stat_live_draws, 1), Surface.stat_live_us / per,
		Surface.stat_placeholder_draws / per, float(Surface.stat_placeholder_us) / maxi(Surface.stat_placeholder_draws, 1), Surface.stat_placeholder_us / per])
	print("BENCH per frame total preview-related CPU: %.0f us (%.2f ms)" % [hud_us / per + (Surface.stat_live_us + Surface.stat_placeholder_us) / per, (hud_us / per + (Surface.stat_live_us + Surface.stat_placeholder_us) / per) / 1000.0])
	var surf_live: Array = hud.cells.filter(func(x): return x.is_live())
	var Atlas = load("res://Scripts/Classes/Battle/BattlePreviewAtlas.gd")
	print("BENCH atlas %s texels, %.2f MB RGBA8" % [Atlas.size_px(), Atlas.memory_bytes() / 1048576.0])
	print("BENCH still_live_at_end=%d alive=%d" % [surf_live.size(), session.alive_count])
	if added_pack != "":
		packs.erase(added_pack)
	quit(0)
