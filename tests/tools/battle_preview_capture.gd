extends SceneTree
## Development tool: renders the real Battle screen (the real 1-1 in its game window, the HUD and the
## opponent previews) at chosen moments of a match and saves PNGs of the display framebuffer.
## Needs a display (e.g. xvfb-run) and a GL renderer:
##   SMB1R_BATTLE_PREVIEW_DEBUG=1 xvfb-run -a -s "-screen 0 2400x1300x24" godot --path . \
##     --rendering-driver opengl3 --rendering-method gl_compatibility --resolution 1920x1080 \
##     -s tests/tools/battle_preview_capture.gd -- out=/some/dir seed=19 shots=screen@40,cell@40
## shots: comma list of <kind>@<tick> where kind is `screen` (the whole Battle screen as the display
## shows it), `full` (opponent #1 enlarged to 256x240 over the game window, needs the debug env var)
## or `cell` (just opponent #1's pane). tick is the session tick to show; fractional ticks (46.5) show
## part-way through that second.
## Optional: window=WxH resizes the game window first; pack=<resource pack name> adds a pack at the
## front of the pack list for this run only (see make_standin_pack.py). SMB1R_BATTLE_PREVIEW_ALL=1 puts
## every pane on the live renderer.
## (The Battle canvas is always CANVAS_ITEMS and the game window always pixel-perfect, so the old
## pixel / smooth visuals switch no longer applies here.)

const LEVEL_1_1 := "res://Scenes/Levels/SMB1/World1/1-1.tscn"

var args := {}
var G
var BS
var screen

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	_run()

func frames(n: int) -> void:
	for i in n:
		await process_frame

func _run() -> void:
	await frames(5)
	G = root.get_node("Global")
	BS = load("res://Scripts/Classes/Battle/BattleScreen.gd")
	var out: String = args.get("out", "/tmp/battle_preview")
	DirAccess.make_dir_recursive_absolute(out)
	var settings = root.get_node("Settings")
	var saved_settings_file := FileAccess.get_file_as_string(settings.SETTINGS_DIR) # the game saves it on every window change
	var saved_video: Dictionary = settings.file.video.duplicate(true)
	var original_window := root.size
	var packs: Array = settings.file.visuals.resource_packs
	var added_pack: String = args.get("pack", "")
	if added_pack != "":
		packs.insert(0, added_pack) # in memory only; removed again before quitting
	var Session = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var Handler = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	if args.has("window"):
		var wh: PackedStringArray = String(args.window).split("x")
		DisplayServer.window_set_position(Vector2i.ZERO)
		root.size = Vector2i(int(wh[0]), int(wh[1]))
		await frames(30) # an X11 window needs a few frames to follow
	Handler.start_match()
	var session = Session.begin(int(args.get("seed", "19"))) # a fixed match, whatever start_match drew
	var guard := 0
	while guard < 1500 and not (current_scene != null and current_scene.get_script() == BS and is_instance_valid(G.current_level) \
			and G.current_level.scene_file_path == LEVEL_1_1 and not G.transitioning_scene):
		await process_frame
		guard += 1
	screen = current_scene
	await frames(5)
	var handler = G.current_level.get_node_or_null("BattleHandler")
	if handler != null:
		handler.set_process(false) # the capture, not the wall clock, drives the Battle clock
	var shots: Array = String(args.get("shots", "screen@40")).split(",")
	var parsed: Array = []
	for s in shots:
		var spec: String = String(s).get_slice(":", 0) # a `:pixel` / `:smooth` suffix from older notes is ignored
		var at := float(spec.get_slice("@", 1))
		parsed.append({"kind": spec.get_slice("@", 0), "tick": int(floor(at)), "alpha": at - floor(at), "name": s})
	parsed.sort_custom(func(a, b): return a.tick + a.alpha < b.tick + b.alpha)
	for shot in parsed:
		while session.tick_count < shot.tick and not session.finished:
			session.step()
			if screen.driver != null:
				screen.driver.update(0.0)
				screen.driver.update(0.5)
		Handler.presentation_alpha = shot.alpha
		if screen.driver != null:
			screen.driver.update(shot.alpha)
		for surface in screen.surfaces:
			if surface.is_live():
				surface.queue_redraw() # we advanced the previews by hand, so tell the panes
		if screen.debug_surface != null:
			screen.debug_surface.queue_redraw()
			screen.debug_surface.visible = shot.kind == "full"
		await frames(4)
		await RenderingServer.frame_post_draw
		var img := DisplayServer.screen_get_image(0)
		img = img.get_region(Rect2i(DisplayServer.window_get_position(), DisplayServer.window_get_size()))
		img = _crop(img, shot.kind)
		var file := "%s/%s_t%03d%s.png" % [out, shot.kind, shot.tick, "" if shot.alpha == 0.0 else "_%02d" % int(round(shot.alpha * 100.0))]
		img.save_png(file)
		var info := ""
		if screen.driver != null and screen.driver.tracks.has(1):
			var t = screen.driver.tracks[1]
			info = " [session tick %d, picture time %.2f, phase %d, mario x=%.0f y=%.0f %s]" % [session.tick_count, t.sim_t, t.phase, t.x, t.y, t.pose]
		print("CAPTURE ", file, " ", img.get_size(), info)
	if added_pack != "":
		packs.erase(added_pack)
	if root.size != original_window:
		root.size = original_window # the game saves the window size whenever it changes
		await frames(30)
	for key in saved_video:
		settings.file.video[key] = saved_video[key]
	var settings_out := FileAccess.open(settings.SETTINGS_DIR, FileAccess.WRITE)
	settings_out.store_string(saved_settings_file)
	settings_out.close()
	quit(0)

func _crop(img: Image, kind: String) -> Image:
	if kind == "screen":
		return img
	var scale := img.get_width() / 480.0
	var r: Rect2 = screen.layout.game if kind == "full" else screen.layout.slots[0]
	return img.get_region(Rect2i(Vector2i(r.position * scale), Vector2i(r.size * scale)))
