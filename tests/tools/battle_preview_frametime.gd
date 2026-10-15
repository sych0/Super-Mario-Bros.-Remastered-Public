extends SceneTree
## Development tool: wall-clock frame time and video memory of the Battle screen's opponent previews
## under a REAL renderer (run it under a display driver, e.g. xvfb with Mesa software GL, which
## exaggerates GPU work; absolute numbers on a real GPU will be lower, the comparison between
## builds is what matters):
##   xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1920x1080 \
##     -s tests/tools/battle_preview_frametime.gd -- frames=600 speed=1 live=1 [pack=SandboxStandIn]
## The screen is the standalone Battle screen (no level in the game window), so this measures the
## previews + chrome only. live=0 keeps every pane on the placeholder. speed=N is the Battle sim speed.

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
	var settings = root.get_node("Settings")
	var packs: Array = settings.file.visuals.resource_packs
	var added_pack: String = args.get("pack", "")
	if added_pack != "":
		packs.insert(0, added_pack)
	var G = root.get_node("Global")
	var Session = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var Screen = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	var Handler = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	G.current_game_mode = G.GameMode.BATTLE
	var session = Session.begin(int(args.get("seed", "5")))
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Screen.live_previews = args.get("live", "1") != "0"
	var screen = Screen.new()
	root.add_child(screen)
	await frames(30) # warm up: shader compile, texture upload
	var n := int(args.get("frames", "600"))
	var speed := int(args.get("speed", "1"))
	var dt := 1.0 / 60.0
	var alpha := 0.0
	var times: Array[float] = []
	var draw_calls := 0
	var last := Time.get_ticks_usec()
	for i in n:
		alpha += dt * speed
		while alpha >= 1.0 and not session.finished:
			alpha -= 1.0
			session.step()
		Handler.presentation_alpha = clampf(alpha, 0.0, 1.0)
		await process_frame
		var now := Time.get_ticks_usec()
		times.append((now - last) / 1000.0)
		last = now
		draw_calls += int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		if session.finished:
			break
	times.sort()
	var sum := 0.0
	for t in times:
		sum += t
	var live := 0
	if "cells" in screen:
		live = screen.cells.filter(func(c): return c.is_live()).size()
	elif "surfaces" in screen: # builds before the atlas
		live = screen.surfaces.filter(func(c): return c.is_live()).size()
	var vram_tex := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0
	var vram_all := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0
	print("FRAMETIME live_panes=%d speed=%d frames=%d session_ticks=%d alive=%d" % [live, speed, times.size(), session.tick_count, session.alive_count])
	print("FRAMETIME ms/frame: mean=%.2f median=%.2f p95=%.2f max=%.2f | draw calls/frame=%.0f | texture mem=%.1f MB video mem=%.1f MB" % [
		sum / maxi(times.size(), 1), times[times.size() / 2], times[int(times.size() * 0.95)], times[times.size() - 1],
		draw_calls / float(maxi(times.size(), 1)), vram_tex, vram_all])
	if added_pack != "":
		packs.erase(added_pack)
	quit(0)
