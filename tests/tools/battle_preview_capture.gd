extends SceneTree
## Development tool: renders the real Battle screen (HUD + opponent previews) at chosen moments
## of a match and saves PNGs. Needs a display (e.g. xvfb-run) and a GL renderer:
##   SMB1R_BATTLE_PREVIEW_DEBUG=1 xvfb-run -a godot --path . --rendering-driver opengl3 \
##     --rendering-method gl_compatibility --resolution 1704x960 \
##     -s tests/tools/battle_preview_capture.gd -- out=/some/dir seed=19 shots=screen@40,full@40
## shots: comma list of <kind>@<tick>[:<visuals>] where kind is `screen` (whole Battle screen),
## `full` (opponent #1 enlarged to 256x240, needs the debug env var) or `cell` (just opponent
## #1's real 26x33 window) or `window` (the actual display framebuffer, i.e. after the game's own
## upscaling), tick is the session tick to show (fractional ticks, e.g. 46.5, show part-way through that second), and visuals is `pixel`
## (the game's default pixel-perfect presentation) or `smooth` (its existing canvas-items
## "visuals" option). Only the window is switched; the user's saved setting is never touched.
## Optional: window=WxH resizes the game window first; pack=<resource pack name> adds a pack at the front of the pack list for this run only
## (see make_standin_pack.py), scene=1 (put the real 1-1 level in the middle), all=1 (needs SMB1R_BATTLE_PREVIEW_ALL=1).

var args := {}
var G
var hud

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
	var out: String = args.get("out", "/tmp/battle_preview")
	DirAccess.make_dir_recursive_absolute(out)
	var packs: Array = root.get_node("Settings").file.visuals.resource_packs
	var added_pack: String = args.get("pack", "")
	if added_pack != "":
		packs.insert(0, added_pack) # in memory only; removed again before quitting
	var Session = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var Hud = load("res://Scripts/Classes/Battle/BattleHud.gd")
	var BattleHandlerRef = load("res://Scripts/Classes/Battle/BattleHandler.gd")
	G.current_game_mode = G.GameMode.BATTLE
	var session = Session.begin(int(args.get("seed", "19")))
	if args.get("scene", "0") == "1":
		G.reset_values()
		G.current_game_mode = G.GameMode.BATTLE
		change_scene_to_file("res://Scenes/Levels/SMB1/World1/1-1.tscn")
		await frames(40)
	hud = Hud.ensure(self)
	await frames(5)
	var handler = current_scene.get_node_or_null("BattleHandler") if current_scene != null else null
	if handler != null:
		handler.set_process(false) # the capture, not the wall clock, drives the Battle clock
	if args.has("window"):
		var wh: PackedStringArray = String(args.window).split("x")
		root.size = Vector2i(int(wh[0]), int(wh[1]))
		await frames(5)
	var shots: Array = String(args.get("shots", "screen@40")).split(",")
	var parsed: Array = []
	for s in shots:
		var vis := "pixel"
		var spec: String = s
		if spec.contains(":"):
			vis = spec.get_slice(":", 1)
			spec = spec.get_slice(":", 0)
		var at := float(spec.get_slice("@", 1))
		parsed.append({"kind": spec.get_slice("@", 0), "tick": int(floor(at)), "alpha": at - floor(at), "vis": vis, "name": s})
	parsed.sort_custom(func(a, b): return a.tick + a.alpha < b.tick + b.alpha)
	for shot in parsed:
		while session.tick_count < shot.tick and not session.finished:
			session.step()
			if hud.driver != null:
				hud.driver.update(0.0)
				hud.driver.update(0.5)
		BattleHandlerRef.presentation_alpha = shot.alpha
		if hud.driver != null:
			hud.driver.update(shot.alpha)
		for surface in hud.surfaces:
			if surface.is_live():
				surface.queue_redraw() # we advanced the previews by hand, so tell the windows
		if hud.debug_surface != null:
			hud.debug_surface.queue_redraw()
		await frames(2)
		_set_visuals(shot.vis)
		if hud.debug_surface != null:
			hud.debug_surface.visible = shot.kind == "full"
		await frames(3)
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		if shot.kind == "window":
			# what actually reaches the display: the window framebuffer, after the game's own scaling
			img = DisplayServer.screen_get_image(0)
			img = img.get_region(Rect2i(DisplayServer.window_get_position(), DisplayServer.window_get_size()))
		img = _crop(img, shot.kind)
		var file := "%s/%s_%s_t%03d%s.png" % [out, shot.kind, shot.vis, shot.tick, "" if shot.alpha == 0.0 else "_%02d" % int(round(shot.alpha * 100.0))]
		img.save_png(file)
		var info := ""
		if hud.driver != null and hud.driver.tracks.has(1):
			var t = hud.driver.tracks[1]
			info = " [session tick %d, picture time %.2f, phase %d, mario x=%.0f y=%.0f %s]" % [session.tick_count, t.sim_t, t.phase, t.x, t.y, t.pose]
		print("CAPTURE ", file, " ", img.get_size(), info)
	_set_visuals("pixel")
	if added_pack != "":
		packs.erase(added_pack)
	quit(0)

func _crop(img: Image, kind: String) -> Image:
	if kind == "screen" or kind == "window":
		return img
	var scale := img.get_width() / 426.0
	if kind == "full":
		var c: Rect2 = hud.layout.center
		return img.get_region(Rect2i(Vector2i(c.position * scale), Vector2i(c.size * scale)))
	var r: Rect2 = hud.layout.slots[0]
	return img.get_region(Rect2i(Vector2i(r.position * scale), Vector2i(r.size * scale)))

## Window-only switch between the two presentations the game offers (mirrors WindowChanger.visuals_changed).
func _set_visuals(vis: String) -> void:
	var smooth := vis == "smooth"
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS if smooth else Window.CONTENT_SCALE_MODE_VIEWPORT
	RenderingServer.viewport_set_snap_2d_transforms_to_pixel(root.get_viewport_rid(), not smooth)
