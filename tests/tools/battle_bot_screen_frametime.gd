extends SceneTree
## Doc 58 s9: the whole Battle screen as a build runs it (the title's Battle entry, the real player's game, the HUD, the atlas, the
## panes; opponents 1..N on real BattleBotWorlds, the rest on the legacy previews), timed frame by frame from the moment the
## Battle screen exists: the round-start creation of the worlds, the pre-round, and S seconds of play including course cuts.
## Prints FRAMETIME lines: percentiles per round phase, frames over 16.7 / 33.3 ms, the worst frames and what happened on them
## (world creations, course cuts), memory and nodes. Measurement only. Run it on the target machine with its real GPU:
##   godot --path . --fixed-fps 60 -s tests/tools/battle_bot_screen_frametime.gd -- --battle-real-bots=34 seconds=30
## (without --fixed-fps the frame times are real-time frames; with it, each frame is timed as it comes and the game advances 1/60 s
## per frame, so a slow machine plays the same game slower instead of skipping physics steps.) `vsync=0` is recommended
## (`--disable-vsync` before `-s`), otherwise frames are capped at the display rate.

const TITLE := "res://Scenes/Levels/TitleScreen.tscn"

var seconds := 30.0
var G
var S
var BS
var ROUND
var HANDLER

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seconds="):
			seconds = a.substr(8).to_float()
	_run()

func wait_until(cond: Callable, max_frames := 900) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await process_frame
	return cond.call()

func on_title() -> bool:
	return current_scene != null and current_scene.scene_file_path == TITLE and not G.transitioning_scene

func _pct(arr: Array, p: float) -> float:
	if arr.is_empty():
		return 0.0
	var a := arr.duplicate()
	a.sort()
	return a[clampi(int(p * (a.size() - 1)), 0, a.size() - 1)]

func _run() -> void:
	for i in 5:
		await process_frame
	G = root.get_node("Global")
	S = root.get_node("Settings")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	ROUND = load("res://Scripts/Classes/Battle/BattleRound.gd")
	HANDLER = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	var DIRECTOR = load("res://Scripts/Classes/Battle/BattleBotDirector.gd")
	var saved_settings := FileAccess.get_file_as_string(S.SETTINGS_DIR)
	HANDLER.seed_source = func() -> int: return 11
	print("FRAMETIME real opponents=%d physics=%s rapier=%s renderer=%s %s cpus=%d" % [DIRECTOR.count(),
		ProjectSettings.get_setting("physics/2d/physics_engine"), ClassDB.class_exists("RapierPhysicsServer2D"),
		RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_vendor(), OS.get_processor_count()])
	G.current_game_mode = G.GameMode.NONE
	change_scene_to_file(TITLE)
	await wait_until(func(): return on_title(), 900)
	current_scene.start_battle()
	await wait_until(func(): return BS.is_active(), 1500)
	var by_phase := {}
	var events := []
	var worst := []
	var known_worlds := {}
	var transitions := {}
	var t_prev := Time.get_ticks_usec()
	var play_frames := 0
	var f := 0
	var mem_peak := 0.0
	while play_frames < int(seconds * 60.0) and f < 60 * 120:
		await process_frame
		f += 1
		var t := Time.get_ticks_usec()
		var dt := (t - t_prev) / 1000.0
		t_prev = t
		if not BS.is_active():
			break
		var scr = BS.instance
		var phase: String = ROUND.State.keys()[scr.battle_round.state]
		if not by_phase.has(phase):
			by_phase[phase] = []
		by_phase[phase].append(dt)
		if phase == "PLAYING":
			play_frames += 1
		var what := []
		if scr.bots != null:
			for id in scr.bots.worlds:
				var w = scr.bots.worlds[id]
				if not known_worlds.has(id):
					known_worlds[id] = true
					what.append("world #%d created" % id)
				var n: int = w.transitions.size()
				if n != transitions.get(id, 0):
					if n > 1:
						what.append("#%d entered %s" % [id, w.scene_path.get_file()])
					transitions[id] = n
		mem_peak = maxf(mem_peak, Performance.get_monitor(Performance.MEMORY_STATIC))
		worst.append([dt, f, phase, ", ".join(what) if not what.is_empty() else "-"])
		if not what.is_empty():
			events.append([f, dt, ", ".join(what)])
	for phase in by_phase:
		var arr: Array = by_phase[phase]
		print("FRAMETIME phase=%s frames=%d p50=%.1f p95=%.1f p99=%.1f max=%.1f ms over16.7=%d over33.3=%d" % [phase, arr.size(),
			_pct(arr, 0.5), _pct(arr, 0.95), _pct(arr, 0.99), _pct(arr, 1.0), arr.filter(func(x): return x > 16.7).size(),
			arr.filter(func(x): return x > 33.3).size()])
	worst.sort_custom(func(a, b): return a[0] > b[0])
	for wv in worst.slice(0, 8):
		print("FRAMETIME worst frame %d (%s): %.1f ms; on it: %s" % [wv[1], wv[2], wv[0], wv[3]])
	var cuts := events.filter(func(e): return "entered" in e[2])
	var cut_ms := cuts.map(func(e): return e[1])
	print("FRAMETIME course cuts=%d, cut frame p50=%.1f max=%.1f ms; worlds created over %d frames" % [cuts.size(), _pct(cut_ms, 0.5),
		_pct(cut_ms, 1.0), events.filter(func(e): return "created" in e[2]).size()])
	print("FRAMETIME memory peak static %.0f MB; nodes %d at the end" % [mem_peak / 1048576.0, Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	HANDLER.seed_source = Callable()
	var fw := FileAccess.open(S.SETTINGS_DIR, FileAccess.WRITE)
	if fw != null:
		fw.store_string(saved_settings)
		fw.close()
	quit()
